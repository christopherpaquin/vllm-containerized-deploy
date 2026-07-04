#!/usr/bin/env bash
# =============================================================================
# snapshot-diagnostics.sh
# Point-in-time diagnostic capture for the vLLM inference server.
#
# Read-only — never mutates GPU state, container state, or config. Captures
# per-GPU VRAM/temperature/power and recent container logs into a timestamped
# file under ~/.local/share/vllm-snapshots/, for post-mortem reference.
#
# Typical use: run this *before* scripts/deploy/teardown.sh when debugging a crash, OOM,
# or silent hang — teardown.sh itself stays a thin, always-safe teardown with no
# embedded snapshot logic (see WORKLOG.md Q5 discussion), so this is the tool
# for "capture evidence, then shut down."
#
# Usage: bash scripts/snapshot-diagnostics.sh [log_lines]   (default: 50)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

CONTAINER_NAME="vllm-coder-server"
SNAPSHOT_DIR="${HOME}/.local/share/vllm-snapshots"

# --- CLI arg: how many log lines to capture ----------------------------------
LOG_LINES="${1:-50}"
if ! [[ "${LOG_LINES}" =~ ^[0-9]+$ ]] || [[ "${LOG_LINES}" -lt 1 ]]; then
  fail "Invalid log_lines '${LOG_LINES}'. Usage: bash scripts/snapshot-diagnostics.sh [log_lines]  (must be a positive integer, default: 50)"
fi

mkdir -p "${SNAPSHOT_DIR}"
SNAPSHOT_FILE="${SNAPSHOT_DIR}/snapshot_$(date -u '+%Y%m%dT%H%M%SZ').txt"

step "STEP 1/2 — Capturing GPU State"

{
  echo "vLLM Diagnostic Snapshot"
  echo "Timestamp (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Container: ${CONTAINER_NAME}"
  echo ""
  echo "=== GPU State ==="
} > "${SNAPSHOT_FILE}"

if command -v nvidia-smi &>/dev/null; then
  GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
  info "Capturing VRAM/temperature/power for ${GPU_COUNT} GPU(s)..."

  printf "%-6s %-35s %-10s %-10s %-10s %-10s\n" \
    "GPU" "Name" "Used MiB" "Total MiB" "Temp C" "Power W" >> "${SNAPSHOT_FILE}"

  for i in $(seq 0 $((GPU_COUNT - 1))); do
    NAME=$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader | xargs)
    USED=$(nvidia-smi -i "$i" --query-gpu=memory.used --format=csv,noheader,nounits | xargs)
    TOTAL=$(nvidia-smi -i "$i" --query-gpu=memory.total --format=csv,noheader,nounits | xargs)
    TEMP=$(nvidia-smi -i "$i" --query-gpu=temperature.gpu --format=csv,noheader,nounits | xargs)
    POWER=$(nvidia-smi -i "$i" --query-gpu=power.draw --format=csv,noheader,nounits | xargs)
    printf "%-6s %-35s %-10s %-10s %-10s %-10s\n" \
      "$i" "${NAME:0:35}" "${USED}" "${TOTAL}" "${TEMP}" "${POWER}" >> "${SNAPSHOT_FILE}"
  done
  ok "GPU state captured."
else
  echo "nvidia-smi not found — GPU state unavailable." >> "${SNAPSHOT_FILE}"
  warn "nvidia-smi not found — skipping GPU state capture."
fi

step "STEP 2/2 — Capturing Recent Container Logs"

{
  echo ""
  echo "=== Last ${LOG_LINES} Log Lines (${CONTAINER_NAME}) ==="
} >> "${SNAPSHOT_FILE}"

if ! CONTAINER_STATE=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null); then
  CONTAINER_STATE="absent"
fi

if [[ "${CONTAINER_STATE}" == "absent" ]]; then
  echo "(container '${CONTAINER_NAME}' does not exist — no logs to capture)" >> "${SNAPSHOT_FILE}"
  warn "Container '${CONTAINER_NAME}' does not exist. Logs section left empty."
else
  echo "Container state at capture time: ${CONTAINER_STATE}" >> "${SNAPSHOT_FILE}"
  echo "" >> "${SNAPSHOT_FILE}"
  if docker logs "${CONTAINER_NAME}" --tail "${LOG_LINES}" >> "${SNAPSHOT_FILE}" 2>&1; then
    ok "Captured last ${LOG_LINES} log lines (container state: ${CONTAINER_STATE})."
  else
    echo "(failed to read container logs)" >> "${SNAPSHOT_FILE}"
    warn "Could not read logs for '${CONTAINER_NAME}', but GPU state was still captured."
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║   Snapshot saved.                                              ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}File:${RESET} ${SNAPSHOT_FILE}"
echo ""
