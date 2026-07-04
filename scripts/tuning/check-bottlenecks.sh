#!/usr/bin/env bash
# =============================================================================
# check-bottlenecks.sh
# Deep-dive hardware & OS performance advisor for the vLLM dual-GPU host.
# Reads live topology/sysfs state and prints copy-pasteable optimization
# suggestions. Never mutates system configuration — read-only diagnostics.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}=== [ℹ]  $* ===${RESET}"; }
ok()    { echo -e "${GREEN}=== [✓]  $* ===${RESET}"; }
warn()  { echo -e "${YELLOW}=== [⚠]  $* ===${RESET}"; }
fail()  { echo -e "${RED}=== [✗]  $* ===${RESET}"; exit 1; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}──────────────────────────────────────────${RESET}"; }

# --- Usage: bash scripts/check-bottlenecks.sh [--json] ----------------------
# --json emits a single machine-readable JSON object on stdout instead of the
# colored human report (which moves to stderr), for consumption by other
# tooling (e.g. a future multi-config comparison script or dashboard).
JSON_MODE=false
if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=true
elif [[ -n "${1:-}" ]]; then
  fail "Unknown argument '${1}'. Usage: bash scripts/check-bottlenecks.sh [--json]"
fi

# Send the whole human report to stderr in JSON mode, keeping fd 3 as a
# handle to the real stdout so the final JSON blob lands there cleanly.
if [[ "${JSON_MODE}" == "true" ]]; then
  exec 3>&1 1>&2
fi

WARNINGS=()
RECOMMENDATIONS=()
PCIE_RECORDS=()
POWER_RECORDS=()
PERSISTENCE_RECORDS=()

if ! command -v nvidia-smi &>/dev/null; then
  fail "nvidia-smi not found. Run scripts/install-prereqs.sh first."
fi

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)

# =============================================================================
# STEP 1/5 — PCIe Bandwidth Analysis
# =============================================================================
step "STEP 1/5 — PCIe Bandwidth Analysis (Tensor Parallel Link Health)"

info "Tensor Parallelism on a dual-GPU rig relies on inter-GPU transfers over"
info "PCIe (NCCL all-reduce). Minimum viable link: Gen3 x8 or Gen4 x4 (~7.9 GB/s)."
echo ""

# Per-lane unidirectional bandwidth (GB/s) by PCIe generation.
per_lane_gbs() {
  case "$1" in
    1) echo "0.25"  ;;
    2) echo "0.50"  ;;
    3) echo "0.985" ;;
    4) echo "1.969" ;;
    5) echo "3.938" ;;
    *) echo "0"     ;;
  esac
}

# Gen3 x8 (or equivalently Gen4 x4) floor, in GB/s.
MIN_BANDWIDTH_GBS="7.88"

printf "  %-6s %-35s %-10s %-10s %-14s %s\n" \
  "GPU" "Name" "Gen.Cur" "Width.Cur" "Bandwidth" "Status"
printf "  %s\n" "$(printf '─%.0s' {1..100})"

PCIE_DEGRADED=false

