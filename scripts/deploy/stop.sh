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
COMPOSE_FILE="${REPO_ROOT}/deploy/docker-compose.yml"
CONTAINER_NAME="vllm-coder-server"

# --- Validate compose file exists --------------------------------------------
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  fail "docker-compose.yml not found at ${COMPOSE_FILE}. Nothing to stop."
fi

# --- Check current container state -------------------------------------------
# A failed `docker inspect --format=` prints a stray empty line to stdout
# before it exits non-zero, so `X=$(cmd || echo fallback)` would capture
# "\nabsent" instead of "absent". Check the exit status explicitly instead.
if ! CONTAINER_STATE=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null); then
  CONTAINER_STATE="absent"
fi

if [[ "${CONTAINER_STATE}" == "absent" ]]; then
  warn "Container '${CONTAINER_NAME}' does not exist. Stack may already be down."
  exit 0
fi

info "Container '${CONTAINER_NAME}' is currently: ${CONTAINER_STATE}"

# --- Graceful teardown -------------------------------------------------------
# --timeout 30: give processes 30s to flush state before SIGKILL.
# NCCL collective ops can take a few seconds to unwind cleanly.
info "Stopping vLLM stack (30s graceful timeout)..."
docker compose -f "${COMPOSE_FILE}" down --timeout 30

ok "Stack stopped. GPU VRAM has been released."

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
