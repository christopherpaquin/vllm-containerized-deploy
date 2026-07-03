#!/usr/bin/env bash
# =============================================================================
# deploy.sh — vLLM Inference Server Deployment Orchestrator
#
# This script is the single entry point for deploying the vLLM stack.
# It wraps all other scripts in the correct order and handles merging
# user configuration with GPU-detected tuning.
#
# Usage:
#   sudo bash scripts/deploy/deploy.sh
#   (root is required — install-prereqs.sh, and enabling the Docker service
#   to survive a reboot, both need it)
#
# Prerequisites:
#   cp deploy/.env.example deploy/.env
#   $EDITOR deploy/.env          # set BIND_HOST, HF_CACHE_DIR at minimum
#
# What this does, in order:
#   1. Load and validate deploy/.env
#   2. Resolve BIND_HOST (auto-detect if not set)
#   3. If BIND_HOST is a non-loopback address, check for an active firewall
#      (ufw or firewalld) and open the API port if it isn't already allowed;
#      if no firewall is active, skip — there's nothing to configure
#   4. Run install-prereqs.sh   — idempotent; skips already-satisfied steps
#   5. Run validate-system.sh   — GPU + Docker connectivity; blocks on failure
#   6. Run check-bottlenecks.sh — advisory performance scan; never blocks
#   7. Run tune-inference.sh    — updates only the GPU-tuned keys in deploy/.env
#   8. Re-apply user vars on top of tuned .env (user settings always win)
#   9. Generate docker-compose.override.yml with fully-resolved vLLM command
#      (optional features like speculative decoding wired in only if set)
#  10. Ensure the Docker service is enabled at boot, so the container (which
#      has restart: unless-stopped) comes back up automatically after a
#      host reboot — not just after a plain container/daemon restart
#  11. Launch via docker compose up -d
#  12. Monitor startup: VRAM telemetry + log tailing until ready or OOM
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# Replace a key's value in deploy/.env in-place if the line exists, else
# append it. Used instead of blind appends so re-running deploy.sh never
# accumulates duplicate/stale key blocks in an existing .env.
set_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

# True if the given IPv4 address is loopback-only (127.0.0.0/8) and
# therefore never reachable from another machine on the network.
is_loopback() {
  [[ "$1" =~ ^127\. ]]
}

is_port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -tln | grep -q -E ":${port}\s"
  elif command -v netstat &>/dev/null; then
    netstat -tln | grep -q -E ":${port}\s"
  else
    # Fallback to bash tcp socket check
    (timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${port}") &>/dev/null
  fi
}

check_port_available() {
  local port="$1"
  local container_name="$2"

  if is_port_in_use "${port}"; then
    if docker ps --filter "name=^/${container_name}$" --filter "status=running" --format '{{.Names}}' | grep -q "^${container_name}$" 2>/dev/null; then
      info "Port ${port} is in use, but it is owned by the running container '${container_name}' which will be recreated."
    else
      fail "Port ${port} is already in use by another process. Please free the port before deploying."
    fi
  fi
}

export IN_DEPLOY_FLOW=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy-artifacts"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"
OVERRIDE_FILE="${DEPLOY_DIR}/docker-compose.override.yml"

# Paths to sibling scripts in other subdirs
SCRIPT_PREREQS="${REPO_ROOT}/scripts/prereqs"
SCRIPT_DEPLOY="${REPO_ROOT}/scripts/deploy"
SCRIPT_TUNING="${REPO_ROOT}/scripts/tuning"

# --- Privilege guard ---------------------------------------------------------
# Required end-to-end: install-prereqs.sh installs system packages, and
# enabling the Docker service to survive a reboot (below) needs systemctl.
if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root: sudo bash scripts/deploy/deploy.sh"
fi

# =============================================================================
# STEP 1 — Load deploy/.env
# =============================================================================
step "STEP 1/8 — Loading Configuration"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo -e ""
  echo -e "${RED}  deploy/.env not found.${RESET}"
  echo -e ""
  echo -e "  Create it from the example file and fill in your settings:"
  echo -e "    ${BOLD}cp deploy/.env.example deploy/.env${RESET}"
  echo -e "    ${BOLD}\$EDITOR deploy/.env${RESET}"
  echo -e ""
  echo -e "  Required fields: BIND_HOST, HF_CACHE_DIR"
  echo -e "  See deploy/.env.example for all options and guidance."
  echo -e ""
  fail "Aborting — deploy/.env must exist before running deploy.sh."
fi

# Source .env; tolerate vars that aren't defined yet (tune-inference adds them)
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}"
set -u

# Snapshot user-set values before tune-inference.sh rewrites the file
U_MODEL="${MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
U_SERVED_NAME="${SERVED_MODEL_NAME:-qwen2.5-coder-32b-awq}"
U_BIND_HOST="${BIND_HOST:-}"
U_PORT="${PORT:-8000}"
U_HF_CACHE="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
U_HF_TOKEN="${HF_TOKEN:-}"
# Optional feature vars (empty = disabled)
U_SPEC_MODEL="${SPECULATIVE_MODEL:-}"
U_SPEC_TOKENS="${NUM_SPECULATIVE_TOKENS:-5}"
U_DTYPE="${DTYPE:-}"
U_ENFORCE_EAGER="${ENFORCE_EAGER:-}"
U_MAX_NUM_SEQS="${MAX_NUM_SEQS:-}"