for i in $(seq 0 $((GPU_COUNT - 1))); do
  NAME=$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader | xargs)
  GEN_CUR=$(nvidia-smi -i "$i" --query-gpu=pcie.link.gen.current --format=csv,noheader | xargs)
  WIDTH_CUR=$(nvidia-smi -i "$i" --query-gpu=pcie.link.width.current --format=csv,noheader | xargs)

  LANE_BW=$(per_lane_gbs "${GEN_CUR}")
  EFFECTIVE_BW=$(echo "scale=2; ${LANE_BW} * ${WIDTH_CUR}" | bc)

  BELOW_FLOOR=$(echo "${EFFECTIVE_BW} < ${MIN_BANDWIDTH_GBS}" | bc)

  if [[ "${BELOW_FLOOR}" -eq 1 ]]; then
    COLOR="${YELLOW}"; ICON="⚠"; STATUS="Below Gen3x8/Gen4x4 floor"
    PCIE_DEGRADED=true
    WARNINGS+=("GPU ${i} (${NAME}): PCIe link Gen${GEN_CUR} x${WIDTH_CUR} (~${EFFECTIVE_BW} GB/s) is below the Gen3x8/Gen4x4 floor (~${MIN_BANDWIDTH_GBS} GB/s). NCCL all-reduce will bottleneck tensor-parallel steps.")
    RECOMMENDATIONS+=("GPU ${i}: reseat the card, check BIOS PCIe bifurcation/Gen lock settings, or move it to a full x16/x8 electrical slot.")
  else
    COLOR="${GREEN}"; ICON="✓"; STATUS="OK"
  fi

  printf "  ${COLOR}%-6s %-35s Gen%-7s x%-9s %-14s %s${RESET}\n" \
    "${ICON} ${i}" "${NAME:0:35}" "${GEN_CUR}" "${WIDTH_CUR}" "${EFFECTIVE_BW} GB/s" "${STATUS}"

  PCIE_RECORDS+=("${i}"$'\x1f'"${NAME}"$'\x1f'"${GEN_CUR}"$'\x1f'"${WIDTH_CUR}"$'\x1f'"${EFFECTIVE_BW}"$'\x1f'"${BELOW_FLOOR}")
done
echo ""

if [[ "${PCIE_DEGRADED}" == "true" ]]; then
  warn "One or more GPUs are below the recommended PCIe bandwidth floor."
else
  ok "All GPU links meet or exceed the Gen3x8/Gen4x4 bandwidth floor."
fi

# =============================================================================
# STEP 2/5 — Power Cap Check
# =============================================================================
step "STEP 2/5 — Power Cap Check"

printf "  %-6s %-35s %-14s %-14s %s\n" \
  "GPU" "Name" "Limit (W)" "Max Cap (W)" "Status"
printf "  %s\n" "$(printf '─%.0s' {1..90})"

POWER_CAPPED=false

for i in $(seq 0 $((GPU_COUNT - 1))); do
  NAME=$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader | xargs)
  PWR_LIMIT=$(nvidia-smi -i "$i" --query-gpu=power.limit --format=csv,noheader,nounits | xargs)
  PWR_MAX=$(nvidia-smi -i "$i" --query-gpu=power.max_limit --format=csv,noheader,nounits | xargs)

  IS_CAPPED=$(echo "${PWR_LIMIT} < ${PWR_MAX}" | bc)

  if [[ "${IS_CAPPED}" -eq 1 ]]; then
    COLOR="${YELLOW}"; ICON="⚠"; STATUS="Throttled below board max"
    POWER_CAPPED=true
    WARNINGS+=("GPU ${i} (${NAME}): power limit set to ${PWR_LIMIT}W, below board max of ${PWR_MAX}W. Sustained inference throughput may be capped.")
    RECOMMENDATIONS+=("GPU ${i}: raise the software power limit with 'sudo nvidia-smi -i ${i} -pl ${PWR_MAX}' if thermal/PSU headroom allows.")
  else
    COLOR="${GREEN}"; ICON="✓"; STATUS="At board max"
  fi

  printf "  ${COLOR}%-6s %-35s %-14s %-14s %s${RESET}\n" \
    "${ICON} ${i}" "${NAME:0:35}" "${PWR_LIMIT}" "${PWR_MAX}" "${STATUS}"

  POWER_RECORDS+=("${i}"$'\x1f'"${NAME}"$'\x1f'"${PWR_LIMIT}"$'\x1f'"${PWR_MAX}"$'\x1f'"${IS_CAPPED}")
done
echo ""

if [[ "${POWER_CAPPED}" == "true" ]]; then
  warn "One or more GPUs are running below their maximum power capability."
else
  ok "All GPUs are running at their maximum board power capability."
fi

# =============================================================================
# STEP 3/5 — GPU Persistence Mode
# =============================================================================
step "STEP 3/5 — GPU Persistence Mode"

info "When persistence mode is off, the NVIDIA driver unloads its GPU state"
info "between clients, adding driver re-init latency to every fresh container"
info "start/restart — noticeable on validate-vram.sh startup and teardown.sh/restart cycles."
echo ""

printf "  %-6s %-35s %s\n" "GPU" "Name" "Persistence Mode"
printf "  %s\n" "$(printf '─%.0s' {1..70})"

