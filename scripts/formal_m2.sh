#!/usr/bin/env bash
#
# up5k-rv -- M2 P2: riscv-formal rv32imc prove + live for the RV32IMC core.
#
# Proves rtl/core/rv32i_core.sv against the riscv-formal rv32imc model suite
# (I + C + M + traps + CSRs) through the formal wrapper (formal/up5k_rv/).
#
# Pipeline:
#   1. scripts/formal_m2_gen.py -- stage + generate the sby check files on
#      NATIVE FS ($TMPDIR/up5k-rv-formal-m2/cores/up5k_rv/checks) and
#      post-process them (read_slang partition, RESET_CYCLES=8, bmc-mode
#      consistency/csrc checks).
#   2. Run the checks: the 70 insn checks + pc_fwd + csrw in prove mode
#      (k-induction, smtbmc yices per M1 P1a); reg/pc_bwd/csrc in bmc mode;
#      liveness + cover. Parallelized across cores; per-check timeout; logs in
#      build/m2/.
#
# Exit criteria (docs/roadmap.md M2): rv32imc prove AND live green (ALTOPS).
#
# Usage:
#   scripts/formal_m2.sh            # full suite
#   scripts/formal_m2.sh --smoke    # fast bmc subset (CI per-PR smoke)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env.sh"

# CHECKS_DIR is assigned below from the generator's output (native FS staging).
LOG_DIR="${REPO_ROOT}/build/m2"
CHECK_TIMEOUT="${FORMAL_M2_TIMEOUT:-1800}"   # per-check (s)
PARALLEL="${FORMAL_M2_PARALLEL:-8}"
# sby workdirs must live on NATIVE filesystem, NOT the repo's virtiofs mount.
WORK_ROOT="${FORMAL_M2_WORK:-/tmp/up5k-m2-sby}"

MODE="${1:-full}"

# The 70 rv32imc instruction checks (from the model's ISA list: 37 I + 25 C +
# 8 M). M instructions are the ALTOPS fake ops (D18).
ISA_LIST="${REPO_ROOT}/formal/riscv-formal/insns/isa_rv32imc.txt"
mapfile -t INSN_NAMES < <(grep -v '^#' "${ISA_LIST}" | grep -v '^$' || true)
INSN_CHECKS=()
for n in "${INSN_NAMES[@]}"; do
  INSN_CHECKS+=("insn_${n}_ch0")
done
# bmc consistency checks + CSR counter checks (gen script switched these to
# bmc) + liveness + cover.
AUX_CHECKS=(reg_ch0 pc_fwd_ch0 pc_bwd_ch0 csrw_mcycle_ch0 csrc_inc_mcycle_ch0
            csrc_upcnt_mcycle_ch0 liveness_ch0 cover)

# --- 1. Generate the checks (staged on native FS; emits CHECKS_DIR last) --------
GEN_OUT=$(python3 "${REPO_ROOT}/scripts/formal_m2_gen.py" "${REPO_ROOT}") \
  || { echo "formal_m2.sh: ERROR: check generation failed" >&2; exit 1; }
CHECKS_DIR=$(printf '%s\n' "${GEN_OUT}" | tail -1)

if [ "${MODE}" = "--smoke" ]; then
  # CI per-PR smoke: a fast bmc subset.
  RUN_CHECKS=(insn_add_ch0 insn_sub_ch0 insn_xor_ch0 insn_lw_ch0 insn_sw_ch0
              insn_beq_ch0 insn_jal_ch0 insn_jalr_ch0 insn_c_add_ch0
              insn_c_lw_ch0 insn_mul_ch0 insn_div_ch0
              reg_ch0 pc_fwd_ch0 pc_bwd_ch0 csrw_mcycle_ch0 cover)
  SMOKE_DIR="${WORK_ROOT}-smoke"
  mkdir -p "${SMOKE_DIR}"
  for c in "${RUN_CHECKS[@]}"; do
    sed 's/^mode prove$/mode bmc/; /`define RISCV_FORMAL_UNBOUNDED/d' \
      "${CHECKS_DIR}/${c}.sby" > "${SMOKE_DIR}/${c}.sby" 2>/dev/null \
      || echo "    [formal-m2] ${c}: no .sby (skipped)"
  done
  CHECKS_DIR="${SMOKE_DIR}"
  echo "==> [formal-m2] smoke mode: bmc subset in ${SMOKE_DIR}"
