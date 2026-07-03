#!/usr/bin/env bash
# =============================================================================
# tune-inference.sh
# Hardware-sensing configuration generator for vLLM on dual-GPU RTX 3060 setup.
# Queries GPU topology dynamically and writes tuned values to deploy/.env.
#
# If deploy/.env already exists, only the hardware-tuned keys below are
# touched (TENSOR_PARALLEL_SIZE, GPU_MEMORY_UTILIZATION, MAX_MODEL_LEN,
# SWAP_SPACE, QUANTIZATION) — every other line (MODEL, network settings,
# HF_TOKEN, optional feature flags, comments, ordering) is left exactly as
# it is on disk. Any change to a tuned value is printed before it's applied.
# The file is only ever fully generated from scratch when it doesn't exist yet.
# =============================================================================
set -euo pipefail

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Determine repository root -----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/scripts/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"

mkdir -p "${DEPLOY_DIR}"

ENV_EXISTS=false
[[ -f "${ENV_FILE}" ]] && ENV_EXISTS=true

# Keys this script owns and is allowed to compute/update. Everything else in
# an existing scripts/deploy/.env (MODEL, network settings, HF_TOKEN, optional
# feature flags, comments, ordering) is never touched.
TUNED_KEYS=(TENSOR_PARALLEL_SIZE GPU_MEMORY_UTILIZATION MAX_MODEL_LEN SWAP_SPACE QUANTIZATION GPU_DEVICE_ID)

# Snapshot the current on-disk value of a tuned key (empty if absent/no file).
read_env_var() {
  local key="$1"
  [[ "${ENV_EXISTS}" == "true" ]] || return 0
  (grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null || true) | tail -1 | cut -d= -f2-
}

# Replace a key's value in-place if the line exists, else append it.
# Leaves every other line in the file untouched.
set_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

if [[ "${ENV_EXISTS}" == "true" ]]; then
  OLD_TENSOR_PARALLEL_SIZE="$(read_env_var TENSOR_PARALLEL_SIZE)"
  OLD_GPU_MEMORY_UTILIZATION="$(read_env_var GPU_MEMORY_UTILIZATION)"
  OLD_MAX_MODEL_LEN="$(read_env_var MAX_MODEL_LEN)"
  OLD_SWAP_SPACE="$(read_env_var SWAP_SPACE)"
  OLD_QUANTIZATION="$(read_env_var QUANTIZATION)"
  OLD_GPU_DEVICE_ID="$(read_env_var GPU_DEVICE_ID)"
fi

# =============================================================================
# STEP 1 — Validate GPU tool presence
# =============================================================================
step "STEP 1/4 — Validating GPU Tools"

# Detect GPU Type
GPU_TYPE="unknown"
if command -v nvidia-smi &>/dev/null; then
  GPU_TYPE="nvidia"
elif command -v rocm-smi &>/dev/null || [[ -e /dev/kfd ]]; then
  GPU_TYPE="amd"
fi

if [[ "${GPU_TYPE}" == "nvidia" ]]; then
  ok "nvidia-smi is available."
elif [[ "${GPU_TYPE}" == "amd" ]]; then
  ok "rocm-smi / AMD GPU detected."
else
  fail "No GPU tools (nvidia-smi or rocm-smi) found. Run scripts/prereqs/install-prereqs.sh first."
fi

# =============================================================================
# STEP 2 — Query GPU Topology
# =============================================================================
step "STEP 2/4 — Querying GPU Topology"

if [[ "${GPU_TYPE}" == "nvidia" ]]; then
  # Total number of GPUs visible to the system
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  info "Detected NVIDIA GPU count: ${GPU_COUNT}"

  if [[ "${GPU_COUNT}" -lt 1 ]]; then
    fail "No NVIDIA GPUs detected. Cannot proceed."
  fi

  # Collect per-GPU VRAM totals (in MiB)
  mapfile -t VRAM_LIST < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)

  info "Per-GPU VRAM (MiB):"
  TOTAL_VRAM_MiB=0
  for i in "${!VRAM_LIST[@]}"; do
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | sed -n "$((i+1))p")
    VRAM_MiB="${VRAM_LIST[$i]// /}"  # trim whitespace
    echo "    GPU ${i}: ${GPU_NAME} — ${VRAM_MiB} MiB"
    TOTAL_VRAM_MiB=$(( TOTAL_VRAM_MiB + VRAM_MiB ))
  done

  # Use GPU 0 as reference for per-card VRAM
  PRIMARY_VRAM_MiB="${VRAM_LIST[0]// /}"
  PRIMARY_VRAM_GiB=$(echo "scale=1; ${PRIMARY_VRAM_MiB} / 1024" | bc)
  TOTAL_VRAM_GiB=$(echo "scale=1; ${TOTAL_VRAM_MiB} / 1024" | bc)

  ok "Primary GPU VRAM: ${PRIMARY_VRAM_GiB} GiB (${PRIMARY_VRAM_MiB} MiB)"
  ok "Total cluster VRAM: ${TOTAL_VRAM_GiB} GiB across ${GPU_COUNT} GPU(s)"
  GPU_DEVICE_ID="nvidia.com/gpu=all"

