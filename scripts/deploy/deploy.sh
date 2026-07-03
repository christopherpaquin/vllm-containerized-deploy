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
#   3. Run install-prereqs.sh   — idempotent; skips already-satisfied steps
#   4. Run validate-system.sh   — GPU + Docker connectivity; blocks on failure
#   5. Run check-bottlenecks.sh — advisory performance scan; never blocks
#   6. Run tune-inference.sh    — updates only the GPU-tuned keys in deploy/.env
#   7. Re-apply user vars on top of tuned .env (user settings always win)
#   8. Generate docker-compose.override.yml with fully-resolved vLLM command
#      (optional features like speculative decoding wired in only if set)
#   9. Ensure the Docker service is enabled at boot, so the container (which
#      has restart: unless-stopped) comes back up automatically after a
#      host reboot — not just after a plain container/daemon restart
#  10. Launch via docker compose up -d
#  11. Monitor startup: VRAM telemetry + log tailing until ready or OOM
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"
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
step "STEP 1/7 — Loading Configuration"

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

ok "deploy/.env loaded."
info "Model         : ${U_MODEL}"
info "Served as     : ${U_SERVED_NAME}"
info "Port          : ${U_PORT}"
info "HF cache      : ${U_HF_CACHE}"

# =============================================================================
# STEP 2 — Resolve BIND_HOST
# =============================================================================
step "STEP 2/7 — Resolving Network Bind Address"

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
# STEP 3 — Prerequisites, system validation, and performance advisory
# =============================================================================
step "STEP 3/7 — System Checks"

info "Running install-prereqs.sh (idempotent — skips already-satisfied steps)..."
bash "${SCRIPT_PREREQS}/install-prereqs.sh"

info "Running validate-system.sh (GPU + Docker connectivity)..."
bash "${SCRIPT_DEPLOY}/validate-system.sh"

info "Running check-bottlenecks.sh (performance advisory — non-blocking)..."
bash "${SCRIPT_TUNING}/check-bottlenecks.sh" || true

# =============================================================================
# STEP 4 — GPU-tuned configuration
# =============================================================================
step "STEP 4/7 — Generating Tuned GPU Configuration"

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

ok "Configuration finalised. GPU-tuned values + user settings merged."

# Re-source to pick up the GPU vars tune-inference.sh wrote
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}"
set -u
FINAL_TP="${TENSOR_PARALLEL_SIZE:-2}"
FINAL_GPU_UTIL="${GPU_MEMORY_UTILIZATION:-0.90}"
FINAL_CTX="${MAX_MODEL_LEN:-16384}"
FINAL_SWAP="${SWAP_SPACE:-4}"
FINAL_QUANT="${QUANTIZATION:-awq}"

info "Tensor parallel size    : ${FINAL_TP}"
info "GPU memory utilization  : ${FINAL_GPU_UTIL}"
info "Max context length      : ${FINAL_CTX} tokens"

# =============================================================================
# STEP 5 — Generate docker-compose.override.yml
# =============================================================================
step "STEP 5/7 — Building Compose Override"

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
# DO NOT EDIT BY HAND. Re-run 'bash scripts/deploy.sh' to regenerate.
# This file is gitignored and must not be committed.
# =============================================================================
services:
  vllm:
    ports:
      - "${U_BIND_HOST}:${U_PORT}:8000"
    command: >
      --model                  ${U_MODEL}
      --tensor-parallel-size   ${FINAL_TP}
      --quantization           ${FINAL_QUANT}
      --max-model-len          ${FINAL_CTX}
      --gpu-memory-utilization ${FINAL_GPU_UTIL}
      --swap-space             ${FINAL_SWAP}
      --host                   0.0.0.0
      --port                   8000
      --served-model-name      ${U_SERVED_NAME}
      --disable-log-requests
${OPT_ARGS}
YAML_EOF

ok "docker-compose.override.yml written."
info "Port binding  : ${U_BIND_HOST}:${U_PORT} → container:8000"

# =============================================================================
# STEP 6 — Ensure boot persistence (Ubuntu / systemd)
# =============================================================================
step "STEP 6/7 — Ensuring Boot Persistence"

# docker-compose.yml sets `restart: unless-stopped` on the vllm service, so
# once the Docker daemon comes up, Docker restarts the container for us.
# The one thing that has to be true for that to also cover a full host
# reboot is that the Docker service itself is enabled to start at boot —
# install-prereqs.sh only enables it when installing Docker for the first
# time, so an already-installed Docker daemon may still be boot-disabled.
if systemctl is-enabled --quiet docker 2>/dev/null; then
  ok "docker.service is enabled at boot — the vLLM container will restart automatically after a reboot."
else
  warn "docker.service is not enabled at boot. Enabling it now..."
  systemctl enable docker
  ok "docker.service enabled — the vLLM container will now restart automatically after a reboot."
fi

# =============================================================================
# STEP 7 — Launch and monitor
# =============================================================================
step "STEP 7/7 — Launching vLLM Server"

CONTAINER_NAME="vllm-coder-server"

# Clean up any stale container before starting (same logic as validate-vram.sh)
if ! CONTAINER_STATE=$(docker inspect \
    --format='{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null); then
  CONTAINER_STATE="absent"
fi

if [[ "${CONTAINER_STATE}" == "exited" || \
      "${CONTAINER_STATE}" == "dead"   || \
      "${CONTAINER_STATE}" == "restarting" ]]; then
  warn "Stale container found (state: ${CONTAINER_STATE}). Removing before restart..."
  docker compose -f "${COMPOSE_FILE}" -f "${OVERRIDE_FILE}" down
fi

info "Starting container..."
docker compose \
  -f "${COMPOSE_FILE}" \
  -f "${OVERRIDE_FILE}" \
  up -d

ok "Container started. Monitoring startup (model load typically takes 2–5 min)..."
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
    ok "Server is UP!"
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║  Deployment successful.                                        ║${RESET}"
    echo -e "${GREEN}${BOLD}║                                                                ║${RESET}"
    printf  "${GREEN}${BOLD}║  API endpoint  : http://%-38s║${RESET}\n" "${U_BIND_HOST}:${U_PORT}/v1"
    printf  "${GREEN}${BOLD}║  Model alias   : %-46s║${RESET}\n" "${U_SERVED_NAME}"
    echo -e "${GREEN}${BOLD}║                                                                ║${RESET}"
    echo -e "${GREEN}${BOLD}║  Next steps:                                                   ║${RESET}"
    echo -e "${GREEN}${BOLD}║    bash scripts/deploy/setup-continue.sh — configure VS Code   ║${RESET}"
    echo -e "${GREEN}${BOLD}║    bash scripts/tuning/benchmark.sh      — verify throughput   ║${RESET}"
    echo -e "${GREEN}${BOLD}║    bash scripts/deploy/stop.sh           — graceful shutdown   ║${RESET}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    exit 0
  fi

  if echo "${LOGS}" | grep -qiE "(cuda out of memory|out of memory|OOM)"; then
    echo ""
    fail "OOM detected. Reduce MAX_MODEL_LEN or GPU_MEMORY_UTILIZATION in deploy/.env and re-run."
  fi
done

echo ""
warn "Server did not signal readiness within ${STARTUP_TIMEOUT}s."
warn "The model may still be loading — 32B models can take 5+ min from cold storage."
echo ""
info "Watch logs : docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.override.yml logs -f"
info "Check VRAM : bash scripts/deploy/validate-vram.sh"
exit 1