# Optional Open WebUI vars
U_ENABLE_OPEN_WEBUI="${ENABLE_OPEN_WEBUI:-false}"
U_OPEN_WEBUI_IMAGE="${OPEN_WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
U_OPEN_WEBUI_CONTAINER_NAME="${OPEN_WEBUI_CONTAINER_NAME:-open-webui}"
U_OPEN_WEBUI_HOST="${OPEN_WEBUI_HOST:-0.0.0.0}"
U_OPEN_WEBUI_PORT="${OPEN_WEBUI_PORT:-3000}"
U_OPEN_WEBUI_DATA_VOLUME="${OPEN_WEBUI_DATA_VOLUME:-open-webui-data}"
U_OPEN_WEBUI_API_BASE="${OPEN_WEBUI_OPENAI_API_BASE_URL:-http://vllm:8000/v1}"
U_OPEN_WEBUI_API_KEY="${OPEN_WEBUI_OPENAI_API_KEY:-}"
U_OPEN_WEBUI_RESTART_POLICY="${OPEN_WEBUI_RESTART_POLICY:-unless-stopped}"
U_VLLM_RESTART_POLICY="${VLLM_RESTART_POLICY:-unless-stopped}"
U_LAN_CIDR="${LAN_CIDR:-}"

# Validate ENABLE_OPEN_WEBUI
if [[ "${U_ENABLE_OPEN_WEBUI}" != "true" && "${U_ENABLE_OPEN_WEBUI}" != "false" ]]; then
  fail "ENABLE_OPEN_WEBUI in deploy/.env must be either 'true' or 'false' (found: '${U_ENABLE_OPEN_WEBUI}')."
fi

# Validate ports are valid integers
if ! [[ "${U_PORT}" =~ ^[0-9]+$ ]]; then
  fail "PORT (vLLM port) must be a valid integer (found: '${U_PORT}')."
fi
if ! [[ "${U_OPEN_WEBUI_PORT}" =~ ^[0-9]+$ ]]; then
  fail "OPEN_WEBUI_PORT must be a valid integer (found: '${U_OPEN_WEBUI_PORT}')."
fi

# Validate port conflict
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" && "${U_PORT}" -eq "${U_OPEN_WEBUI_PORT}" ]]; then
  fail "Conflict: vLLM PORT and OPEN_WEBUI_PORT cannot be the same (both are ${U_PORT})."
fi

ok "deploy/.env loaded."
info "Model         : ${U_MODEL}"
info "Served as     : ${U_SERVED_NAME}"
info "Port          : ${U_PORT}"
info "HF cache      : ${U_HF_CACHE}"
info "Open WebUI    : ${U_ENABLE_OPEN_WEBUI} (Port: ${U_OPEN_WEBUI_PORT})"

# =============================================================================
# STEP 2 — Resolve BIND_HOST
# =============================================================================
step "STEP 2/8 — Resolving Network Bind Address"