PERSISTENCE_OFF=false

for i in $(seq 0 $((GPU_COUNT - 1))); do
  NAME=$(nvidia-smi -i "$i" --query-gpu=name --format=csv,noheader | xargs)
  PMODE=$(nvidia-smi -i "$i" --query-gpu=persistence_mode --format=csv,noheader | xargs)

  if [[ "${PMODE}" == "Disabled" ]]; then
    COLOR="${YELLOW}"; ICON="⚠"
    PERSISTENCE_OFF=true
    WARNINGS+=("GPU ${i} (${NAME}): persistence mode is Disabled — driver reloads between clients, adding init latency to every container start/restart.")
    RECOMMENDATIONS+=("GPU ${i}: enable persistence mode for faster driver init: sudo nvidia-smi -i ${i} -pm 1  (or 'sudo nvidia-smi -pm 1' for all GPUs; persists until reboot — add to a systemd unit or /etc/rc.local to survive reboots)")
  else
    COLOR="${GREEN}"; ICON="✓"
  fi

  printf "  ${COLOR}%-6s %-35s %s${RESET}\n" "${ICON} ${i}" "${NAME:0:35}" "${PMODE}"
  PERSISTENCE_RECORDS+=("${i}"$'\x1f'"${NAME}"$'\x1f'"${PMODE}")
done
echo ""

if [[ "${PERSISTENCE_OFF}" == "true" ]]; then
  warn "One or more GPUs have persistence mode disabled."
else
  ok "All GPUs have persistence mode enabled."
fi

# =============================================================================
# STEP 4/5 — OS Tuning Feedback
# =============================================================================
step "STEP 4/5 — OS Tuning Feedback"

# --- Transparent Huge Pages --------------------------------------------------
THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
THP_ACTIVE="unavailable"

if [[ -r "${THP_PATH}" ]]; then
  THP_RAW=$(cat "${THP_PATH}")
  THP_ACTIVE=$(echo "${THP_RAW}" | grep -oP '(?<=\[)[a-z]+(?=\])' || echo "unknown")

  info "Transparent Huge Pages (THP): ${THP_RAW}"

  case "${THP_ACTIVE}" in
    always)
      ok "THP mode: always — optimal for large contiguous KV-cache allocations."
      ;;
    madvise)
      warn "THP mode: madvise — vLLM's allocator may not opt in automatically."
      RECOMMENDATIONS+=("THP: set to 'always' for lower TLB-miss overhead on large tensor allocations: echo always | sudo tee ${THP_PATH}")
      ;;
    never)
      warn "THP mode: never — large model weight/KV-cache allocations will use 4K pages."
      WARNINGS+=("Transparent Huge Pages are disabled (never). This increases TLB pressure for large tensor allocations.")
      RECOMMENDATIONS+=("THP: enable with: echo always | sudo tee ${THP_PATH}")
      ;;
    *)
      warn "THP mode: unrecognized value in ${THP_PATH} — could not parse."
      ;;
  esac
else
  warn "Cannot read ${THP_PATH} (not present or insufficient permissions)."
fi

echo ""

# --- CPU Governor -------------------------------------------------------------
GOV_FILES=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
declare -A GOV_COUNTS=()

if [[ -e "${GOV_FILES[0]}" ]]; then
  for f in "${GOV_FILES[@]}"; do
    GOV=$(cat "$f" 2>/dev/null || echo "unknown")
    GOV_COUNTS["${GOV}"]=$(( ${GOV_COUNTS["${GOV}"]:-0} + 1 ))
  done

  info "CPU governor distribution across $(nproc) logical CPUs:"
  for gov in "${!GOV_COUNTS[@]}"; do
    echo "    ${gov}: ${GOV_COUNTS[$gov]} core(s)"
  done

  if [[ -n "${GOV_COUNTS[powersave]:-}" ]]; then
    warn "CPU governor 'powersave' detected on ${GOV_COUNTS[powersave]} core(s)."
    WARNINGS+=("${GOV_COUNTS[powersave]} CPU core(s) are running the 'powersave' governor, which increases token pre-fill latency due to frequency scaling ramp-up.")
    RECOMMENDATIONS+=("CPU governor: switch to 'performance' for lower pre-fill latency: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor  (or: sudo cpupower frequency-set -g performance)")
  else
    ok "No cores running 'powersave' governor."
  fi
