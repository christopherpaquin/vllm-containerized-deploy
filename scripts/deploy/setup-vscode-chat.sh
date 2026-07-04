#!/usr/bin/env bash
# =============================================================================
# setup-vscode-chat.sh
# Injects the vLLM custom endpoint into ~/.config/Code/User/chatLanguageModels.json
# for VS Code native Copilot/Chat integrations.
#
# Usage:
#   bash scripts/deploy/setup-vscode-chat.sh [vllm-host] [-y|--yes]
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
      echo "Usage: bash scripts/deploy/setup-vscode-chat.sh [vllm-host] [-y|--yes]"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# =============================================================================
# STEP 1 — Dependency Check
# =============================================================================
step "STEP 1/3 — Dependency Check"

if ! command -v python3 &>/dev/null; then
  fail "python3 not found. Please install it."
fi

if ! command -v jq &>/dev/null; then
  fail "jq not found. Please install it."
fi

ok "python3 and jq are available."

# =============================================================================
# STEP 2 — Resolve vLLM Server Settings (IP/Port/Model)
# =============================================================================
step "STEP 2/3 — Resolve vLLM Configuration"

# Resolve Host, Port, Model, and Max Model Len
BIND_HOST=""
PORT=""
MODEL_ID=""
MAX_MODEL_LEN=""

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