if [[ -z "${U_BIND_HOST}" ]]; then
  warn "BIND_HOST not set in deploy/.env — auto-detecting primary external IP..."
  # Preferred: IP that routes toward the internet (the primary LAN interface)
  DETECTED=$(ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
  # Fallback: first non-loopback IP from hostname -I
  [[ -z "${DETECTED}" ]] && DETECTED=$(hostname -I 2>/dev/null | awk '{print $1}' || true)

  if [[ -n "${DETECTED}" ]]; then
    U_BIND_HOST="${DETECTED}"
    warn "Auto-detected BIND_HOST=${U_BIND_HOST}"
    warn "Add BIND_HOST=${U_BIND_HOST} to deploy/.env to silence this message."
  else
    U_BIND_HOST="0.0.0.0"
    warn "Could not detect external IP — falling back to BIND_HOST=0.0.0.0 (all interfaces)."
  fi
else
  ok "BIND_HOST=${U_BIND_HOST}"
fi

# Sanity-check: must look like an IPv4 address
if ! echo "${U_BIND_HOST}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  fail "BIND_HOST '${U_BIND_HOST}' is not a valid IPv4 address."
fi

info "API will be reachable at: http://${U_BIND_HOST}:${U_PORT}/v1"

# =============================================================================
# STEP 3 — Firewall check (only relevant when reachable from the network)
# =============================================================================
step "STEP 3/8 — Checking Firewall Rules"

if is_loopback "${U_BIND_HOST}"; then
  info "BIND_HOST=${U_BIND_HOST} is loopback-only — not reachable from the network. Skipping firewall check."

elif command -v ufw &>/dev/null && ufw status | grep -q "^Status: active"; then
  info "ufw is active — checking inbound/outbound rules..."

  # 1. vLLM API Port Check & Add
  if ufw status | grep -q -E "${U_PORT}(/tcp)?\s+ALLOW"; then
    ok "ufw already allows inbound traffic on ${U_PORT}/tcp."
  else
    if [[ -n "${U_LAN_CIDR}" ]]; then
      warn "Adding ufw rule: allow proto tcp from ${U_LAN_CIDR} to any port ${U_PORT}..."
      ufw allow proto tcp from "${U_LAN_CIDR}" to any port "${U_PORT}" comment "vLLM API LAN (added by deploy.sh)"
    else
      warn "Adding ufw rule: allow in ${U_PORT}/tcp..."
      ufw allow in "${U_PORT}/tcp" comment "vLLM API (added by deploy.sh)"
    fi
    # Validation
    if ufw status | grep -q -E "${U_PORT}(/tcp)?\s+ALLOW"; then
      ok "Verified: vLLM API firewall rule is active."
    else
      fail "Failed to verify vLLM API firewall rule."
    fi
  fi

  # 2. Open WebUI Port Check & Add (when enabled)
  if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
    if ufw status | grep -q -E "${U_OPEN_WEBUI_PORT}(/tcp)?\s+ALLOW"; then
      ok "ufw already allows inbound traffic on ${U_OPEN_WEBUI_PORT}/tcp."
    else
      if [[ -n "${U_LAN_CIDR}" ]]; then
        warn "Adding ufw rule: allow proto tcp from ${U_LAN_CIDR} to any port ${U_OPEN_WEBUI_PORT}..."
        ufw allow proto tcp from "${U_LAN_CIDR}" to any port "${U_OPEN_WEBUI_PORT}" comment "Open WebUI LAN (added by deploy.sh)"
      else
        warn "Adding ufw rule: allow in ${U_OPEN_WEBUI_PORT}/tcp..."
        ufw allow in "${U_OPEN_WEBUI_PORT}/tcp" comment "Open WebUI (added by deploy.sh)"
      fi
      # Validation
      if ufw status | grep -q -E "${U_OPEN_WEBUI_PORT}(/tcp)?\s+ALLOW"; then
        ok "Verified: Open WebUI firewall rule is active."
      else
        fail "Failed to verify Open WebUI firewall rule."
      fi
    fi
  fi

  # 3. Outbound rules policy check
  if ufw status verbose | grep -qE "Default:.*deny \(outgoing\)"; then
    if ufw status | grep -qE "ALLOW OUT.*${U_PORT}/tcp"; then
      ok "ufw already allows outbound traffic on ${U_PORT}/tcp."
    else
      warn "ufw's default outgoing policy is deny. Adding an explicit outbound allow rule for vLLM..."
      ufw allow out "${U_PORT}/tcp" comment "vLLM API outbound (added by deploy.sh)"
      ok "Added: ufw allow out ${U_PORT}/tcp"
    fi
    if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
      if ufw status | grep -qE "ALLOW OUT.*${U_OPEN_WEBUI_PORT}/tcp"; then
        ok "ufw already allows outbound traffic on ${U_OPEN_WEBUI_PORT}/tcp."
      else
        warn "ufw's default outgoing policy is deny. Adding an explicit outbound allow rule for Open WebUI..."
        ufw allow out "${U_OPEN_WEBUI_PORT}/tcp" comment "Open WebUI outbound (added by deploy.sh)"
        ok "Added: ufw allow out ${U_OPEN_WEBUI_PORT}/tcp"
      fi
    fi
  else
    ok "ufw's default outgoing policy already allows outbound traffic — no outbound rules needed."
  fi

elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
  info "firewalld is active — checking inbound rules..."

  # 1. vLLM API Port Check & Add
  if [[ -n "${U_LAN_CIDR}" ]]; then
    if firewall-cmd --permanent --query-rich-rule="rule family='ipv4' source address='${U_LAN_CIDR}' port port='${U_PORT}' protocol='tcp' accept" &>/dev/null; then
      ok "firewalld already allows traffic on ${U_PORT}/tcp from ${U_LAN_CIDR}."
    else
      warn "Adding firewalld rich rule for port ${U_PORT} from ${U_LAN_CIDR}..."
      firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${U_LAN_CIDR}' port port='${U_PORT}' protocol='tcp' accept"
      firewall-cmd --reload
      # Validation
      if firewall-cmd --permanent --query-rich-rule="rule family='ipv4' source address='${U_LAN_CIDR}' port port='${U_PORT}' protocol='tcp' accept" &>/dev/null; then
        ok "Verified: firewalld restricted rule for ${U_PORT} is active."
      else
        fail "Failed to verify restricted firewalld rule for port ${U_PORT}."
      fi
    fi
  else
    if firewall-cmd --query-port="${U_PORT}/tcp" &>/dev/null; then
      ok "firewalld already allows traffic on ${U_PORT}/tcp."
    else
      warn "Adding firewalld port rule for ${U_PORT}/tcp..."
      firewall-cmd --permanent --add-port="${U_PORT}/tcp"
      firewall-cmd --reload
      # Validation
      if firewall-cmd --query-port="${U_PORT}/tcp" &>/dev/null; then
        ok "Verified: firewalld rule for port ${U_PORT}/tcp is active."
      else
        fail "Failed to verify firewalld rule for port ${U_PORT}/tcp."
      fi
    fi
  fi

  # 2. Open WebUI Port Check & Add (when enabled)
  if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
    if [[ -n "${U_LAN_CIDR}" ]]; then
      if firewall-cmd --permanent --query-rich-rule="rule family='ipv4' source address='${U_LAN_CIDR}' port port='${U_OPEN_WEBUI_PORT}' protocol='tcp' accept" &>/dev/null; then
        ok "firewalld already allows traffic on ${U_OPEN_WEBUI_PORT}/tcp from ${U_LAN_CIDR}."
      else
        warn "Adding firewalld rich rule for port ${U_OPEN_WEBUI_PORT} from ${U_LAN_CIDR}..."
        firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${U_LAN_CIDR}' port port='${U_OPEN_WEBUI_PORT}' protocol='tcp' accept"
        firewall-cmd --reload
        # Validation
        if firewall-cmd --permanent --query-rich-rule="rule family='ipv4' source address='${U_LAN_CIDR}' port port='${U_OPEN_WEBUI_PORT}' protocol='tcp' accept" &>/dev/null; then
          ok "Verified: firewalld restricted rule for ${U_OPEN_WEBUI_PORT} is active."
        else
          fail "Failed to verify restricted firewalld rule for port ${U_OPEN_WEBUI_PORT}."
        fi
      fi
    else
      if firewall-cmd --query-port="${U_OPEN_WEBUI_PORT}/tcp" &>/dev/null; then
        ok "firewalld already allows traffic on ${U_OPEN_WEBUI_PORT}/tcp."
      else
        warn "Adding firewalld port rule for ${U_OPEN_WEBUI_PORT}/tcp..."
        firewall-cmd --permanent --add-port="${U_OPEN_WEBUI_PORT}/tcp"
        firewall-cmd --reload
        # Validation
        if firewall-cmd --query-port="${U_OPEN_WEBUI_PORT}/tcp" &>/dev/null; then
          ok "Verified: firewalld rule for port ${U_OPEN_WEBUI_PORT}/tcp is active."
        else
          fail "Failed to verify firewalld rule for port ${U_OPEN_WEBUI_PORT}/tcp."
        fi
      fi
    fi
  fi
  info "firewalld's default zone permits outbound traffic — no separate outbound rules needed."

else
  info "No active firewall (ufw/firewalld) detected — nothing to configure."
fi

# =============================================================================
# STEP 4 — Prerequisites, system validation, and performance advisory
# =============================================================================
step "STEP 4/8 — System Checks"

info "Running install-prereqs.sh (idempotent — skips already-satisfied steps)..."
bash "${SCRIPT_PREREQS}/install-prereqs.sh"

info "Running validate-system.sh (GPU + Docker connectivity)..."
set +e
bash "${SCRIPT_DEPLOY}/validate-system.sh"
VALIDATION_STATUS=$?
set -e

if [[ ${VALIDATION_STATUS} -eq 2 ]]; then
  echo ""
  warn "Validation completed with warnings."
  read -rp "Validation warnings detected. Do you want to [c] Continue or [e] Exit deployment? [c/e]: " CHOICE
  if [[ ! "${CHOICE}" =~ ^[cC]$ ]]; then
    fail "Deployment aborted by user."
  fi
elif [[ ${VALIDATION_STATUS} -ne 0 ]]; then
  fail "Pre-flight validation failed (critical errors). Please address the errors above."
fi

info "Running check-bottlenecks.sh (performance advisory)..."
set +e
bash "${SCRIPT_TUNING}/check-bottlenecks.sh"
BOTTLENECK_STATUS=$?
set -e

if [[ ${BOTTLENECK_STATUS} -eq 2 ]]; then
  echo ""
  warn "Performance tuning recommendations found."

  # Check if there are actual implementable software tunables
  HAS_GOVERNOR_ISSUE=false
  if [[ -e "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" ]]; then
    if grep -q "powersave" /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null; then
      HAS_GOVERNOR_ISSUE=true
    fi
  fi

  HAS_PERSISTENCE_ISSUE=false
  if command -v nvidia-smi &>/dev/null; then
    if nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | grep -q "Disabled"; then
      HAS_PERSISTENCE_ISSUE=true
    fi
  fi

  HAS_THP_ISSUE=false
  if [[ -r "/sys/kernel/mm/transparent_hugepage/enabled" ]]; then
    if ! grep -q "\[always\]" /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
      HAS_THP_ISSUE=true
    fi
  fi

  if [[ "${HAS_GOVERNOR_ISSUE}" == "true" || "${HAS_PERSISTENCE_ISSUE}" == "true" || "${HAS_THP_ISSUE}" == "true" ]]; then
    read -rp "Tuning bottlenecks detected. Do you want to [c] Continue, [i] Implement tunables, or [e] Exit deployment? [c/i/e]: " CHOICE
    if [[ "${CHOICE}" =~ ^[iI]$ ]]; then
      info "Applying performance tunables..."
      # 1. Switch CPU governor to performance
      if [[ "${HAS_GOVERNOR_ISSUE}" == "true" ]]; then
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null || true
      fi
      # 2. Enable GPU persistence mode
      if [[ "${HAS_PERSISTENCE_ISSUE}" == "true" ]]; then
        nvidia-smi -pm 1 >/dev/null || true
      fi
      # 3. Enable Transparent Huge Pages
      if [[ "${HAS_THP_ISSUE}" == "true" ]]; then
        echo "always" | tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null || true
      fi
      ok "Performance tunables applied successfully."
    elif [[ "${CHOICE}" =~ ^[eE]$ ]] || [[ ! "${CHOICE}" =~ ^[cC]$ ]]; then
      fail "Deployment aborted by user."
    fi
  else
    # No software tunables, only physical hardware warnings (e.g. PCIe)
    read -rp "Hardware bottlenecks detected. Do you want to [c] Continue or [e] Exit deployment? [c/e]: " CHOICE
    if [[ ! "${CHOICE}" =~ ^[cC]$ ]]; then
      fail "Deployment aborted by user."
    fi
  fi
elif [[ ${BOTTLENECK_STATUS} -ne 0 ]]; then
  fail "Performance advisory script failed with critical errors."
fi

# =============================================================================
# STEP 5 — GPU-tuned configuration
# =============================================================================
step "STEP 5/8 — Generating Tuned GPU Configuration"

info "Running tune-inference.sh (detects GPU topology, writes deploy/.env)..."
# Export user's model so tune-inference.sh respects it instead of using its default
export MODEL="${U_MODEL}"
export SERVED_MODEL_NAME="${U_SERVED_NAME}"
bash "${SCRIPT_TUNING}/tune-inference.sh"

# Re-apply user settings on top of what tune-inference.sh wrote.
# tune-inference.sh owns GPU vars; we own network + model identity.
# Updated in-place (not appended) so re-running deploy.sh never piles up
# duplicate key blocks in an existing deploy/.env.
set_env_var BIND_HOST         "${U_BIND_HOST}"
set_env_var MODEL             "${U_MODEL}"
set_env_var SERVED_MODEL_NAME "${U_SERVED_NAME}"
set_env_var PORT              "${U_PORT}"
set_env_var HF_CACHE_DIR      "${U_HF_CACHE}"
[[ -n "${U_HF_TOKEN}" ]] && set_env_var HF_TOKEN "${U_HF_TOKEN}"
set_env_var ENABLE_OPEN_WEBUI          "${U_ENABLE_OPEN_WEBUI}"
set_env_var OPEN_WEBUI_IMAGE           "${U_OPEN_WEBUI_IMAGE}"
set_env_var OPEN_WEBUI_CONTAINER_NAME  "${U_OPEN_WEBUI_CONTAINER_NAME}"
set_env_var OPEN_WEBUI_HOST            "${U_OPEN_WEBUI_HOST}"
set_env_var OPEN_WEBUI_PORT            "${U_OPEN_WEBUI_PORT}"
set_env_var OPEN_WEBUI_DATA_VOLUME     "${U_OPEN_WEBUI_DATA_VOLUME}"
set_env_var OPEN_WEBUI_OPENAI_API_BASE_URL "${U_OPEN_WEBUI_API_BASE}"
set_env_var OPEN_WEBUI_OPENAI_API_KEY  "${U_OPEN_WEBUI_API_KEY}"
set_env_var OPEN_WEBUI_RESTART_POLICY  "${U_OPEN_WEBUI_RESTART_POLICY}"
set_env_var VLLM_RESTART_POLICY        "${U_VLLM_RESTART_POLICY}"
[[ -n "${U_LAN_CIDR}" ]] && set_env_var LAN_CIDR "${U_LAN_CIDR}"

ok "Configuration finalised. GPU-tuned values + user settings merged."

# Re-source to pick up the GPU vars tune-inference.sh wrote
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}"
set -u
FINAL_TP="${TENSOR_PARALLEL_SIZE:-2}"
FINAL_GPU_UTIL="${GPU_MEMORY_UTILIZATION:-0.90}"
FINAL_CTX="${MAX_MODEL_LEN:-16384}"
FINAL_QUANT="${QUANTIZATION:-awq}"