else
  warn "cpufreq scaling_governor interface not found (cpufreq driver may be unavailable, e.g. in a VM)."
fi

# =============================================================================
# STEP 5/5 — System RAM & HF Cache Storage (KV-Cache Swap Suitability)
# =============================================================================
step "STEP 5/5 — System RAM & Storage (KV-Cache Swap Suitability)"

info "scripts/deploy/.env.example's SWAP_SPACE guidance: only beneficial if system RAM"
info ">= 64 GiB and the HuggingFace cache lives on NVMe. This step verifies both."
echo ""

# --- System RAM ---------------------------------------------------------------
RAM_TOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
RAM_TOTAL_GIB=$(echo "scale=1; ${RAM_TOTAL_KB} / 1024 / 1024" | bc)
RAM_MEETS_64G=$(echo "${RAM_TOTAL_GIB} >= 64" | bc)

info "System RAM: ${RAM_TOTAL_GIB} GiB"

# --- HF cache storage device ---------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/scripts/deploy/.env"

HF_CACHE_DIR="${HOME}/.cache/huggingface"
if [[ -f "${ENV_FILE}" ]]; then
  ENV_HF_CACHE_DIR=$(grep '^HF_CACHE_DIR=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' || true)
  [[ -n "${ENV_HF_CACHE_DIR}" ]] && HF_CACHE_DIR="${ENV_HF_CACHE_DIR}"
else
  info "scripts/deploy/.env not generated yet (run tune-inference.sh) — checking the default HF cache path."
fi

# Walk up to the nearest existing ancestor so `df` has something to resolve
# even before the cache directory itself has been created.
DF_TARGET="${HF_CACHE_DIR}"
while [[ ! -d "${DF_TARGET}" && "${DF_TARGET}" != "/" ]]; do
  DF_TARGET="$(dirname "${DF_TARGET}")"
done
[[ -d "${DF_TARGET}" ]] || DF_TARGET="${HOME}"

STORAGE_ROTATIONAL=false
STORAGE_IS_NVME=false
STORAGE_MODEL="unknown"
STORAGE_DEV=""