# Load other defaults/configs from .env if it exists
ENV_MAX_LEN=""
if [[ -f "${ENV_FILE}" ]]; then
  ENV_MAX_LEN=$(grep '^MAX_MODEL_LEN=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  MODEL_ID=$(grep '^SERVED_MODEL_NAME=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  if [[ -z "${MODEL_ID}" ]]; then
    MODEL_ID=$(grep '^MODEL=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "")
  fi
fi

# Determine MAX_MODEL_LEN
if [[ -n "${ENV_MAX_LEN}" ]]; then
  if confirm "Use vLLM maximum context length found in scripts/deploy/.env (${ENV_MAX_LEN} tokens)?"; then
    MAX_MODEL_LEN="${ENV_MAX_LEN}"
  fi
fi

if [[ -z "${MAX_MODEL_LEN}" ]]; then
  if [[ "${ASSUME_YES}" == "true" ]]; then
    MAX_MODEL_LEN="6144"
  else
    reply=""
    if [[ -e /dev/tty ]]; then
      read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM maximum context length (tokens) [default: 6144]: ")" reply < /dev/tty || reply=""
    else
      read -r -p "$(echo -e "${YELLOW}?${RESET} Enter the vLLM maximum context length (tokens) [default: 6144]: ")" reply || reply=""
    fi
    MAX_MODEL_LEN="${reply:-6144}"
  fi
fi

VLLM_HOST="${BIND_HOST}:${PORT}"
VLLM_API_BASE="http://${VLLM_HOST}/v1"

# Try to query the live server for the actual served model ID
info "Checking live model ID at ${VLLM_API_BASE}..."
LIVE_MODEL=$(python3 -c "
import urllib.request, json, sys
try:
    r = urllib.request.urlopen('${VLLM_API_BASE}/models', timeout=3)
    d = json.loads(r.read())
    print(d['data'][0]['id'])
except Exception:
    sys.exit(1)
" 2>/dev/null || echo "")

if [[ -n "${LIVE_MODEL}" ]]; then
  MODEL_ID="${LIVE_MODEL}"
  ok "Resolved model name from live server: ${MODEL_ID}"
else
  MODEL_ID="${MODEL_ID:-qwen2.5-coder-32b-awq}"
  warn "vLLM server is not reachable at ${VLLM_API_BASE}."
  warn "Using fallback model name: ${MODEL_ID}"
fi

# =============================================================================
# STEP 3 — Configure VS Code Chat (chatLanguageModels.json)
# =============================================================================
step "STEP 3/3 — Configure VS Code Chat"

VSCODE_CHAT_FILE="${HOME}/.config/Code/User/chatLanguageModels.json"
BACKUP_FILE="${VSCODE_CHAT_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"

mkdir -p "$(dirname "${VSCODE_CHAT_FILE}")"

if [[ -f "${VSCODE_CHAT_FILE}" ]]; then
  info "${VSCODE_CHAT_FILE} already exists. Backing up to ${BACKUP_FILE}..."
  cp "${VSCODE_CHAT_FILE}" "${BACKUP_FILE}"
  ok "Backup saved: ${BACKUP_FILE}"
fi

info "Injecting local vLLM server into chatLanguageModels.json..."

set +e
python3 - <<PYEOF
import os, json, sys

config_path = "${VSCODE_CHAT_FILE}"
model_id = "${MODEL_ID}"
api_url = "http://${BIND_HOST}:${PORT}/v1/chat/completions"

# Generate a nice display name: e.g. "qwen2.5-coder-32b-awq" -> "Qwen2.5 Coder 32b Awq"
parts = model_id.replace("/", "-").split("-")
model_name = " ".join([p.capitalize() for p in parts if p]) + " (Local)"

try:
    max_tokens = int("${MAX_MODEL_LEN}")
except ValueError:
    max_tokens = 32768

# VS Code Copilot Chat's prompt-tsx renderer crashes client-side if maxInputTokens is too low
# due to the injected tool schemas. Force a minimum of 32768 tokens for the client-side config.
if max_tokens < 32768:
    max_tokens = 32768

# Load existing config
config = []
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config = json.load(f)
    except Exception as e:
        print(f"  [ERROR] {config_path} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

if not isinstance(config, list):
    config = []

# Build new custom endpoint entry
new_vendor = {
    "name": "Local vLLM Server",
    "vendor": "customendpoint",
    "apiKey": "dummy",  # pragma: allowlist secret
    "apiType": "chat-completions",
    "models": [
        {
            "id": model_id,
            "name": model_name,
            "url": api_url,
            "toolCalling": True,
            "vision": False,
            "maxInputTokens": max_tokens
        }
    ]
}

# Filter out old custom endpoint entry to avoid duplicates
cleaned_config = []
already_configured = False

for entry in config:
    if not isinstance(entry, dict):
        cleaned_config.append(entry)
        continue

    if entry.get("name") == "Local vLLM Server" or entry.get("vendor") == "customendpoint":
        models = entry.get("models", [])
        if len(models) > 0 and models[0].get("url") == api_url and models[0].get("id") == model_id and models[0].get("maxInputTokens") == max_tokens and models[0].get("toolCalling") == True:
            already_configured = True
            cleaned_config.append(entry)
    else:
        cleaned_config.append(entry)

if already_configured and len(config) > 0:
    print("  [INFO] Local vLLM Server is already configured in chatLanguageModels.json with the correct settings. Exiting.")
    sys.exit(0)

# Filter out other customendpoint entries and insert the new one
cleaned_config = [e for e in cleaned_config if not (isinstance(e, dict) and (e.get("name") == "Local vLLM Server" or e.get("vendor") == "customendpoint"))]
cleaned_config.insert(0, new_vendor)

try:
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(cleaned_config, f, indent=2)
        f.write("\n")
    print(f"  [OK] Successfully updated {config_path}")
except Exception as e:
    print(f"  [ERROR] Failed to write {config_path}: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
PYTHON_STATUS=$?
set -e

if [[ "${PYTHON_STATUS}" -ne 0 ]]; then
  if [[ -f "${BACKUP_FILE}" ]]; then
    warn "Failed to update ${VSCODE_CHAT_FILE}. Restoring backup..."
    cp "${BACKUP_FILE}" "${VSCODE_CHAT_FILE}"
  fi
  fail "chatLanguageModels.json update failed."
fi

# =============================================================================
# STEP 4 — Validate JSON Syntax
# =============================================================================
if jq empty "${VSCODE_CHAT_FILE}" 2>/dev/null; then
  ok "JSON validation passed — chatLanguageModels.json is well-formed."
else
  if [[ -f "${BACKUP_FILE}" ]]; then
    warn "JSON validation FAILED. Restoring backup..."
    cp "${BACKUP_FILE}" "${VSCODE_CHAT_FILE}"
  fi
  fail "JSON validation FAILED. chatLanguageModels.json is not well-formed."
fi

echo -e "\n${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   VS Code native Chat configured for local vLLM.             ║${RESET}"
echo -e "${GREEN}${BOLD}║   Reload VS Code window to apply.                            ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