elif [[ "${GPU_TYPE}" == "amd" ]]; then
  GPU_COUNT=$(rocm-smi --showid 2>/dev/null | grep -c 'GPU\[' || echo 1)
  info "Detected AMD GPU count: ${GPU_COUNT}"

  # Default/fallback VRAM estimations for parameter tuning on AMD if we don't query via rocm-smi.
  # Assume 16GB primary VRAM as a baseline.
  PRIMARY_VRAM_MiB=16384
  PRIMARY_VRAM_GiB=16
  TOTAL_VRAM_MiB=$(( PRIMARY_VRAM_MiB * GPU_COUNT ))
  TOTAL_VRAM_GiB=$(( PRIMARY_VRAM_GiB * GPU_COUNT ))

  ok "Primary GPU VRAM (assumed): ${PRIMARY_VRAM_GiB} GiB"
  ok "Total cluster VRAM (assumed): ${TOTAL_VRAM_GiB} GiB across ${GPU_COUNT} GPU(s)"
  GPU_DEVICE_ID="amd.com/gpu=all"
fi

# =============================================================================
# STEP 3 — Calculate Safe Inference Parameters
# =============================================================================
step "STEP 3/4 — Calculating Tuned Parameters"

# --- Model Selection ---------------------------------------------------------
# Respect MODEL if already set in environment (e.g. exported by deploy.sh or
# pre-set in deploy/.env). Fall back to the recommended default for 24 GB VRAM:
# Qwen2.5-Coder-32B-Instruct-AWQ — purpose-built for code generation, fits
# comfortably on 2x RTX 3060 at AWQ quantization with TP=2.
MODEL="${MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"

# Served model name alias — what API clients put in the "model" field.
# Avoids the slash in the HF ID that breaks some OpenAI-compatible clients.
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen2.5-coder-32b-awq}"

# --- Tensor Parallelism -------------------------------------------------------
# Always match GPU count for full topology coverage.
TENSOR_PARALLEL_SIZE="${GPU_COUNT}"

# --- GPU Memory Utilization ---------------------------------------------------
# Values are chosen based on VRAM tier alone (see tiers below).
# This script intentionally does NOT read check-bottlenecks.sh output (THP mode,
# CPU governor) and adjust utilization based on OS state. Rationale: those are
# one-line fixes (echo always | tee /sys/.../thp; cpupower governor performance),
# not things to compensate for permanently in .env numbers a user will forget to
# update later. The right workflow is: fix the OS setting → re-run this script.
#
# TODO(strict-mode): if a future --strict flag is added, check-bottlenecks.sh
# could exit non-zero on bad OS state, and this script could optionally gate
# on that exit code before writing .env (agreed in WORKLOG.md Q1 discussion).
#
# 12 GiB cards: use 90% to leave ~1.2 GiB headroom for CUDA overhead.
# For larger cards (>16 GiB), 92% is safe. For smaller (<10 GiB), drop to 85%.

if [[ "${PRIMARY_VRAM_MiB}" -le 10240 ]]; then
  GPU_MEMORY_UTILIZATION="0.85"
  warn "Small VRAM detected (<10 GiB). Setting GPU_MEMORY_UTILIZATION=0.85 conservatively."
elif [[ "${PRIMARY_VRAM_MiB}" -le 13312 ]]; then
  # ~12 GiB class (RTX 3060 / 4070)
  GPU_MEMORY_UTILIZATION="0.90"
  info "12 GiB class GPU detected. Setting GPU_MEMORY_UTILIZATION=0.90."
