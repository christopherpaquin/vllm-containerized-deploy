#!/usr/bin/env bash
# =============================================================================
# setup-continue.sh
# Automated IDE Continue extension hook.
# Injects a vLLM endpoint into ~/.continue/config.yaml, creating the file
# with full defaults if it doesn't already exist.
#
# Run this on whichever machine has your IDE + Continue installed — that is
# not necessarily the machine hosting vLLM. On the vLLM host itself, no
# argument is needed (defaults to localhost:8000). From any other
# workstation on the network, pass that host's BIND_HOST:PORT:
#
# Usage:
#   bash setup-continue.sh                    # vLLM running on this machine
#   bash setup-continue.sh 192.168.1.50:8000  # vLLM running on another host
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Options -------------------------------------------------------------
ASSUME_YES=false
VLLM_HOST_ARG=""
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help)
      echo "Usage: bash scripts/deploy/setup-continue.sh [vllm-host] [-y|--yes]"
      echo "  vllm-host   Optional host[:port] of the vLLM server."
      echo "  -y, --yes   Auto-confirm prompts."
      exit 0
      ;;
    -*) ;;
    *) VLLM_HOST_ARG="${arg}" ;;
  esac
done

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  local reply
  if [[ -e /dev/tty ]]; then
    read -r -p "$(echo -e "${YELLOW}?${RESET} ${prompt} [y/N] ")" reply < /dev/tty || reply=""
  else
    read -r -p "$(echo -e "${YELLOW}?${RESET} ${prompt} [y/N] ")" reply || reply=""
  fi
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONTINUE_DIR="${HOME}/.continue"
CONFIG_FILE="${CONTINUE_DIR}/config.yaml"
BACKUP_FILE="${CONTINUE_DIR}/config.yaml.bak.$(date '+%Y%m%d_%H%M%S')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/scripts/deploy/.env"

# Resolve Host and Port
BIND_HOST=""
PORT=""

if [[ -n "${VLLM_HOST_ARG}" ]]; then
  if [[ "${VLLM_HOST_ARG}" == *:* ]]; then
    BIND_HOST="${VLLM_HOST_ARG%%:*}"
    PORT="${VLLM_HOST_ARG##*:}"
  else
    BIND_HOST="${VLLM_HOST_ARG}"
    PORT="8000"
  fi
  info "Using vLLM server address from command line argument: ${BIND_HOST}:${PORT}"
