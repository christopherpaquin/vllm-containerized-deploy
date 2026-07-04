#!/usr/bin/env bash
# =============================================================================
# setup-zed.sh
# Automated Zed IDE local model configuration utility.
# Injects the vLLM custom model endpoint into ~/.config/zed/settings.json.
#
# Usage:
#   bash scripts/deploy/setup-zed.sh                    # Use defaults from local .env
#   bash scripts/deploy/setup-zed.sh 10.1.10.17:8000    # Point to a specific server address
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
      echo "Usage: bash scripts/deploy/setup-zed.sh [vllm-host] [-y|--yes]"
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
CONFIG_DIR="${HOME}/.config/zed"
CONFIG_FILE="${CONFIG_DIR}/settings.json"
BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Default values if .env is missing or has defaults
BIND_HOST="localhost"
PORT="8000"
MODEL_ID="qwen2.5-coder-14b-awq"
MAX_MODEL_LEN=32768

ENV_FILE="$(dirname "$0")/../../scripts/deploy/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # Squelch unbound variable errors by sourcing with fallbacks
  set +u
  # Extract specific variables from .env to avoid collision
  ENV_BIND_HOST=$(grep -E "^BIND_HOST=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  ENV_PORT=$(grep -E "^PORT=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  ENV_MODEL_NAME=$(grep -E "^SERVED_MODEL_NAME=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  ENV_MAX_LEN=$(grep -E "^MAX_MODEL_LEN=" "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")
  set -u

  [[ -n "${ENV_BIND_HOST}" ]] && BIND_HOST="${ENV_BIND_HOST}"
  [[ -n "${ENV_PORT}" ]] && PORT="${ENV_PORT}"
  [[ -n "${ENV_MODEL_NAME}" ]] && MODEL_ID="${ENV_MODEL_NAME}"
  [[ -n "${ENV_MAX_LEN}" ]] && MAX_MODEL_LEN="${ENV_MAX_LEN}"
fi

# Override values from command-line argument if passed
if [[ -n "${VLLM_HOST_ARG}" ]]; then
  if [[ "${VLLM_HOST_ARG}" =~ : ]]; then
    BIND_HOST=$(echo "${VLLM_HOST_ARG}" | cut -d: -f1)
    PORT=$(echo "${VLLM_HOST_ARG}" | cut -d: -f2)
  else
    BIND_HOST="${VLLM_HOST_ARG}"
  fi
fi

# Treat BIND_HOST="0.0.0.0" as localhost for client convenience
if [[ "${BIND_HOST}" == "0.0.0.0" ]]; then
  BIND_HOST="localhost"
fi

step "STEP 1/3 — Dependency Check"
if ! command -v python3 &>/dev/null; then
  fail "python3 is required but not installed."
fi
ok "python3 is available."

step "STEP 2/3 — Resolve vLLM Configuration"
VLLM_API_BASE="http://${BIND_HOST}:${PORT}/v1"
info "vLLM server target: ${BIND_HOST}:${PORT}"

# Query the live model ID from vLLM endpoint if reachable
info "Checking live model ID at http://${BIND_HOST}:${PORT}/v1..."
LIVE_MODEL=""
if command -v curl &>/dev/null && command -v jq &>/dev/null; then
  if LIVE_MODEL=$(curl -s --max-time 3 "${VLLM_API_BASE}/models" | jq -r '.data[0].id' 2>/dev/null) && [[ -n "${LIVE_MODEL}" ]] && [[ "${LIVE_MODEL}" != "null" ]]; then
    MODEL_ID="${LIVE_MODEL}"
    # Fetch live max model length if query succeeds
    if LIVE_MAX_LEN=$(curl -s --max-time 3 "${VLLM_API_BASE}/models" | jq -r '.data[0].max_model_len' 2>/dev/null) && [[ -n "${LIVE_MAX_LEN}" ]] && [[ "${LIVE_MAX_LEN}" != "null" ]]; then
      MAX_MODEL_LEN="${LIVE_MAX_LEN}"
    fi
    ok "Resolved model name from live server: ${MODEL_ID} (Context limit: ${MAX_MODEL_LEN})"
  else
    warn "vLLM server not responding yet. Falling back to configured default: ${MODEL_ID} (${MAX_MODEL_LEN} context)"
  fi
else
  warn "curl or jq missing. Skipping live check, falling back to configured: ${MODEL_ID} (${MAX_MODEL_LEN} context)"
fi

step "STEP 3/3 — Configure Zed Settings"
if [[ ! -d "${CONFIG_DIR}" ]]; then
  mkdir -p "${CONFIG_DIR}"
  ok "Created Zed configuration directory: ${CONFIG_DIR}"
fi

if [[ -f "${CONFIG_FILE}" ]]; then
  info "Backing up ${CONFIG_FILE} to ${BACKUP_FILE}..."
  cp "${CONFIG_FILE}" "${BACKUP_FILE}"
  ok "Backup saved: ${BACKUP_FILE}"
fi

# Ingress JSONC stripping and patch injection using Python
python3 - <<PYEOF
import sys
import os
import json
import re

config_path = "${CONFIG_FILE}"
api_base = "${VLLM_API_BASE}"
model_id = "${MODEL_ID}"
max_tokens = int("${MAX_MODEL_LEN}")

# Helper to clean comments and trailing commas from Zed settings JSONC
def clean_jsonc(text):
    # Remove block comments
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    # Remove line comments
    text = re.sub(r'(?<!:)//.*', '', text)
    # Remove trailing commas
    text = re.sub(r',\s*([\]}])', r'\1', text)
    return text

config = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            raw_content = f.read()
        cleaned_content = clean_jsonc(raw_content)
        if cleaned_content.strip():
            config = json.loads(cleaned_content)
    except Exception as e:
        print(f"  [ERROR] {config_path} parsing failed: {e}", file=sys.stderr)
        sys.exit(1)

# Ensure required configuration structures exist
if "language_models" not in config:
    config["language_models"] = {}
if "openai" not in config["language_models"]:
    config["language_models"]["openai"] = {}

# Configure the local OpenAI provider details
openai_provider = config["language_models"]["openai"]
openai_provider.pop("api_base", None)
openai_provider.pop("api_key", None)
openai_provider["api_url"] = api_base

# Update/insert the available models list
available_models = openai_provider.get("available_models", [])
if not isinstance(available_models, list):
    available_models = []

# Build model entry
display_name = "Qwen 2.5 Coder 14B (Local)" if "14b" in model_id else "Qwen 2.5 Coder (Local)"
new_model_entry = {
    "name": model_id,
    "display_name": display_name,
    "max_tokens": max_tokens
}

# Avoid duplicate model registration in available_models
cleaned_models = [m for m in available_models if isinstance(m, dict) and m.get("name") != model_id]
cleaned_models.insert(0, new_model_entry)
openai_provider["available_models"] = cleaned_models

# Set as default assistant model
if "assistant" not in config:
    config["assistant"] = {}
config["assistant"]["default_model"] = {
    "provider": "openai",
    "model": model_id
}
config["assistant"]["version"] = "2"

# Save updated config
try:
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)
    print("  [OK] Successfully updated ~/.config/zed/settings.json")
except Exception as e:
    print(f"  [ERROR] Writing {config_path} failed: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Zed IDE is configured for local vLLM.                      ║"
echo "║   The assistant panel will now use Qwen 2.5 Coder.           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
