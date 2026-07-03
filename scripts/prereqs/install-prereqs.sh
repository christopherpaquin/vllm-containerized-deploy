#!/usr/bin/env bash
# =============================================================================
# install-prereqs.sh
# Idempotent validator & installer for all vLLM deployment prerequisites.
# Philosophy: Validator-first. Never blindly overwrites a working driver stack.
#
# Every component that is already present is left untouched — no updates,
# no upgrades, no re-configuration. Anything missing is only installed after
# an explicit y/N confirmation (skip prompts with -y/--yes for automation).
#
# Usage:
#   sudo bash scripts/prereqs/install-prereqs.sh [-y|--yes]
# =============================================================================
set -euo pipefail

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Options -------------------------------------------------------------
ASSUME_YES=false
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help)
      echo "Usage: sudo bash scripts/prereqs/install-prereqs.sh [-y|--yes]"
      echo "  -y, --yes   Auto-confirm every install prompt (for automation)."
      exit 0
      ;;
  esac
done

# Prompts before installing anything. Reads from the controlling terminal
# so it still works when the script's own stdin is redirected. Returns
# non-zero (declined) if there's no terminal to prompt on and -y wasn't set.
confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  if [[ ! -e /dev/tty ]]; then
    warn "No terminal available to prompt (\"${prompt}\") — pass -y/--yes to auto-confirm. Skipping."
    return 1
  fi
  local reply
  read -r -p "$(echo -e "${YELLOW}?${RESET} ${prompt} [y/N] ")" reply < /dev/tty || reply=""
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# --- Privilege guard ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root (sudo $0)."
fi

# =============================================================================
# STEP 1 — NVIDIA GPU Driver
# =============================================================================
step "STEP 1/4 — NVIDIA GPU Driver"

if command -v nvidia-smi &>/dev/null; then
  DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
  ok "nvidia-smi found. Driver version: ${DRIVER_VERSION}. Skipping — existing driver is never updated/upgraded/reinstalled."
else
  warn "nvidia-smi not found. No NVIDIA driver detected."

  if confirm "Install the recommended NVIDIA GPU driver now (headless, via ubuntu-drivers --gpgpu)?"; then
    info "Installing ubuntu-drivers-common..."
    apt-get update -qq
    apt-get install -y ubuntu-drivers-common

    info "Detecting recommended GPU driver..."
    ubuntu-drivers install --gpgpu

    warn "═══════════════════════════════════════════════════════════"
    warn "  A SYSTEM REBOOT IS REQUIRED to activate the GPU driver."
    warn "  After reboot, re-run this script to continue setup."
    warn "  Command: sudo reboot"
    warn "═══════════════════════════════════════════════════════════"
    exit 0
  else
    fail "NVIDIA driver is required. Install it manually, or re-run and confirm."
  fi
fi

# =============================================================================
# STEP 2 — Docker CE
# =============================================================================
step "STEP 2/4 — Docker CE"

if command -v docker &>/dev/null; then
  DOCKER_VERSION=$(docker --version)
  ok "Docker already installed: ${DOCKER_VERSION}. Skipping — existing install is never upgraded or reconfigured."
else
  warn "Docker not found."

  if confirm "Install Docker CE from the official Docker repositories?"; then
    # Remove any legacy packages that may conflict
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
      apt-get remove -y "$pkg" 2>/dev/null || true
    done

    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker's official GPG key (--batch --yes: don't hang/fail if the
    # keyring file already exists from a prior partial run)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add the Docker stable repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker service
    systemctl enable --now docker

    ok "Docker CE installed and service started."
  else
    fail "Docker is required to run the vLLM container. Install it manually, or re-run and confirm."
  fi
fi

# Verify docker compose plugin
if ! docker compose version &>/dev/null; then
  warn "docker compose plugin not detected."
  if confirm "Install docker-compose-plugin?"; then
    apt-get install -y docker-compose-plugin
  else
    fail "docker compose plugin is required. Install it manually, or re-run and confirm."
  fi
fi
ok "Docker Compose plugin: $(docker compose version --short)"

# =============================================================================
# STEP 3 — NVIDIA Container Toolkit
# =============================================================================
step "STEP 3/4 — NVIDIA Container Toolkit"

if dpkg -s nvidia-container-toolkit 2>/dev/null | grep -q "ok installed"; then
  NCT_VERSION=$(dpkg -s nvidia-container-toolkit 2>/dev/null | awk -F': ' '/^Version:/{print $2}')
  ok "nvidia-container-toolkit already installed: ${NCT_VERSION}. Skipping — existing install is never upgraded."