if command -v lsblk &>/dev/null && command -v df &>/dev/null; then
  STORAGE_DEV=$(df --output=source "${DF_TARGET}" 2>/dev/null | tail -1 | xargs)
  if [[ -n "${STORAGE_DEV}" && "${STORAGE_DEV}" == /dev/* ]]; then
    ROTA=$(lsblk -no rota "${STORAGE_DEV}" 2>/dev/null | head -1 | xargs)
    PKNAME=$(lsblk -no pkname "${STORAGE_DEV}" 2>/dev/null | head -1 | xargs)
    PARENT_DEV="/dev/${PKNAME:-$(basename "${STORAGE_DEV}")}"
    STORAGE_MODEL=$(lsblk -no model "${PARENT_DEV}" 2>/dev/null | xargs || true)
    [[ -z "${STORAGE_MODEL}" ]] && STORAGE_MODEL="unknown"
    [[ "${ROTA}" == "1" ]] && STORAGE_ROTATIONAL=true
    [[ "$(basename "${PARENT_DEV}")" =~ ^nvme ]] && STORAGE_IS_NVME=true
  else
    warn "Could not resolve a block device for ${DF_TARGET} (network filesystem, overlay, or container mount?). Skipping storage rotational check."
  fi
else
  warn "lsblk or df not found — skipping HF cache storage check."
fi

if [[ -n "${STORAGE_DEV}" ]]; then
  if [[ "${STORAGE_IS_NVME}" == "true" ]]; then
    STORAGE_KIND="NVMe SSD"
  elif [[ "${STORAGE_ROTATIONAL}" == "false" ]]; then
    STORAGE_KIND="SATA/SAS SSD (non-rotational, not NVMe)"
  else
    STORAGE_KIND="Spinning HDD"
  fi
  info "HF cache path ${HF_CACHE_DIR} → ${STORAGE_DEV} (${STORAGE_MODEL:-unknown model}) — ${STORAGE_KIND}"
fi

# --- Read the configured (or default) SWAP_SPACE -------------------------------
SWAP_SPACE_VAL=4
if [[ -f "${ENV_FILE}" ]]; then
  ENV_SWAP=$(grep '^SWAP_SPACE=' "${ENV_FILE}" | cut -d'=' -f2- | tr -d '"' || true)
  [[ -n "${ENV_SWAP}" ]] && SWAP_SPACE_VAL="${ENV_SWAP}"
fi

echo ""
if ! [[ "${SWAP_SPACE_VAL}" =~ ^[0-9]+$ ]]; then
  warn "SWAP_SPACE value '${SWAP_SPACE_VAL}' in scripts/deploy/.env is not a plain integer — skipping swap-suitability check."
elif [[ "${SWAP_SPACE_VAL}" -gt 0 ]]; then
  if [[ "${STORAGE_ROTATIONAL}" == "true" ]]; then
    warn "SWAP_SPACE=${SWAP_SPACE_VAL} GiB is configured, but the HF cache path resolves to a spinning HDD (${STORAGE_DEV})."
    WARNINGS+=("SWAP_SPACE=${SWAP_SPACE_VAL} GiB is set, but KV-cache offload would land on a rotational disk (${STORAGE_DEV}, ${STORAGE_MODEL:-unknown model}) — offloaded requests could stall for seconds instead of milliseconds under burst load.")
    RECOMMENDATIONS+=("Either set SWAP_SPACE=0 in scripts/deploy/.env to disable CPU offload, or move HF_CACHE_DIR to an SSD/NVMe-backed path.")
  elif [[ "${RAM_MEETS_64G}" -eq 0 ]]; then
    warn "SWAP_SPACE=${SWAP_SPACE_VAL} GiB is configured, but system RAM (${RAM_TOTAL_GIB} GiB) is below the 64 GiB the docs recommend for swap to help."
    RECOMMENDATIONS+=("Consider SWAP_SPACE=0 in scripts/deploy/.env — below ~64 GiB system RAM, CPU offload competes with the OS/other processes for memory instead of providing headroom.")
  else
    ok "SWAP_SPACE=${SWAP_SPACE_VAL} GiB is configured on suitable hardware (${RAM_TOTAL_GIB} GiB RAM, non-rotational storage)."
  fi
else
  ok "SWAP_SPACE is disabled (0) — RAM/storage suitability for swap is not applicable."
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${YELLOW}${BOLD}║   Bottleneck scan completed with warnings (non-blocking):     ║${RESET}"
  echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  for w in "${WARNINGS[@]}"; do
    echo -e "${YELLOW}  ⚠  ${w}${RESET}"
  done

  if [[ ${#RECOMMENDATIONS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}  Recommended actions (copy-paste ready):${RESET}"
    for r in "${RECOMMENDATIONS[@]}"; do
      echo -e "  ${CYAN}→${RESET} ${r}"
    done
  fi
  echo ""
  echo -e "${CYAN}  Re-run this script after applying changes to confirm they took effect.${RESET}"
else
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║   No bottlenecks detected. Host is tuned for inference.       ║${RESET}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
fi

if [[ "${JSON_MODE}" != "true" ]]; then
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    exit 2
  else
    exit 0
  fi
fi

# =============================================================================
# JSON output (--json mode only) — written to the real stdout via fd 3
# =============================================================================
if [[ "${JSON_MODE}" == "true" ]]; then
  GOV_LINES=""
  for gov in "${!GOV_COUNTS[@]}"; do
    GOV_LINES+="${gov}"$'\x1f'"${GOV_COUNTS[$gov]}"$'\n'
  done

  PCIE_LINES=$(printf '%s\n' "${PCIE_RECORDS[@]}")
  POWER_LINES=$(printf '%s\n' "${POWER_RECORDS[@]}")
  PERSISTENCE_LINES=$(printf '%s\n' "${PERSISTENCE_RECORDS[@]}")
  WARNINGS_LINES=$(printf '%s\n' "${WARNINGS[@]:-}")
  RECS_LINES=$(printf '%s\n' "${RECOMMENDATIONS[@]:-}")

  PCIE_DEGRADED="${PCIE_DEGRADED}" POWER_CAPPED="${POWER_CAPPED}" PERSISTENCE_OFF="${PERSISTENCE_OFF}" \
  THP_ACTIVE="${THP_ACTIVE}" GPU_COUNT="${GPU_COUNT}" \
  PCIE_LINES="${PCIE_LINES}" POWER_LINES="${POWER_LINES}" PERSISTENCE_LINES="${PERSISTENCE_LINES}" GOV_LINES="${GOV_LINES}" \
  WARNINGS_LINES="${WARNINGS_LINES}" RECS_LINES="${RECS_LINES}" \
  RAM_TOTAL_GIB="${RAM_TOTAL_GIB}" STORAGE_DEV="${STORAGE_DEV}" STORAGE_MODEL="${STORAGE_MODEL}" \
  STORAGE_ROTATIONAL="${STORAGE_ROTATIONAL}" STORAGE_IS_NVME="${STORAGE_IS_NVME}" SWAP_SPACE_VAL="${SWAP_SPACE_VAL}" \
  python3 - >&3 <<'PYEOF'
import json
import os
import time

def parse_records(raw, fields):
    records = []
    for line in raw.split("\n"):
        if not line:
            continue
        parts = line.split("\x1f")
        records.append(dict(zip(fields, parts)))
    return records

def parse_list(raw):
    return [line for line in raw.split("\n") if line]

pcie = parse_records(os.environ["PCIE_LINES"], ["gpu", "name", "gen_current", "width_current", "effective_bandwidth_gbs", "below_floor"])
for r in pcie:
    r["gpu"] = int(r["gpu"])
    r["gen_current"] = int(r["gen_current"])
    r["width_current"] = int(r["width_current"])
    r["effective_bandwidth_gbs"] = float(r["effective_bandwidth_gbs"])
    r["below_floor"] = r["below_floor"] == "1"

power = parse_records(os.environ["POWER_LINES"], ["gpu", "name", "power_limit_w", "power_max_limit_w", "capped"])
for r in power:
    r["gpu"] = int(r["gpu"])
    r["power_limit_w"] = float(r["power_limit_w"])
    r["power_max_limit_w"] = float(r["power_max_limit_w"])
    r["capped"] = r["capped"] == "1"

persistence = parse_records(os.environ["PERSISTENCE_LINES"], ["gpu", "name", "persistence_mode"])
for r in persistence:
    r["gpu"] = int(r["gpu"])

governors = {}
for line in os.environ["GOV_LINES"].split("\n"):
    if not line:
        continue
    gov, count = line.split("\x1f")
    governors[gov] = int(count)

def try_float(s, default=None):
    try:
        return float(s)
    except (TypeError, ValueError):
        return default

record = {
    "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "gpu_count": int(os.environ["GPU_COUNT"]),
    "ram_total_gib": try_float(os.environ.get("RAM_TOTAL_GIB")),
    "storage": {
        "device": os.environ.get("STORAGE_DEV") or None,
        "model": os.environ.get("STORAGE_MODEL") or None,
        "rotational": os.environ.get("STORAGE_ROTATIONAL") == "true",
        "is_nvme": os.environ.get("STORAGE_IS_NVME") == "true",
    },
    "swap_space_gib": try_float(os.environ.get("SWAP_SPACE_VAL")),
    "pcie": pcie,
    "pcie_degraded": os.environ["PCIE_DEGRADED"] == "true",
    "power": power,
    "power_capped": os.environ["POWER_CAPPED"] == "true",
    "persistence": persistence,
    "persistence_mode_off": os.environ["PERSISTENCE_OFF"] == "true",
    "transparent_huge_pages": os.environ["THP_ACTIVE"],
    "cpu_governors": governors,
    "warnings": parse_list(os.environ["WARNINGS_LINES"]),
    "recommendations": parse_list(os.environ["RECS_LINES"]),
}
print(json.dumps(record, indent=2))
PYEOF
fi