else
  # 16+ GiB class (A100, RTX 4090, etc.)
  GPU_MEMORY_UTILIZATION="0.92"
  info "Large VRAM GPU detected (>16 GiB). Setting GPU_MEMORY_UTILIZATION=0.92."
fi

# --- Max Model Length (Context Window) ---------------------------------------
# Qwen2.5-Coder native context is 128K, but KV cache is O(n^2) per token.
# On 24 GiB total, cap at 16384 to prevent KV cache OOM on long sessions.
# Each KV cache token for Qwen2.5-32B-AWQ ~ 0.9 MB across the cluster.
if [[ "${TOTAL_VRAM_MiB}" -le 24576 ]]; then
  # <= 24 GiB total: conservative cap
  MAX_MODEL_LEN=16384
  info "Total VRAM ≤ 24 GiB. Capping MAX_MODEL_LEN=${MAX_MODEL_LEN} to protect KV cache budget."
elif [[ "${TOTAL_VRAM_MiB}" -le 49152 ]]; then
  # 24–48 GiB range
  MAX_MODEL_LEN=32768
  info "Total VRAM 24–48 GiB. Setting MAX_MODEL_LEN=${MAX_MODEL_LEN}."
else
  # 48+ GiB (e.g., A100 80G x2): allow up to native context
  MAX_MODEL_LEN=65536
  info "High-VRAM setup detected. Setting MAX_MODEL_LEN=${MAX_MODEL_LEN}."
fi

# --- Swap Space (KV Cache Offload) -------------------------------------------
# Disabled by default; enable if system RAM ≥ 64 GiB and NVMe swap is fast.
SWAP_SPACE=4  # GiB, minimal — change to 0 to disable CPU offload

# --- Quantization -------------------------------------------------------------
# AWQ (Activation-aware Weight Quantization) — matches the model variant.
QUANTIZATION=awq

# --- vLLM API Server Settings ------------------------------------------------
HOST="0.0.0.0"   # inside container; host-side binding controlled by BIND_HOST
PORT="${PORT:-8000}"

# --- HuggingFace Cache -------------------------------------------------------
HF_CACHE_DIR="${HOME}/.cache/huggingface"

# Display calculated parameters
echo ""
echo -e "${BOLD}  Calculated vLLM Configuration:${RESET}"
printf "  %-30s %s\n" "MODEL:"                "${MODEL}"
printf "  %-30s %s\n" "TENSOR_PARALLEL_SIZE:" "${TENSOR_PARALLEL_SIZE}"
printf "  %-30s %s\n" "MAX_MODEL_LEN:"        "${MAX_MODEL_LEN} tokens"
printf "  %-30s %s\n" "GPU_MEMORY_UTILIZATION:" "${GPU_MEMORY_UTILIZATION}"
printf "  %-30s %s\n" "SWAP_SPACE:"           "${SWAP_SPACE} GiB"
printf "  %-30s %s\n" "PORT:"                 "${PORT}"
printf "  %-30s %s\n" "GPU_DEVICE_ID:"        "${GPU_DEVICE_ID}"
echo ""

# =============================================================================
# STEP 4 — Write deploy/.env
# =============================================================================

if [[ "${ENV_EXISTS}" == "false" ]]; then
  step "STEP 4/4 — Creating ${ENV_FILE}"
  info "No existing scripts/deploy/.env found — generating a new one from scratch."

  cat > "${ENV_FILE}" <<EOF
# =============================================================================
# scripts/deploy/.env — Auto-generated by scripts/tuning/tune-inference.sh
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# GPU Count: ${GPU_COUNT}  |  Per-GPU VRAM: ${PRIMARY_VRAM_GiB} GiB  |  Total: ${TOTAL_VRAM_GiB} GiB
# =============================================================================

# --- Model Configuration -----------------------------------------------------
# HuggingFace model ID for Qwen2.5-Coder-32B-Instruct in AWQ quantization.
# To use a different model, set MODEL in scripts/deploy/.env before running deploy.sh.
MODEL=${MODEL}

# API alias served to clients (avoids slash in HF ID breaking some clients).
SERVED_MODEL_NAME=${SERVED_MODEL_NAME}

# --- Parallelism -------------------------------------------------------------
# Number of GPUs for tensor parallelism. Must match physical GPU count.
TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE}