info "Tensor parallel size    : ${FINAL_TP}"
info "GPU memory utilization  : ${FINAL_GPU_UTIL}"
info "Max context length      : ${FINAL_CTX} tokens"

# =============================================================================
# STEP 6 — Generate docker-compose.override.yml
# =============================================================================
step "STEP 6/8 — Building Compose Override"

# The override is regenerated on every deploy run so optional features stay
# in sync with whatever is in deploy/.env at deploy time.
# It is gitignored and must not be committed.

# Build optional vLLM args (only args for features the user actually enabled)
OPT_ARGS=""

if [[ -n "${U_SPEC_MODEL}" ]]; then
  OPT_ARGS="${OPT_ARGS}      --speculative-model       ${U_SPEC_MODEL}
      --num-speculative-tokens  ${U_SPEC_TOKENS}
"
  info "Speculative decoding : ENABLED (${U_SPEC_MODEL}, ${U_SPEC_TOKENS} tokens)"
fi

if [[ -n "${U_DTYPE}" ]]; then
  OPT_ARGS="${OPT_ARGS}      --dtype                   ${U_DTYPE}
"
  info "dtype override       : ${U_DTYPE}"
fi

if [[ "${U_ENFORCE_EAGER}" == "true" ]]; then
  OPT_ARGS="${OPT_ARGS}      --enforce-eager
