#!/usr/bin/env bash
#
# up5k-rv formal-toolchain smoke gate (M0, Phase 2).
#
# Proves the riscv-formal toolchain end-to-end using the STOCK picorv32 binding
# (formal/riscv-formal/cores/picorv32) with the rv32imc spec, before any of our
# own core RTL exists. Runs a representative GREEN subset of generated checks
# through SymbiYosys (sby) and reports PASS/FAIL per check.
#
# This is a de-risk smoke, not full proof coverage (that is M3+ scope). It does
# NOT touch rtl/ or docs/.
#
# The stock core RTL is vendored at third_party/picorv32.v (pinned to a specific
# upstream commit; no network fetch at runtime). The .sby check files must be
# generated first -- either by this script's auto-gen logic below or by the
# explicit `make formal-smoke-generate` target. Each check runs in its default
# mode/depth from cores/picorv32/checks.cfg (bmc, depth 20 for insn checks),
# bounded to 900 s per check via `timeout`.
#
# Smoke logs are written under build/smoke/ (gitignored), not into the
# riscv-formal submodule tree.
#
# Exits non-zero on any check failure.

set -u

# Resolve the repo root relative to this script (scripts/ is one level below
# the repo root) -- same pattern as scripts/env.sh and scripts/lint.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# Load the pinned toolchain (PATH, REPO_ROOT). No-op if tools are absent.
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env.sh"

# Directory of the riscv-formal submodule checks for picorv32.
RISCV_FORMAL_DIR="${REPO_ROOT}/formal/riscv-formal"
CORE_DIR="${RISCV_FORMAL_DIR}/cores/picorv32"
CHECKS_DIR="${CORE_DIR}/checks"

# Vendored, pinned copy of the stock picorv32 core RTL.
VENDORED_CORE="${REPO_ROOT}/third_party/picorv32.v"

# Smoke log directory (gitignored build artifact; NOT in the submodule tree).
LOG_DIR="${REPO_ROOT}/build/smoke"

# Per-check timeout in seconds (900 = 15 min).
CHECK_TIMEOUT="${FORMAL_SMOKE_TIMEOUT:-900}"

# ---------------------------------------------------------------------------
# Green subset (verified against stock picorv32, rv32imc, default bmc mode):
#   - ALU ops:           add, sub, xor
#   - load / store:      lw, sw
#   - branch:            beq
#   - jal / jalr:        jal, jalr
#   - compressed (C):    c_add, c_lw
#   - M-extension:       mul, mulh
#   - consistency:       reg, pc_fwd, pc_bwd
# ---------------------------------------------------------------------------
CHECKS=(
  insn_add_ch0
  insn_sub_ch0
  insn_xor_ch0
  insn_lw_ch0
  insn_sw_ch0
  insn_beq_ch0
  insn_jal_ch0
  insn_jalr_ch0
  insn_c_add_ch0
  insn_c_lw_ch0
  insn_mul_ch0
  insn_mulh_ch0
  reg_ch0
  pc_fwd_ch0
  pc_bwd_ch0
)

FAILED=0

# --- 1. Ensure the vendored core RTL is present ---------------------------------
if [ ! -f "${VENDORED_CORE}" ]; then
  echo "formal_smoke.sh: ERROR: vendored core not found at ${VENDORED_CORE}" >&2
  echo "                Expected a pinned copy of YosysHQ/picorv32 (see header)." >&2
  exit 1
fi

# The stock picorv32 binding expects picorv32.v in cores/picorv32/. Copy the
# vendored file into place only if missing (no network fetch).
if [ ! -f "${CORE_DIR}/picorv32.v" ]; then
  echo "==> [formal-smoke] copying vendored picorv32.v into binding"
  cp "${VENDORED_CORE}" "${CORE_DIR}/picorv32.v" \
    || { echo "formal_smoke.sh: ERROR: failed to copy vendored core" >&2; exit 1; }
fi

# --- 2. Generate the .sby check files if they do not exist yet ------------------
if [ ! -f "${CHECKS_DIR}/insn_add_ch0.sby" ]; then
  echo "==> [formal-smoke] generating checks (genchecks.py)"
  (cd "${CORE_DIR}" && python3 ../../checks/genchecks.py) \
    || { echo "formal_smoke.sh: ERROR: check generation failed" >&2; exit 1; }
fi

if [ ! -d "${CHECKS_DIR}" ]; then
  echo "formal_smoke.sh: ERROR: ${CHECKS_DIR} does not exist." >&2
  echo "                Run `make formal-smoke-generate` first." >&2
  exit 1
fi

# --- 3. Create the log directory ------------------------------------------------
mkdir -p "${LOG_DIR}"

echo "==> [formal-smoke] stock picorv32 / rv32imc subset (${#CHECKS[@]} checks)"
echo "    checks dir: ${CHECKS_DIR}"
echo "    riscv-formal pin: $(git -C "${RISCV_FORMAL_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "    vendored core:    ${VENDORED_CORE}"
echo "    log dir:          ${LOG_DIR}"
echo "    per-check timeout: ${CHECK_TIMEOUT}s"
echo

# --- 4. Run each check -----------------------------------------------------------
for c in "${CHECKS[@]}"; do
  if [ ! -f "${CHECKS_DIR}/${c}.sby" ]; then
    echo "    [formal-smoke] ${c}: MISSING (.sby not generated) -> FAIL"
    FAILED=1
    continue
  fi

  start=$(date +%s)
  if timeout "${CHECK_TIMEOUT}" sby -f "${CHECKS_DIR}/${c}.sby" > "${LOG_DIR}/${c}.smoke.log" 2>&1; then
    end=$(date +%s)
    echo "    [formal-smoke] ${c}: PASS  ($((end - start))s)"
  else
    end=$(date +%s)
    echo "    [formal-smoke] ${c}: FAIL  ($((end - start))s)"
    echo "        log: ${LOG_DIR}/${c}.smoke.log"
    FAILED=1
  fi
done

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "formal_smoke.sh: PASS (all ${#CHECKS[@]} stock picorv32 checks green)"
else
  echo "formal_smoke.sh: FAIL (see above)"
fi

exit "${FAILED}"
