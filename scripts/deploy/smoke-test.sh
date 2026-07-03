#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh
# Smoke test verification for the vLLM and Open WebUI services.
# Supports running locally or from a remote LAN client.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/scripts/deploy/.env"

# --- Defaults ----------------------------------------------------------------
HOST_IP="127.0.0.1"
VLLM_PORT=8000
WEBUI_PORT=3000
ENABLE_WEBUI=false
VLLM_CONTAINER="vllm-coder-server"
WEBUI_CONTAINER="open-webui"

# Load local env if present
if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090,SC1091
  source "${ENV_FILE}"
  set -u
  HOST_IP="${BIND_HOST:-127.0.0.1}"
  VLLM_PORT="${PORT:-8000}"
  WEBUI_PORT="${OPEN_WEBUI_PORT:-3000}"
  ENABLE_WEBUI="${ENABLE_OPEN_WEBUI:-false}"
  VLLM_CONTAINER="vllm-coder-server"
  WEBUI_CONTAINER="${OPEN_WEBUI_CONTAINER_NAME:-open-webui}"
fi

# Override defaults with positional parameters if provided
# Usage: smoke-test.sh [host-ip] [vllm-port] [open-webui-port] [enable-webui]
if [[ $# -ge 1 ]]; then
  HOST_IP="$1"
fi
if [[ $# -ge 2 ]]; then
  VLLM_PORT="$2"
fi
if [[ $# -ge 3 ]]; then
  WEBUI_PORT="$3"
  ENABLE_WEBUI=true  # Explicitly enable WebUI check if port is provided
fi
if [[ $# -ge 4 ]]; then
  ENABLE_WEBUI="$4"
fi

info "Targeting Host       : ${HOST_IP}"
info "vLLM API Port        : ${VLLM_PORT}"
if [[ "${ENABLE_WEBUI}" == "true" ]]; then
  info "Open WebUI Port      : ${WEBUI_PORT}"
fi

# --- 1. Validate vLLM Endpoint -----------------------------------------------
info "Validating vLLM API..."
VLLM_URL="http://${HOST_IP}:${VLLM_PORT}/v1/models"
if curl -sf "${VLLM_URL}" > /dev/null; then
  ok "vLLM endpoint at ${VLLM_URL} is responding successfully."
else
  fail "Could not connect to vLLM endpoint at ${VLLM_URL}"
fi

# --- 2. Validate Open WebUI Endpoint ------------------------------------------
if [[ "${ENABLE_WEBUI}" == "true" ]]; then
  info "Validating Open WebUI..."
  WEBUI_URL="http://${HOST_IP}:${WEBUI_PORT}"
  if curl -sf "${WEBUI_URL}" > /dev/null || curl -sfI "${WEBUI_URL}" > /dev/null; then
    ok "Open WebUI endpoint at ${WEBUI_URL} is responding successfully."
  else
    fail "Could not connect to Open WebUI endpoint at ${WEBUI_URL}"
  fi
fi

# --- 3. Validate Docker Restart Policies (Local Only) --------------------------
# Check if running locally (docker CLI is installed and can connect to Docker daemon)
if command -v docker &>/dev/null && docker ps &>/dev/null; then
  info "Checking local container configurations..."

  # Check vLLM restart policy
  if docker inspect "${VLLM_CONTAINER}" &>/dev/null; then
    V_RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${VLLM_CONTAINER}")
    V_STATUS=$(docker inspect --format='{{.State.Status}}' "${VLLM_CONTAINER}")
    ok "Container '${VLLM_CONTAINER}' is ${V_STATUS} with restart policy: ${V_RESTART}"
    if [[ "${V_RESTART}" == "no" ]]; then
      warn "Container '${VLLM_CONTAINER}' has restart policy set to 'no'."
    fi
  else
    warn "vLLM container '${VLLM_CONTAINER}' not found locally."
  fi

  # Check Open WebUI restart policy
  if [[ "${ENABLE_WEBUI}" == "true" ]]; then
    if docker inspect "${WEBUI_CONTAINER}" &>/dev/null; then
      W_RESTART=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${WEBUI_CONTAINER}")
      W_STATUS=$(docker inspect --format='{{.State.Status}}' "${WEBUI_CONTAINER}")
      ok "Container '${WEBUI_CONTAINER}' is ${W_STATUS} with restart policy: ${W_RESTART}"
      if [[ "${W_RESTART}" == "no" ]]; then
        warn "Container '${WEBUI_CONTAINER}' has restart policy set to 'no'."
      fi
    else
      warn "Open WebUI container '${WEBUI_CONTAINER}' not found locally."
    fi
  fi
else
  info "Docker not available locally or cannot connect to daemon; skipping container inspect checks."
fi

ok "Smoke test verification successful!"
