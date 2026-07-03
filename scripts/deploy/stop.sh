#!/usr/bin/env bash
# =============================================================================
# stop.sh
# Graceful teardown wrapper for the vLLM inference server.
# Brings down the docker compose stack cleanly, giving NCCL time to flush
# inter-GPU state before SIGKILL.
#
# Per architecture discussion in WORKLOG.md (Q5): this script stays thin —
# no embedded VRAM/log snapshot. If you need a pre-stop post-mortem snapshot,
# run scripts/snapshot-diagnostics.sh (diagnostics agent scope) first, then
# run this script.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/scripts/deploy/.env"
COMPOSE_FILE="${REPO_ROOT}/deploy-artifacts/docker-compose.yml"
CONTAINER_NAME="vllm-coder-server"

PURGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--purge)
      PURGE=true
      shift
      ;;
    *)
      fail "Unknown option: $1. Supported options: -p, --purge (destroys data volumes)"
      ;;
  esac
done

# --- Validate compose file exists --------------------------------------------
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  fail "docker-compose.yml not found at ${COMPOSE_FILE}. Nothing to stop."
fi

# --- Check current container states ------------------------------------------
if ! CONTAINER_STATE=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null); then
  CONTAINER_STATE="absent"
fi

# Sourcing .env for Open WebUI variables if present
set +u
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "${ENV_FILE}"
fi
set -u

WEBUI_CONTAINER="${OPEN_WEBUI_CONTAINER_NAME:-open-webui}"
if ! WEBUI_STATE=$(docker inspect --format='{{.State.Status}}' "${WEBUI_CONTAINER}" 2>/dev/null); then
  WEBUI_STATE="absent"
fi

if [[ "${CONTAINER_STATE}" == "absent" && "${WEBUI_STATE}" == "absent" ]]; then
  warn "vLLM and Open WebUI containers do not exist. Stack may already be down."
  exit 0
fi

info "vLLM container: ${CONTAINER_STATE} | Open WebUI container: ${WEBUI_STATE}"

# --- Setup compose arguments -------------------------------------------------
COMPOSE_ARGS=("--env-file" "${ENV_FILE}" "-f" "${COMPOSE_FILE}")
OVERRIDE_FILE="${REPO_ROOT}/deploy-artifacts/docker-compose.override.yml"
if [[ -f "${OVERRIDE_FILE}" ]]; then
  COMPOSE_ARGS+=("-f" "${OVERRIDE_FILE}")
fi

OPEN_WEBUI_COMPOSE="${REPO_ROOT}/deploy-artifacts/docker-compose.open-webui.yml"
if [[ -f "${OPEN_WEBUI_COMPOSE}" ]]; then
  if [[ "${ENABLE_OPEN_WEBUI:-false}" == "true" || "${WEBUI_STATE}" != "absent" ]]; then
    COMPOSE_ARGS+=("-f" "${OPEN_WEBUI_COMPOSE}")
  fi
fi

DOWN_ARGS=()
if [[ "${PURGE}" == "true" ]]; then
  DOWN_ARGS+=("--volumes")
  warn "Purging persistent volumes (data will be deleted)..."
fi

# --- Graceful teardown -------------------------------------------------------
info "Stopping container stack (30s graceful timeout)..."
docker compose "${COMPOSE_ARGS[@]}" down --timeout 30 "${DOWN_ARGS[@]}"

ok "Stack stopped."

# --- Post-stop VRAM confirmation ---------------------------------------------
if command -v nvidia-smi &>/dev/null; then
  GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
  echo ""
  printf "  %-6s %-35s %-12s %-12s\n" "GPU" "Name" "Used MiB" "Free MiB"
  printf "  %s\n" "$(printf '─%.0s' {1..70})"
  for i in $(seq 0 $((GPU_COUNT - 1))); do
    NAME=$(nvidia-smi -i "$i" --query-gpu=name        --format=csv,noheader | xargs)
    USED=$(nvidia-smi -i "$i" --query-gpu=memory.used  --format=csv,noheader,nounits | xargs)
    FREE=$(nvidia-smi -i "$i" --query-gpu=memory.free  --format=csv,noheader,nounits | xargs)
    printf "  %-6s %-35s %-12s %-12s\n" "$i" "${NAME:0:35}" "${USED}" "${FREE}"
  done
  echo ""
fi

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   vLLM server stopped. GPUs are free.                   ║${RESET}"
echo -e "${GREEN}${BOLD}║   To restart: bash scripts/deploy/validate-vram.sh      ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