"
  warn "ENFORCE_EAGER=true — CUDA graph capture disabled (slower inference)"
fi

if [[ -n "${U_MAX_NUM_SEQS}" ]]; then
  OPT_ARGS="${OPT_ARGS}      --max-num-seqs            ${U_MAX_NUM_SEQS}
"
  info "Max concurrent seqs  : ${U_MAX_NUM_SEQS}"
fi

# Write override — all values are literal (already resolved), no compose substitution
cat > "${OVERRIDE_FILE}" << YAML_EOF
# =============================================================================
# docker-compose.override.yml — AUTO-GENERATED by scripts/deploy.sh
# DO NOT EDIT BY HAND. Re-run 'sudo bash scripts/deploy/deploy.sh' to regenerate.
# This file is gitignored and must not be committed.
# =============================================================================
services:
  vllm:
    ports:
      - "${U_BIND_HOST}:${U_PORT}:8000"
    restart: "${U_VLLM_RESTART_POLICY}"
    command: >
      --model                  ${U_MODEL}
      --tensor-parallel-size   ${FINAL_TP}
      --quantization           ${FINAL_QUANT}
      --max-model-len          ${FINAL_CTX}
      --gpu-memory-utilization ${FINAL_GPU_UTIL}
      --host                   0.0.0.0
      --port                   8000
      --served-model-name      ${U_SERVED_NAME}
      --no-enable-log-requests