else
  warn "nvidia-container-toolkit not found."

  if confirm "Install nvidia-container-toolkit (required for GPU passthrough to containers)?"; then
    # Add NVIDIA Container Toolkit repository.
    # --batch --yes: gpg --dearmor refuses to overwrite an existing keyring
    # file without confirmation, which would otherwise hang/fail on a
    # second run (e.g. after a first run's apt-get install itself failed
    # but the keyring was already written).
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
    ok "nvidia-container-toolkit installed."
  else
    fail "nvidia-container-toolkit is required for GPU passthrough to containers. Install it manually, or re-run and confirm."
  fi
fi

# --- Verify NVIDIA runtime is registered in Docker daemon.json ---------------
# jq is a hard dependency of this check (below) but is normally only
# installed in STEP 4 — install it here first if it's missing so a fresh,
# minimal Ubuntu install doesn't abort on "jq: command not found".
if ! command -v jq &>/dev/null; then
  warn "jq not found (required to check/register the NVIDIA Docker runtime)."
  if confirm "Install jq now?"; then
    apt-get update -qq
    apt-get install -y jq
  else
    fail "jq is required to configure the NVIDIA Docker runtime. Install it manually, or re-run and confirm."
  fi
fi

DAEMON_JSON="/etc/docker/daemon.json"
info "Verifying NVIDIA runtime is registered in ${DAEMON_JSON}..."

NEEDS_RUNTIME_CONFIG=false

if [[ ! -f "${DAEMON_JSON}" ]]; then
  warn "${DAEMON_JSON} does not exist."
  NEEDS_RUNTIME_CONFIG=true
elif ! jq -e '.runtimes.nvidia' "${DAEMON_JSON}" &>/dev/null; then
  warn "NVIDIA runtime not found in ${DAEMON_JSON}."
  NEEDS_RUNTIME_CONFIG=true
else
  ok "NVIDIA runtime already configured in ${DAEMON_JSON}. Leaving it untouched."
fi

if [[ "${NEEDS_RUNTIME_CONFIG}" == "true" ]]; then
  if confirm "Register the NVIDIA runtime in ${DAEMON_JSON} and restart the Docker daemon to apply it (this briefly stops any currently-running containers, e.g. an already-running vLLM server)?"; then
    # Generate NVIDIA runtime configuration via toolkit helper
    nvidia-ctk runtime configure --runtime=docker

    info "Restarting Docker daemon to apply runtime changes..."
    systemctl restart docker
    ok "Docker daemon restarted with NVIDIA runtime support."
  else
    fail "The NVIDIA runtime must be registered in ${DAEMON_JSON} for GPU passthrough. Configure it manually, or re-run and confirm."
  fi
fi

# Sanity-check: confirm the runtime block is now present
if jq -e '.runtimes.nvidia' "${DAEMON_JSON}" &>/dev/null; then
  ok "Confirmed: NVIDIA runtime present in ${DAEMON_JSON}."
else
  fail "Failed to register NVIDIA runtime. Inspect ${DAEMON_JSON} manually."
fi

# =============================================================================
# STEP 4 — System Tools
# =============================================================================
step "STEP 4/4 — System Tools (jq, python3, python3-pip, python3-venv)"

TOOLS=(jq python3 python3-pip python3-venv)
MISSING_TOOLS=()

for tool in "${TOOLS[@]}"; do
  if dpkg -s "${tool}" 2>/dev/null | grep -q "ok installed"; then
    ok "${tool} — already installed."
  else
    warn "${tool} — not found, queuing for installation."
    MISSING_TOOLS+=("${tool}")
  fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  if confirm "Install missing system tools (${MISSING_TOOLS[*]})?"; then
    apt-get update -qq
    apt-get install -y "${MISSING_TOOLS[@]}"
    ok "All missing tools installed."
  else
    fail "Required tools missing: ${MISSING_TOOLS[*]}. Install them manually, or re-run and confirm."
  fi
fi

# Verify python3 is callable and report version
PYTHON_VERSION=$(python3 --version 2>&1)
ok "Python runtime: ${PYTHON_VERSION}"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║       All prerequisites validated and satisfied.         ║${RESET}"
if [[ "${IN_DEPLOY_FLOW:-false}" != "true" ]]; then
  echo -e "${GREEN}${BOLD}║   Next step: bash scripts/deploy/validate-system.sh        ║${RESET}"
fi
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