else
  RUN_CHECKS=("${INSN_CHECKS[@]}" "${AUX_CHECKS[@]}")
fi

mkdir -p "${LOG_DIR}" "${WORK_ROOT}"

echo "==> [formal-m2] ${MODE} suite (${#RUN_CHECKS[@]} checks)"
echo "    checks dir: ${CHECKS_DIR}"
echo "    sby work:   ${WORK_ROOT} (native FS)"
echo "    riscv-formal pin: $(git -C "${REPO_ROOT}/formal/riscv-formal" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "    log dir:          ${LOG_DIR}"
echo "    per-check timeout: ${CHECK_TIMEOUT}s, parallel: ${PARALLEL}"
echo

# --- 2. Run the checks in parallel ----------------------------------------------
# NOTE: the generated .sby files use `expect pass,fail`, so sby returns rc=0
# for BOTH a proof PASS and a counterexample FAIL. The status must come from
# the log's final DONE line, not the exit code.
run_one() {
  local c="$1"
  local out="${LOG_DIR}/${c}.log"
  local wd="${WORK_ROOT}/${c}"
  rm -rf "${wd}"
  start=$(date +%s)
  timeout "${CHECK_TIMEOUT}" sby -d "${wd}" -f "${CHECKS_DIR}/${c}.sby" > "${out}" 2>&1
  local rc=$?
  end=$(date +%s)
  if grep -q "DONE (PASS" "${out}"; then
    echo "    [formal-m2] ${c}: PASS  ($((end - start))s)"
  elif [ "${rc}" -eq 124 ]; then
    echo "    [formal-m2] ${c}: TIMEOUT  (${CHECK_TIMEOUT}s) -- log: ${out}"
  elif grep -q "DONE (FAIL" "${out}"; then
    echo "    [formal-m2] ${c}: FAIL  ($((end - start))s) -- counterexample in ${wd}"
    echo "        log: ${out}"
  else
    echo "    [formal-m2] ${c}: ERROR (rc=${rc}, $((end - start))s) -- log: ${out}"
  fi
}
export -f run_one
export CHECKS_DIR LOG_DIR CHECK_TIMEOUT WORK_ROOT

MISSING=0
for c in "${RUN_CHECKS[@]}"; do
  if [ ! -f "${CHECKS_DIR}/${c}.sby" ]; then
    echo "    [formal-m2] ${c}: MISSING (.sby not generated)"
    MISSING=1
  fi
done

if [ "${MISSING}" -eq 1 ]; then
  echo "formal_m2.sh: ERROR: generated checks missing" >&2
  exit 1
fi

FAILED=0
tmp=$(mktemp)
printf '%s\n' "${RUN_CHECKS[@]}" | xargs -P "${PARALLEL}" -I{} bash -c 'run_one "$@"' _ {} > "${tmp}" 2>&1
cat "${tmp}"
rm -f "${tmp}"

# --- 3. Summary -----------------------------------------------------------------
for c in "${RUN_CHECKS[@]}"; do
  if ! grep -q "DONE (PASS" "${LOG_DIR}/${c}.log" 2>/dev/null; then
    FAILED=1
  fi
done

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "formal_m2.sh: PASS (all ${#RUN_CHECKS[@]} rv32imc checks green)"
else
  echo "formal_m2.sh: FAIL (see logs above / ${LOG_DIR}/)"
fi

exit "${FAILED}"