${OPT_ARGS}
YAML_EOF

if [[ -n "${SUDO_USER:-}" ]]; then
  chown "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${OVERRIDE_FILE}" 2>/dev/null || true
fi
chmod 664 "${OVERRIDE_FILE}" 2>/dev/null || true

ok "docker-compose.override.yml written."
info "Port binding  : ${U_BIND_HOST}:${U_PORT} → container:8000"

# =============================================================================
# STEP 7 — Ensure boot persistence (Ubuntu / systemd)
# =============================================================================
step "STEP 7/8 — Ensuring Boot Persistence"

# docker-compose.yml sets `restart: unless-stopped` on the vllm service, so
# once the Docker daemon comes up, Docker restarts the container for us.
# The one thing that has to be true for that to also cover a full host
# reboot is that the Docker service itself is enabled to start at boot —
# install-prereqs.sh only enables it when installing Docker for the first
# time, so an already-installed Docker daemon may still be boot-disabled.
if systemctl is-enabled --quiet docker 2>/dev/null; then
  ok "docker.service is enabled at boot."
else
  warn "docker.service is not enabled at boot. Enabling it now..."
  systemctl enable docker || fail "Failed to enable docker.service at boot."
  ok "docker.service enabled."
fi

# =============================================================================
# STEP 8 — Launch and monitor
# =============================================================================
step "STEP 8/8 — Launching vLLM Server"

if ! command -v docker &>/dev/null; then
  fail "Docker is not installed or not in PATH. Run scripts/prereqs/install-prereqs.sh first."
fi
if ! docker compose version &>/dev/null; then
  fail "Docker Compose (v2) is not available. Ensure the docker-compose-plugin is installed."
fi

CONTAINER_NAME="vllm-coder-server"

# Sourcing both Compose files if Open WebUI is enabled
COMPOSE_DOWN_ARGS=("--env-file" "${ENV_FILE}" "-f" "${COMPOSE_FILE}" "-f" "${OVERRIDE_FILE}")
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
  COMPOSE_DOWN_ARGS+=("-f" "${REPO_ROOT}/deploy-artifacts/docker-compose.open-webui.yml")
fi

# Get the current Docker Compose project name (corresponds to directory name containing the Compose file)
PROJECT_NAME=$(basename "$(dirname "${COMPOSE_FILE}")")

# Inspect existing container status and project labels
if ! CONTAINER_STATE=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null); then
  CONTAINER_STATE="absent"
fi

WEBUI_STATE="absent"
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
  if ! WEBUI_STATE=$(docker inspect --format='{{.State.Status}}' "${U_OPEN_WEBUI_CONTAINER_NAME}" 2>/dev/null); then
    WEBUI_STATE="absent"
  fi
fi

VLLM_PROJECT=""
if [[ "${CONTAINER_STATE}" != "absent" ]]; then
  VLLM_PROJECT=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${CONTAINER_NAME}" 2>/dev/null || true)
fi

WEBUI_PROJECT=""
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" && "${WEBUI_STATE}" != "absent" ]]; then
  WEBUI_PROJECT=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${U_OPEN_WEBUI_CONTAINER_NAME}" 2>/dev/null || true)
fi

