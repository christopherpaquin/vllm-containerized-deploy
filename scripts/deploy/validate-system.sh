#!/usr/bin/env bash
# =============================================================================
# validate-system.sh
# Pre-flight hardware & topology validation for the vLLM dual-GPU setup.
# Checks Docker-GPU connectivity, PCIe link health, and display server VRAM.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

WARNINGS=()

# =============================================================================
# STEP 1 — Preflight dependency checks
# =============================================================================
step "STEP 1/4 — Preflight Dependency Check"

for cmd in nvidia-smi docker jq; do
  if command -v "$cmd" &>/dev/null; then
    ok "${cmd} found."
  else
    fail "${cmd} not found. Run scripts/install-prereqs.sh first."
  fi
done

# =============================================================================
# STEP 2 — Docker ↔ GPU Connectivity Test
# =============================================================================
step "STEP 2/4 — Docker ↔ GPU Connectivity Test"

info "Running containerized nvidia-smi (may pull image once)..."

DOCKER_NVIDIA_OUTPUT=$(docker run --rm --gpus all \
  nvidia/cuda:12.2.2-base-ubuntu22.04 \
  nvidia-smi --query-gpu=index,name,driver_version,memory.total \
  --format=csv,noheader 2>&1) || {
  fail "Docker GPU test failed. Check NVIDIA runtime config.\nOutput: ${DOCKER_NVIDIA_OUTPUT}"
}

CONTAINER_GPU_COUNT=$(echo "${DOCKER_NVIDIA_OUTPUT}" | grep -c '.' || true)

if [[ "${CONTAINER_GPU_COUNT}" -lt 1 ]]; then
  fail "Docker container reports 0 GPUs. NVIDIA runtime may not be configured."
fi

ok "Docker can see ${CONTAINER_GPU_COUNT} GPU(s):"
while IFS=',' read -r idx name drv mem; do
  printf "    GPU %s: %-35s Driver: %-10s VRAM: %s MiB\n" \
    "$(echo "$idx" | xargs)" "$(echo "$name" | xargs)" \
    "$(echo "$drv" | xargs)" "$(echo "$mem" | xargs)"
done <<< "${DOCKER_NVIDIA_OUTPUT}"

# =============================================================================
# STEP 3 — PCIe Link Quality Analysis
# =============================================================================
step "STEP 3/4 — PCIe Link Quality Analysis"

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
info "Querying PCIe link topology for ${GPU_COUNT} GPU(s)..."

printf "\n  %-6s %-35s %-12s %-12s %-14s %-14s %s\n" \
  "GPU" "Name" "Gen.Cur" "Gen.Max" "Width.Cur" "Width.Max" "Status"
printf "  %s\n" "$(printf '─%.0s' {1..100})"

ALL_PCIE_OK=true

for i in $(seq 0 $((GPU_COUNT - 1))); do
  NAME=$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader | xargs)
  GEN_CUR=$(nvidia-smi -i "$i" --query-gpu=pcie.link.gen.current --format=csv,noheader | xargs)
  GEN_MAX=$(nvidia-smi -i "$i" --query-gpu=pcie.link.gen.max --format=csv,noheader | xargs)
  WIDTH_CUR=$(nvidia-smi -i "$i" --query-gpu=pcie.link.width.current --format=csv,noheader | xargs)
  WIDTH_MAX=$(nvidia-smi -i "$i" --query-gpu=pcie.link.width.max --format=csv,noheader | xargs)

  STATUS_MSG=""
  IS_DEGRADED=false

  if [[ "${GEN_CUR}" -lt "${GEN_MAX}" ]]; then
    STATUS_MSG+=" [PCIe Gen downgraded: Gen${GEN_CUR} < Gen${GEN_MAX}]"
    IS_DEGRADED=true; ALL_PCIE_OK=false
  fi
  if [[ "${WIDTH_CUR}" -lt "${WIDTH_MAX}" ]]; then
    STATUS_MSG+=" [Lane width reduced: x${WIDTH_CUR} < x${WIDTH_MAX}]"
    IS_DEGRADED=true; ALL_PCIE_OK=false
  fi

  if [[ "${IS_DEGRADED}" == "true" ]]; then
    COLOR="${YELLOW}"; ICON="⚠"
    WARNINGS+=("GPU ${i} (${NAME}): PCIe at Gen${GEN_CUR}x${WIDTH_CUR} (max Gen${GEN_MAX}x${WIDTH_MAX}) — slot bandwidth limited.")
  else
    COLOR="${GREEN}"; ICON="✓"; STATUS_MSG=" [Optimal]"
  fi

  printf "  ${COLOR}%-6s %-35s Gen%-9s Gen%-9s x%-13s x%-13s %s${RESET}\n" \
    "${ICON} ${i}" "${NAME}" "${GEN_CUR}" "${GEN_MAX}" \
    "${WIDTH_CUR}" "${WIDTH_MAX}" "${STATUS_MSG}"
done
echo ""

if [[ "${ALL_PCIE_OK}" == "false" ]]; then
  warn "One or more GPUs are running at degraded PCIe link settings."
  warn "This is common when a secondary slot is electrically x4 only."
  warn "Impact: NCCL all-reduce operations (Tensor Parallelism) use PCIe."
  warn "Mitigation: Check BIOS PCIe Gen lock, or swap GPU slot positions."
fi

info "This check compares each GPU against its own rated PCIe spec. For an"
info "absolute NCCL all-reduce bandwidth floor (Gen3x8 / Gen4x4), run:"
info "  bash scripts/check-bottlenecks.sh"

# =============================================================================
# STEP 4 — Display Server VRAM Budget Warning (GPU 0)
# =============================================================================
step "STEP 4/4 — Display Server VRAM Impact (GPU 0)"

GPU0_USED=$(nvidia-smi -i 0 --query-gpu=memory.used --format=csv,noheader,nounits | xargs)
GPU0_TOTAL=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits | xargs)
GPU0_NAME=$(nvidia-smi -i 0 --query-gpu=name --format=csv,noheader | xargs)

info "GPU 0 (${GPU0_NAME}): ${GPU0_USED} MiB used / ${GPU0_TOTAL} MiB total"

DISPLAY_VRAM_THRESHOLD_MiB=800

if [[ "${GPU0_USED}" -gt "${DISPLAY_VRAM_THRESHOLD_MiB}" ]]; then
  warn "GPU 0 is consuming ${GPU0_USED} MiB at idle — display server detected."
  warn "vLLM allocates GPU_MEMORY_UTILIZATION from remaining free VRAM."
  warn "Mitigation A: sudo systemctl isolate multi-user.target (kills display)"
  warn "Mitigation B: Lower GPU_MEMORY_UTILIZATION to 0.85 in deploy/.env"
  WARNINGS+=("GPU 0 has ${GPU0_USED} MiB VRAM used at idle (display server). Lower GPU_MEMORY_UTILIZATION or kill display manager.")
else
  ok "GPU 0 idle VRAM usage ${GPU0_USED} MiB — below threshold (${DISPLAY_VRAM_THRESHOLD_MiB} MiB). Safe to deploy."
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${YELLOW}${BOLD}║    Validation completed with warnings (non-blocking):        ║${RESET}"
  echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  for w in "${WARNINGS[@]}"; do
    echo -e "${YELLOW}  ⚠  ${w}${RESET}"
  done
  echo -e "\n${CYAN}  Review warnings above, then run: bash scripts/tune-inference.sh${RESET}"
else
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║    All checks passed. System is ready.                      ║${RESET}"
  echo -e "${GREEN}${BOLD}║    Next step: bash scripts/tuning/tune-inference.sh                ║${RESET}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
fi
