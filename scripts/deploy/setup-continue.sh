#!/usr/bin/env bash
# =============================================================================
# setup-continue.sh
# Automated VS Code Continue extension hook.
# Injects a vLLM endpoint into ~/.continue/config.json, creating the file
# with full defaults if it doesn't already exist.
#
# Run this on whichever machine has VS Code + Continue installed — that is
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

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONTINUE_DIR="${HOME}/.continue"
CONFIG_FILE="${CONTINUE_DIR}/config.json"
BACKUP_FILE="${CONTINUE_DIR}/config.json.bak.$(date '+%Y%m%d_%H%M%S')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/deploy/.env"

# Optional first argument: host[:port] of the machine running vLLM.
# Defaults to localhost:8000 for the common case of running this script
# directly on the vLLM host.
VLLM_HOST="${1:-localhost:8000}"
VLLM_API_BASE="http://${VLLM_HOST}/v1"
MODEL_TITLE="Qwen2.5-Coder-32B (vLLM @ ${VLLM_HOST})"

# ---------------------------------------------------------------------------
# Model ID resolution strategy (in priority order):
#   1. Query the live /v1/models endpoint — uses the actual served-model-name
#      registered in docker-compose.yml (e.g. "qwen2.5-coder-32b-awq").
#      This is authoritative: it's what API requests must send in the "model"
#      field for vLLM to accept them.
#   2. Fall back to MODEL= in deploy/.env if the server is not yet running.
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
  warn "Using MODEL_ID from deploy/.env as fallback: ${MODEL_ID}"
  warn "Note: this may NOT match the served-model-name in docker-compose.yml."
  warn "Re-run this script once the server is up for an accurate config."
fi

# =============================================================================
# STEP 1 — Verify python3 and jq
# =============================================================================
step "STEP 1/4 — Dependency Check"

if ! command -v python3 &>/dev/null; then
  fail "python3 not found. Install it manually (e.g. apt install python3) or run scripts/prereqs/install-prereqs.sh if this is the vLLM host."
fi

if ! command -v jq &>/dev/null; then
  fail "jq not found. Install it manually (e.g. apt install jq) or run scripts/prereqs/install-prereqs.sh if this is the vLLM host."
fi

ok "python3 and jq are available."

# =============================================================================
# STEP 2 — Ensure ~/.continue/ directory exists
# =============================================================================
step "STEP 2/4 — Ensure ~/.continue/ Directory"

mkdir -p "${CONTINUE_DIR}"
ok "Directory ${CONTINUE_DIR} is ready."

# =============================================================================
# STEP 3 — Create or patch config.json
# =============================================================================
step "STEP 3/4 — Configure Continue config.json"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  # -------------------------------------------------------------------------
  # Brand new installation — write the complete default config
  # -------------------------------------------------------------------------
  info "${CONFIG_FILE} does not exist. Writing full default configuration..."

  cat > "${CONFIG_FILE}" <<JSONEOF
{
  "models": [
    {
      "title": "${MODEL_TITLE}",
      "provider": "openai",
      "model": "${MODEL_ID}",
      "apiBase": "${VLLM_API_BASE}",
      "apiKey": "dummy",
      "useLegacyCompletionsEndpoint": false,
      "contextLength": 16384,
      "completionOptions": {
        "temperature": 0.1,
        "topP": 0.95,
        "maxTokens": 2048
      }
    }
  ],
  "tabAutocompleteModel": {
    "title": "${MODEL_TITLE} (Autocomplete)",
    "provider": "openai",
    "model": "${MODEL_ID}",
    "apiBase": "${VLLM_API_BASE}",
    "apiKey": "dummy",
    "useLegacyCompletionsEndpoint": false,
    "contextLength": 4096,
    "completionOptions": {
      "temperature": 0.05,
      "maxTokens": 512,
      "stop": ["\n\n", "\`\`\`"]
    }
  },
  "tabAutocompleteOptions": {
    "disable": false,
    "useCopyBuffer": false,
    "maxPromptTokens": 1024,
    "prefixPercentage": 0.85
  },
  "embeddingsProvider": {
    "provider": "transformers.js"
  },
  "contextProviders": [
    { "name": "code",       "params": {} },
    { "name": "docs",       "params": {} },
    { "name": "diff",       "params": {} },
    { "name": "terminal",   "params": {} },
    { "name": "problems",   "params": {} },
    { "name": "folder",     "params": {} },
    { "name": "codebase",   "params": {} }
  ],
  "slashCommands": [
    { "name": "edit",     "description": "Edit selected code" },
    { "name": "comment",  "description": "Write comments for selected code" },
    { "name": "share",    "description": "Export conversation" },
    { "name": "cmd",      "description": "Generate shell command" },
    { "name": "commit",   "description": "Generate a git commit message" }
  ],
  "allowAnonymousTelemetry": false
}
JSONEOF

  ok "Default config.json written to ${CONFIG_FILE}."