# Clean up existing containers only if they belong to a different project (preventing naming conflicts)
# or if they are in a broken state (exited/dead/restarting).
if [[ "${CONTAINER_STATE}" != "absent" ]]; then
  if [[ "${VLLM_PROJECT}" != "${PROJECT_NAME}" || \
        "${CONTAINER_STATE}" == "exited" || \
        "${CONTAINER_STATE}" == "dead" || \
        "${CONTAINER_STATE}" == "restarting" ]]; then
    warn "Removing container '${CONTAINER_NAME}' (status: ${CONTAINER_STATE}, project: ${VLLM_PROJECT:-none}) to prevent conflict..."
    docker rm -f "${CONTAINER_NAME}" &>/dev/null || true
    CONTAINER_STATE="absent"
  fi
fi

if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" && "${WEBUI_STATE}" != "absent" ]]; then
  if [[ "${WEBUI_PROJECT}" != "${PROJECT_NAME}" || \
        "${WEBUI_STATE}" == "exited" || \
        "${WEBUI_STATE}" == "dead" || \
        "${WEBUI_STATE}" == "restarting" ]]; then
    warn "Removing container '${U_OPEN_WEBUI_CONTAINER_NAME}' (status: ${WEBUI_STATE}, project: ${WEBUI_PROJECT:-none}) to prevent conflict..."
    docker rm -f "${U_OPEN_WEBUI_CONTAINER_NAME}" &>/dev/null || true
    WEBUI_STATE="absent"
  fi
fi

# Port availability and conflict checks
check_port_available "${U_PORT}" "${CONTAINER_NAME}"
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
  check_port_available "${U_OPEN_WEBUI_PORT}" "${U_OPEN_WEBUI_CONTAINER_NAME}"
fi

info "Starting container stack..."
COMPOSE_UP_ARGS=("--env-file" "${ENV_FILE}" "-f" "${COMPOSE_FILE}" "-f" "${OVERRIDE_FILE}")
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
  COMPOSE_UP_ARGS+=("-f" "${REPO_ROOT}/deploy-artifacts/docker-compose.open-webui.yml")
fi

if ! docker compose "${COMPOSE_UP_ARGS[@]}" up -d; then
  fail "Docker Compose deployment failed to start the services."
fi

ok "Container stack started. Monitoring startup (model load typically takes 2–5 min)..."
echo ""

# --- Inline startup monitor --------------------------------------------------
STARTUP_TIMEOUT=300   # seconds; 32B over USB3/NVMe can be slow
POLL_INTERVAL=5
ELAPSED=0
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 0)

while [[ "${ELAPSED}" -lt "${STARTUP_TIMEOUT}" ]]; do
  sleep "${POLL_INTERVAL}"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))

  # VRAM bar display
  if [[ "${GPU_COUNT}" -gt 0 ]]; then
    printf "  [%3ds] " "${ELAPSED}"
    for i in $(seq 0 $(( GPU_COUNT - 1 ))); do
      USED=$(nvidia-smi  -i "$i" --query-gpu=memory.used  --format=csv,noheader,nounits | xargs)
      TOTAL=$(nvidia-smi -i "$i" --query-gpu=memory.total --format=csv,noheader,nounits | xargs)
      PCT=$(( USED * 100 / TOTAL ))
      FILLED=$(( PCT / 5 )); EMPTY=$(( 20 - FILLED ))
      BAR="$(printf '█%.0s' $(seq 1 ${FILLED} 2>/dev/null))$(printf '░%.0s' $(seq 1 ${EMPTY} 2>/dev/null))"
      printf "GPU%d [%s] %5d/%-5d MiB  " "$i" "${BAR}" "${USED}" "${TOTAL}"
    done
    echo ""
  fi

  LOGS=$(docker logs "${CONTAINER_NAME}" 2>&1 | tail -8)

  if echo "${LOGS}" | grep -q "Uvicorn running on"; then
    echo ""
    ok "vLLM server is UP!"
    break
  fi

  if echo "${LOGS}" | grep -qiE "(cuda out of memory|out of memory|OOM)"; then
    echo ""
    fail "OOM detected. Reduce MAX_MODEL_LEN or GPU_MEMORY_UTILIZATION in deploy/.env and re-run."
  fi
done

if [[ "${ELAPSED}" -ge "${STARTUP_TIMEOUT}" ]]; then
  echo ""
  warn "Server did not signal readiness within ${STARTUP_TIMEOUT}s."
  warn "The model may still be loading — 32B models can take 5+ min from cold storage."
  echo ""
  info "Watch logs : docker compose ${COMPOSE_UP_ARGS[*]} logs -f"
  info "Check VRAM : bash scripts/deploy/validate-vram.sh"
  exit 1
fi

# =============================================================================
# Post-deployment Validation
# =============================================================================
step "Post-deployment Validation"

# 1. Check Docker service boot persistence
if systemctl is-enabled --quiet docker 2>/dev/null; then
  ok "Docker is enabled to start at boot."
else
  fail "Docker service is not enabled to start at boot."
fi