# --- Memory Management -------------------------------------------------------
# Fraction of GPU VRAM vLLM may allocate (0.0–1.0).
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}

# Maximum sequence length (prompt + completion). KV cache scales linearly.
# Reduce this value if encountering CUDA OOM during KV cache allocation.
MAX_MODEL_LEN=${MAX_MODEL_LEN}

# CPU swap space (GiB) for KV cache offload. Set to 0 to disable.
SWAP_SPACE=${SWAP_SPACE}

# --- Quantization ------------------------------------------------------------
# AWQ (Activation-aware Weight Quantization) — matches the model variant.
QUANTIZATION=${QUANTIZATION}

# --- Server Settings ---------------------------------------------------------
# Host network interface inside container; port inside container
HOST=${HOST}
PORT=${PORT}

# --- HuggingFace Cache -------------------------------------------------------
HF_CACHE_DIR=${HF_CACHE_DIR}

# --- GPU CDI ID --------------------------------------------------------------
# The device ID used for CDI device reservation in docker-compose.
GPU_DEVICE_ID=${GPU_DEVICE_ID}

# --- Optional Performance Flags ----------------------------------------------
# Uncomment to enable speculative decoding (requires a draft model).
# SPECULATIVE_MODEL=Qwen/Qwen2.5-Coder-1.5B-Instruct
# NUM_SPECULATIVE_TOKENS=5

# Uncomment to force a specific dtype (default: auto)
# DTYPE=float16
EOF

  ok "${ENV_FILE} created."
else
  step "STEP 4/4 — Updating tuned values in ${ENV_FILE}"
  info "Existing scripts/deploy/.env found. Only these hardware-tuned keys are updated:"
  info "${TUNED_KEYS[*]}"
  warn "Everything else in the file (MODEL, network settings, HF_TOKEN,"
  warn "optional feature flags, comments, ordering) is left exactly as-is."
  echo ""

  CHANGED=false
  print_diff() {
    local key="$1" old="$2" new="$3"
    if [[ "${old}" == "${new}" ]]; then
      printf "  %-26s %-10s (unchanged)\n" "${key}:" "${new}"
    else
      CHANGED=true
      printf "  %-26s ${YELLOW}%s -> %s${RESET}\n" "${key}:" "${old:-<unset>}" "${new}"
    fi
  }
  print_diff "TENSOR_PARALLEL_SIZE"   "${OLD_TENSOR_PARALLEL_SIZE}"   "${TENSOR_PARALLEL_SIZE}"
  print_diff "GPU_MEMORY_UTILIZATION" "${OLD_GPU_MEMORY_UTILIZATION}" "${GPU_MEMORY_UTILIZATION}"
  print_diff "MAX_MODEL_LEN"          "${OLD_MAX_MODEL_LEN}"          "${MAX_MODEL_LEN}"
  print_diff "SWAP_SPACE"             "${OLD_SWAP_SPACE}"             "${SWAP_SPACE}"
  print_diff "QUANTIZATION"           "${OLD_QUANTIZATION}"           "${QUANTIZATION}"
  print_diff "GPU_DEVICE_ID"          "${OLD_GPU_DEVICE_ID}"          "${GPU_DEVICE_ID}"
  echo ""

  if [[ "${CHANGED}" == "true" ]]; then
    set_env_var TENSOR_PARALLEL_SIZE   "${TENSOR_PARALLEL_SIZE}"
    set_env_var GPU_MEMORY_UTILIZATION "${GPU_MEMORY_UTILIZATION}"
    set_env_var MAX_MODEL_LEN          "${MAX_MODEL_LEN}"
    set_env_var SWAP_SPACE             "${SWAP_SPACE}"
    set_env_var QUANTIZATION           "${QUANTIZATION}"
    set_env_var GPU_DEVICE_ID          "${GPU_DEVICE_ID}"
    ok "${ENV_FILE} updated — tuned values above applied, nothing else touched."
  else
    ok "No tuned values changed — ${ENV_FILE} left untouched."
  fi
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Tuning complete. Config written to scripts/deploy/.env      ║${RESET}"
echo -e "${GREEN}${BOLD}║  Review and adjust values before launching the server.        ║${RESET}"
echo -e "${GREEN}${BOLD}║  Next step: bash scripts/deploy/validate-system.sh           ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