else
  # -------------------------------------------------------------------------
  # Config already exists — safely inject our endpoint using Python+json
  # -------------------------------------------------------------------------
  info "${CONFIG_FILE} already exists. Backing up to ${BACKUP_FILE}..."
  cp "${CONFIG_FILE}" "${BACKUP_FILE}"
  ok "Backup saved: ${BACKUP_FILE}"

  info "Injecting local vLLM model entry into existing config..."

  python3 - <<PYEOF
import json
import sys

config_path  = "${CONFIG_FILE}"
model_id     = "${MODEL_ID}"
api_base     = "${VLLM_API_BASE}"
model_title  = "${MODEL_TITLE}"

# Load existing config
with open(config_path, "r") as f:
    config = json.load(f)

# Build new chat model entry
new_chat_model = {
    "title": model_title,
    "provider": "openai",
    "model": model_id,
    "apiBase": api_base,
    "apiKey": "dummy",
    "useLegacyCompletionsEndpoint": False,
    "contextLength": 16384,
    "completionOptions": {
        "temperature": 0.1,
        "topP": 0.95,
        "maxTokens": 2048
    }
}

# Build autocomplete model entry
new_autocomplete_model = {
    "title": f"{model_title} (Autocomplete)",
    "provider": "openai",
    "model": model_id,
    "apiBase": api_base,
    "apiKey": "dummy",
    "useLegacyCompletionsEndpoint": False,
    "contextLength": 4096,
    "completionOptions": {
        "temperature": 0.05,
        "maxTokens": 512,
        "stop": ["\n\n", "\`\`\`"]
    }
}

# Ensure models array exists
if "models" not in config or not isinstance(config["models"], list):
    config["models"] = []

# Check if our model entry already exists (by apiBase + model ID)
existing_titles = {m.get("title") for m in config["models"]}
if model_title in existing_titles:
    print(f"  [INFO] Model '{model_title}' already present in models array — updating in place.")
    config["models"] = [
        new_chat_model if m.get("title") == model_title else m
        for m in config["models"]
    ]
else:
    # Prepend so our local model is the default selected one
    config["models"].insert(0, new_chat_model)
    print(f"  [INFO] Inserted '{model_title}' at position 0 of models array.")

# Always update tabAutocompleteModel to point to local endpoint
config["tabAutocompleteModel"] = new_autocomplete_model
print(f"  [INFO] tabAutocompleteModel set to: {model_title}")

# Write back with clean formatting
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

print(f"  [OK]  {config_path} updated successfully.")
PYEOF

fi

# =============================================================================
# STEP 4 — Validate the final JSON
# =============================================================================
step "STEP 4/4 — Validate Config JSON Syntax"

if jq empty "${CONFIG_FILE}" 2>/dev/null; then
  ok "JSON validation passed — config.json is well-formed."
else
  if [[ -f "${BACKUP_FILE}" ]]; then
    warn "JSON validation FAILED. Restoring backup from ${BACKUP_FILE}..."
    cp "${BACKUP_FILE}" "${CONFIG_FILE}"
    warn "Restored backup. Inspect config.json and re-run the script."
  else
    warn "JSON validation FAILED. No backup file found to restore."
  fi
  fail "JSON validation FAILED. config.json is not well-formed."
fi

# Show summary of configured endpoints
echo ""
echo -e "${BOLD}  Continue Extension Configuration Summary:${RESET}"
echo -e "  Config file   : ${CONFIG_FILE}"
echo -e "  Model ID      : ${MODEL_ID}  (resolved from live server or .env)"
echo -e "  API Base      : ${VLLM_API_BASE}"
echo -e "  Autocomplete  : enabled (same model, limited context)"
echo ""

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   Continue extension is configured for local vLLM.          ║${RESET}"
echo -e "${GREEN}${BOLD}║   Reload VS Code window (Ctrl+Shift+P → Reload Window)      ║${RESET}"
echo -e "${GREEN}${BOLD}║   Next step: bash scripts/benchmark.sh                      ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