# 2. Check vLLM container status
VLLM_STATUS=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "absent")
if [[ "${VLLM_STATUS}" == "running" ]]; then
  ok "vLLM container '${CONTAINER_NAME}' is running."
else
  fail "vLLM container '${CONTAINER_NAME}' is not running (status: ${VLLM_STATUS})."
fi

# 3. Check vLLM restart policy
VLLM_RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
if [[ "${VLLM_RESTART}" == "${U_VLLM_RESTART_POLICY}" ]]; then
  ok "vLLM container restart policy is '${U_VLLM_RESTART_POLICY}'."
else
  fail "vLLM container restart policy is '${VLLM_RESTART}' (expected: '${U_VLLM_RESTART_POLICY}')."
fi

# 4. Check vLLM API endpoint
info "Querying vLLM API models endpoint..."
if curl -sf "http://localhost:${U_PORT}/v1/models" >/dev/null; then
  ok "vLLM API endpoint is responding successfully."
else
  fail "vLLM API endpoint failed to respond at http://localhost:${U_PORT}/v1/models"
fi

# 5. Optional Open WebUI validations
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
  # Check Open WebUI container status
  WEBUI_STATUS=$(docker inspect --format='{{.State.Status}}' "${U_OPEN_WEBUI_CONTAINER_NAME}" 2>/dev/null || echo "absent")
  if [[ "${WEBUI_STATUS}" == "running" ]]; then
    ok "Open WebUI container '${U_OPEN_WEBUI_CONTAINER_NAME}' is running."
  else
    fail "Open WebUI container '${U_OPEN_WEBUI_CONTAINER_NAME}' is not running (status: ${WEBUI_STATUS})."
  fi

  # Check Open WebUI restart policy
  WEBUI_RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${U_OPEN_WEBUI_CONTAINER_NAME}" 2>/dev/null || echo "unknown")
  if [[ "${WEBUI_RESTART}" == "${U_OPEN_WEBUI_RESTART_POLICY}" ]]; then
    ok "Open WebUI container restart policy is '${U_OPEN_WEBUI_RESTART_POLICY}'."
  else
    fail "Open WebUI container restart policy is '${WEBUI_RESTART}' (expected: '${U_OPEN_WEBUI_RESTART_POLICY}')."
  fi

  # Check Open WebUI HTTP endpoint responds
  info "Querying Open WebUI HTTP endpoint..."
  if curl -sf "http://localhost:${U_OPEN_WEBUI_PORT}" >/dev/null || curl -sfI "http://localhost:${U_OPEN_WEBUI_PORT}" >/dev/null; then
    ok "Open WebUI endpoint is responding successfully."
  else
    fail "Open WebUI HTTP endpoint failed to respond at http://localhost:${U_OPEN_WEBUI_PORT}"
  fi

  # Validate Open WebUI can reach vLLM container
  info "Verifying container-to-container connectivity..."
  if docker exec "${U_OPEN_WEBUI_CONTAINER_NAME}" which curl &>/dev/null; then
    if docker exec "${U_OPEN_WEBUI_CONTAINER_NAME}" curl -sf "${U_OPEN_WEBUI_API_BASE}/models" >/dev/null; then
      ok "Open WebUI container successfully reached vLLM container via ${U_OPEN_WEBUI_API_BASE}."
    else
      warn "Open WebUI container could not reach vLLM via ${U_OPEN_WEBUI_API_BASE} inside the Docker network."
    fi
  elif docker exec "${U_OPEN_WEBUI_CONTAINER_NAME}" python3 -c "import urllib.request; urllib.request.urlopen('${U_OPEN_WEBUI_API_BASE}/models')" &>/dev/null; then
    ok "Open WebUI container successfully reached vLLM container via ${U_OPEN_WEBUI_API_BASE} (verified via python3)."
  else
    warn "Could not verify container-to-container connectivity (curl/python3 unavailable or connection failed)."
  fi
fi

echo ""
ok "All post-deployment validations passed!"
echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Deployment successful.                                        ║${RESET}"
echo -e "${GREEN}${BOLD}║                                                                ║${RESET}"
printf  "${GREEN}${BOLD}║  vLLM API      : http://%-38s║${RESET}\n" "${U_BIND_HOST}:${U_PORT}/v1"
if [[ "${U_ENABLE_OPEN_WEBUI}" == "true" ]]; then
  printf  "${GREEN}${BOLD}║  Open WebUI    : http://%-38s║${RESET}\n" "${U_BIND_HOST}:${U_OPEN_WEBUI_PORT}"
fi
echo -e "${GREEN}${BOLD}║                                                                ║${RESET}"
echo -e "${GREEN}${BOLD}║  Next steps:                                                   ║${RESET}"
echo -e "${GREEN}${BOLD}║    bash scripts/deploy/setup-continue.sh — configure VS Code   ║${RESET}"
echo -e "${GREEN}${BOLD}║    bash scripts/tuning/benchmark.sh      — verify throughput   ║${RESET}"
echo -e "${GREEN}${BOLD}║    bash scripts/deploy/stop.sh           — graceful shutdown   ║${RESET}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
exit 0