else
  # Read from .env if present
  ENV_HOST=""
  ENV_PORT=""
  if [[ -f "${ENV_FILE}" ]]; then
    ENV_HOST=$(grep '^BIND_HOST=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
    ENV_PORT=$(grep '^PORT=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  fi

  # Determine BIND_HOST
  if [[ -n "${ENV_HOST}" ]]; then
    SUGGESTED_HOST="${ENV_HOST}"
    if [[ "${ENV_HOST}" == "0.0.0.0" ]]; then
      SUGGESTED_HOST="127.0.0.1"
    fi
    if confirm "Use vLLM host IP found in scripts/deploy/.env (${SUGGESTED_HOST})?"; then
      BIND_HOST="${SUGGESTED_HOST}"
    fi
  fi

  if [[ -z "${BIND_HOST}" ]]; then
    if [[ "${ASSUME_YES}" == "true" ]]; then
      BIND_HOST="127.0.0.1"
    else
      reply=""
      if [[ -e /dev/tty ]]; then
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server IP/hostname [default: 127.0.0.1]: ")" reply < /dev/tty || reply=""
      else
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server IP/hostname [default: 127.0.0.1]: ")" reply || reply=""
      fi
      BIND_HOST="${reply:-127.0.0.1}"
    fi
  fi

  # Determine PORT
  if [[ -n "${ENV_PORT}" ]]; then
    if confirm "Use vLLM port found in scripts/deploy/.env (${ENV_PORT})?"; then
      PORT="${ENV_PORT}"
    fi
  fi

  if [[ -z "${PORT}" ]]; then
    if [[ "${ASSUME_YES}" == "true" ]]; then
      PORT="8000"
    else
      reply=""
      if [[ -e /dev/tty ]]; then
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server port [default: 8000]: ")" reply < /dev/tty || reply=""
      else
        read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM server port [default: 8000]: ")" reply || reply=""
      fi
      PORT="${reply:-8000}"
    fi
  fi
fi

VLLM_HOST="${BIND_HOST}:${PORT}"
VLLM_API_BASE="http://${VLLM_HOST}/v1"
MODEL_TITLE="Qwen2.5-Coder-32B (vLLM @ ${VLLM_HOST})"

# ---------------------------------------------------------------------------
# Model ID resolution strategy (in priority order):
#   1. Query the live /v1/models endpoint — uses the actual served-model-name
#      registered in docker-compose.yml (e.g. "qwen2.5-coder-32b-awq").
#      This is authoritative: it's what API requests must send in the "model"
#      field for vLLM to accept them.
#   2. Fall back to MODEL= in scripts/deploy/.env if the server is not yet running.
#      The raw HF path (e.g. "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ") is a
#      best-effort placeholder — it will NOT match unless served-model-name
#      is absent from docker-compose.yml.
# ---------------------------------------------------------------------------
MODEL_ID=""
if python3 -c "
import urllib.request, json, sys
try:
    r = urllib.request.urlopen('${VLLM_API_BASE}/models', timeout=5)
    d = json.loads(r.read())
    print(d['data'][0]['id'])
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  MODEL_ID=$(python3 -c "
import urllib.request, json, sys
try:
    r = urllib.request.urlopen('${VLLM_API_BASE}/models', timeout=5)
    d = json.loads(r.read())
    print(d['data'][0]['id'])
except Exception:
    sys.exit(1)
" 2>/dev/null)
  info "Resolved model name from live server: ${MODEL_ID}"
else
  # Server not running — read from .env as fallback
  if [[ -f "${ENV_FILE}" ]]; then
    MODEL_ID=$(grep '^MODEL=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' || true)
  fi
  MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
  warn "vLLM server is not reachable at ${VLLM_API_BASE}."
  warn "Using MODEL_ID from scripts/deploy/.env as fallback: ${MODEL_ID}"
  warn "Note: this may NOT match the served-model-name in docker-compose.yml."
  warn "Re-run this script once the server is up for an accurate config."
fi

# =============================================================================
# STEP 1 — Verify python3, PyYAML, and jq
# =============================================================================
step "STEP 1/4 — Dependency Check"

if ! command -v python3 &>/dev/null; then
  fail "python3 not found. Install it manually (e.g. apt install python3) or run scripts/prereqs/install-prereqs.sh if this is the vLLM host."
fi

if ! python3 -c "import yaml" &>/dev/null; then
  fail "python3 PyYAML package ('yaml') not found. Install it manually (e.g. apt install python3-yaml) or run scripts/prereqs/install-prereqs.sh if this is the vLLM host."
fi

if ! command -v jq &>/dev/null; then
  fail "jq not found. Install it manually (e.g. apt install jq) or run scripts/prereqs/install-prereqs.sh if this is the vLLM host."
fi

ok "python3, PyYAML, and jq are available."

# =============================================================================
# STEP 2 — Ensure ~/.continue/ directory exists
# =============================================================================
step "STEP 2/4 — Ensure ~/.continue/ Directory"

mkdir -p "${CONTINUE_DIR}"
ok "Directory ${CONTINUE_DIR} is ready."

# =============================================================================
# STEP 3 — Create or patch config.yaml
# =============================================================================
step "STEP 3/4 — Configure Continue config.yaml"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  # -------------------------------------------------------------------------
  # Brand new installation — write the complete default config
  # -------------------------------------------------------------------------
  info "${CONFIG_FILE} does not exist. Writing full default configuration..."

  cat > "${CONFIG_FILE}" <<YAMLEOF
name: Local Config
version: 1.0.0
schema: v1

models:
  - name: ${MODEL_TITLE}
    provider: openai
    model: ${MODEL_ID}
    apiBase: ${VLLM_API_BASE}
    apiKey: dummy
    roles:
      - chat
      - edit
      - apply
      - autocomplete
    defaultCompletionOptions:
      maxTokens: 1024
YAMLEOF

  ok "Default config.yaml written to ${CONFIG_FILE}."

else
  # -------------------------------------------------------------------------
  # Config already exists — safely inject our endpoint using Python+PyYAML
  # -------------------------------------------------------------------------
  info "${CONFIG_FILE} already exists. Backing up to ${BACKUP_FILE}..."
  cp "${CONFIG_FILE}" "${BACKUP_FILE}"
  ok "Backup saved: ${BACKUP_FILE}"

  info "Injecting local vLLM model entry into existing config..."

  set +e
  python3 - <<PYEOF
import sys
import yaml

config_path  = "${CONFIG_FILE}"
model_id     = "${MODEL_ID}"
api_base     = "${VLLM_API_BASE}"
model_title  = "${MODEL_TITLE}"

# Load existing config
try:
    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f)
except Exception as e:
    print(f"  [ERROR] {config_path} is not valid YAML: {e}", file=sys.stderr)
    sys.exit(1)

if not config:
    config = {}

# Ensure models array exists
if "models" not in config or not isinstance(config["models"], list):
    config["models"] = []

# Build new model entry
new_model = {
    "name": model_title,
    "provider": "openai",
    "model": model_id,
    "apiBase": api_base,
    "apiKey": "dummy",
    "roles": ["chat", "edit", "apply", "autocomplete"],
    "defaultCompletionOptions": {
        "maxTokens": 1024
    }
}

# Filter out old local vLLM entries to avoid duplicates
cleaned_models = []
already_configured = False

for m in config["models"]:
    if not isinstance(m, dict):
        cleaned_models.append(m)
        continue

    # Identify local vLLM models
    is_vllm = False
    if m.get("provider") == "openai":
        api_base_str = m.get("apiBase", "")
        if any(ip_prefix in api_base_str for ip_prefix in ["localhost", "127.0.0.1", "10.", "192.168.", "172."]):
            is_vllm = True
        elif "vLLM" in m.get("name", ""):
            is_vllm = True

        if m.get("apiBase") == api_base and m.get("model") == model_id and "defaultCompletionOptions" in m:
            already_configured = True
            cleaned_models.append(m)
    else:
        # Keep non-vLLM models (e.g. Claude)
        cleaned_models.append(m)

# If the exact model is already the first model, we can exit early
if already_configured and len(config["models"]) > 0 and config["models"][0].get("apiBase") == api_base:
    print("  [INFO] The exact local vLLM model is already configured. Exiting.")
    sys.exit(0)

# Prepend the new model entry
cleaned_models.insert(0, new_model)
config["models"] = cleaned_models

# Ensure name, version, and schema are set in root if not present
if "name" not in config:
    config["name"] = "Local Config"
if "version" not in config:
    config["version"] = "1.0.0"
if "schema" not in config:
    config["schema"] = "v1"

# Write back with clean formatting
try:
    with open(config_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)
    print(f"  [OK]  {config_path} updated successfully.")
except Exception as e:
    print(f"  [ERROR] Failed to write {config_path}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  PYTHON_STATUS=$?
  set -e

  if [[ "${PYTHON_STATUS}" -ne 0 ]]; then
    warn "Failed to update ${CONFIG_FILE}. Restoring backup from ${BACKUP_FILE}..."
    cp "${BACKUP_FILE}" "${CONFIG_FILE}"
    fail "config.yaml update failed and was rolled back. Fix the YAML syntax error above and re-run."
  fi
fi

# =============================================================================
# STEP 4 — Validate the final YAML
# =============================================================================
step "STEP 4/4 — Validate Config YAML Syntax"

if python3 -c "import yaml; yaml.safe_load(open('${CONFIG_FILE}'))" &>/dev/null; then
  ok "YAML validation passed — config.yaml is well-formed."
else
  if [[ -f "${BACKUP_FILE}" ]]; then
    warn "YAML validation FAILED. Restoring backup from ${BACKUP_FILE}..."
    cp "${BACKUP_FILE}" "${CONFIG_FILE}"
    warn "Restored backup. Inspect config.yaml and re-run the script."
  else
    warn "YAML validation FAILED. No backup file found to restore."
  fi
  fail "YAML validation FAILED. config.yaml is not well-formed."
fi

# Show summary of configured endpoints
echo ""
echo -e "${BOLD}  Continue Extension Configuration Summary:${RESET}"
echo -e "  Config file   : ${CONFIG_FILE}"
echo -e "  Model ID      : ${MODEL_ID}  (resolved from live server or .env)"
echo -e "  API Base      : ${VLLM_API_BASE}"
echo -e "  Roles         : chat, edit, apply, autocomplete"
echo ""

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   Continue extension is configured for local vLLM.          ║${RESET}"
echo -e "${GREEN}${BOLD}║   Reload VS Code window (Ctrl+Shift+P → Reload Window)      ║${RESET}"
echo -e "${GREEN}${BOLD}║   Next step: bash scripts/tuning/benchmark.sh                ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
