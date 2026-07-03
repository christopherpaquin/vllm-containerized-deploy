#!/usr/bin/env bash
# =============================================================================
# validate-vram.sh
# Live initialization telemetry monitor for vLLM container startup.
# Polls VRAM allocation and container logs during the KV cache loading phase.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Configuration -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/deploy-artifacts/docker-compose.yml"
CONTAINER_NAME="vllm-coder-server"

MAX_POLLS=30          # Maximum polling iterations
POLL_INTERVAL=5       # Seconds between polls
STARTUP_TIMEOUT=$(( MAX_POLLS * POLL_INTERVAL ))  # 150 seconds total

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)

# =============================================================================
# STEP 1 — Launch vLLM container
# =============================================================================
step "STEP 1/2 — Launching vLLM Server"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  fail "docker-compose.yml not found at ${COMPOSE_FILE}. Ensure deploy-artifacts/ directory is set up."
fi

# --- Clean up a stale crashed/looping container before restarting ------------
# A container left in 'exited'/'dead' (crashed and not auto-restarted) or
# 'restarting' (stuck in a restart loop, e.g. repeated OOM under
# `restart: unless-stopped`) would otherwise have its old log lines — possibly
# including a prior OOM trace — tailed alongside the new run below, which is
# confusing when the user is re-running this script to recover from an OOM.
if ! CONTAINER_STATE=$(docker inspect --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null); then
  CONTAINER_STATE="absent"
fi
if [[ "${CONTAINER_STATE}" == "exited" || "${CONTAINER_STATE}" == "dead" || "${CONTAINER_STATE}" == "restarting" ]]; then
  warn "Container '${CONTAINER_NAME}' is in '${CONTAINER_STATE}' state (stale from a previous run)."
  info "Running 'docker compose down' to clear it before restarting..."
  docker compose --env-file "${REPO_ROOT}/scripts/deploy/.env" -f "${COMPOSE_FILE}" down
fi

info "Starting container stack from ${COMPOSE_FILE}..."
docker compose --env-file "${REPO_ROOT}/scripts/deploy/.env" -f "${COMPOSE_FILE}" up -d

ok "Container started. Monitoring initialization for up to ${STARTUP_TIMEOUT}s..."

# =============================================================================
# STEP 2 — Polling Loop: VRAM Telemetry + Log Parsing
# =============================================================================
step "STEP 2/2 — Live VRAM Telemetry Monitor"

echo ""
echo -e "${BOLD}  Polling every ${POLL_INTERVAL}s  |  Max iterations: ${MAX_POLLS}${RESET}"
echo -e "${BOLD}  Success signal : 'Uvicorn running on...'${RESET}"
echo -e "${BOLD}  Failure signals: 'CUDA out of memory' | 'OOM'${RESET}"
echo ""

for poll in $(seq 1 "${MAX_POLLS}"); do
  TIMESTAMP=$(date '+%H:%M:%S')
  echo -e "${CYAN}── [Poll ${poll}/${MAX_POLLS}] ${TIMESTAMP} ─────────────────────────────────${RESET}"

  # --- Per-GPU VRAM snapshot -------------------------------------------------
  for i in $(seq 0 $((GPU_COUNT - 1))); do
    NAME=$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader | xargs)
    USED=$(nvidia-smi -i "$i" --query-gpu=memory.used --format=csv,noheader,nounits | xargs)
    TOTAL=$(nvidia-smi -i "$i" --query-gpu=memory.total --format=csv,noheader,nounits | xargs)
    PCT=$(echo "scale=1; ${USED} * 100 / ${TOTAL}" | bc)

    # Build a simple ASCII bar (40 chars wide)
    FILLED=$(echo "scale=0; ${USED} * 40 / ${TOTAL}" | bc)
    BAR=$(printf '%0.s█' $(seq 1 "${FILLED}") 2>/dev/null || true)
    EMPTY=$(printf '%0.s░' $(seq 1 $((40 - FILLED))) 2>/dev/null || true)

    printf "  GPU %d %-30s [%s%s] %5s MiB / %5s MiB  (%5s%%)\n" \
      "$i" "$(echo "$NAME" | cut -c1-30)" "${BAR}" "${EMPTY}" \
      "${USED}" "${TOTAL}" "${PCT}"
  done

  # --- Container log inspection ----------------------------------------------
  RECENT_LOGS=$(docker logs "${CONTAINER_NAME}" 2>&1 | tail -20 || true)

  # Check for OOM / fatal errors (exit immediately)
  if echo "${RECENT_LOGS}" | grep -qiE 'CUDA out of memory|OutOfMemoryError|OOM|RuntimeError.*CUDA'; then
    echo ""
    fail "═══════════════════════════════════════════════════════════════
  OOM DETECTED in container logs!
  vLLM ran out of VRAM during KV cache allocation.

  Recommended recovery actions:
    1. Open scripts/deploy/.env and reduce:
         MAX_MODEL_LEN=8192        (halve the context window)
         GPU_MEMORY_UTILIZATION=0.85
    2. If a display server is active, free GPU 0:
         sudo systemctl isolate multi-user.target
    3. Re-run: bash scripts/tune-inference.sh && bash scripts/validate-vram.sh
═══════════════════════════════════════════════════════════════"
  fi

  # Check for successful startup signal
  if echo "${RECENT_LOGS}" | grep -q "Uvicorn running on"; then
    echo ""
    ok "═══════════════════════════════════════════════════════════════"
    ok "  vLLM server is READY — Uvicorn is accepting connections."
    ok "  Endpoint: http://localhost:8000/v1"
    ok ""
    ok "  Run benchmark: bash scripts/benchmark.sh"
    ok "═══════════════════════════════════════════════════════════════"
    exit 0
  fi

  # Show the last meaningful log line as a status hint
  LAST_LOG=$(echo "${RECENT_LOGS}" | grep -v '^$' | tail -1 || echo "(no output yet)")
  echo -e "  ${YELLOW}Last log:${RESET} ${LAST_LOG}"
  echo ""

  # Wait before next poll (skip wait on last iteration)
  if [[ "${poll}" -lt "${MAX_POLLS}" ]]; then
    sleep "${POLL_INTERVAL}"
  fi
done

# Timeout reached without success
fail "═══════════════════════════════════════════════════════════════
  Timeout: vLLM did not report ready after ${STARTUP_TIMEOUT}s.
  Model download or KV cache allocation is still running.

  Actions:
    • Check full logs: docker logs ${CONTAINER_NAME} --follow
    • Large models (32B AWQ) may take 5–15 min to download on first run.
    • Re-run this script once you see 'Uvicorn running' in the logs.
═══════════════════════════════════════════════════════════════"
