#!/usr/bin/env bash
#
# up5k-rv -- M1 P3: riscv-formal rv32i prove for the RV32I core.
#
# Proves rtl/core/rv32i_core.sv against the riscv-formal rv32i model suite
# through the formal/rvfi_channel wrapper (formal/up5k_rv/).
#
# Pipeline:
#   1. scripts/formal_m1_gen.py -- stage + generate the sby check files on
#      NATIVE FS ($TMPDIR/up5k-rv-formal/cores/up5k_rv/checks) and
#      post-process them (read_slang partition, RESET_CYCLES=8, bmc-mode
#      consistency checks). Generation runs on native FS because the repo's
#      virtiofs mount corrupts getcwd() after any rmtree/write on it.
#   2. Run the checks: 37 insn checks + pc_fwd in prove mode (k-induction,
#      smtbmc yices per M1 P1a); reg/pc_bwd in bmc mode; cover in cover mode.
#      Parallelized across cores; per-check timeout; logs in build/m1/.
#
# Exit criteria (docs/roadmap.md M1): the full rv32i check set green.
#
# Usage:
#   scripts/formal_m1.sh            # full prove suite
#   scripts/formal_m1.sh --smoke    # fast bmc subset (CI per-PR smoke)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env.sh"

# CHECKS_DIR is assigned below from the generator's output (native FS staging).
LOG_DIR="${REPO_ROOT}/build/m1"
CHECK_TIMEOUT="${FORMAL_M1_TIMEOUT:-1800}"   # per-check (s)
PARALLEL="${FORMAL_M1_PARALLEL:-8}"          # modest: reads still hit virtiofs
# sby workdirs must live on NATIVE filesystem, NOT the repo's virtiofs mount:
# removing a leftover workdir (a child of the sby cwd) transiently invalidates
# getcwd() on virtiofs, crashing sby with "os.getcwd(): FileNotFoundError".
WORK_ROOT="${FORMAL_M1_WORK:-/tmp/up5k-m1-sby}"

MODE="${1:-full}"

# Full prove set (36 RV32I instructions) + pc_fwd (prove).
INSN_CHECKS=(
  insn_add_ch0 insn_addi_ch0 insn_and_ch0 insn_andi_ch0 insn_auipc_ch0
  insn_beq_ch0 insn_bge_ch0 insn_bgeu_ch0 insn_blt_ch0 insn_bltu_ch0
  insn_bne_ch0 insn_jal_ch0 insn_jalr_ch0
  insn_lb_ch0 insn_lbu_ch0 insn_lh_ch0 insn_lhu_ch0 insn_lui_ch0 insn_lw_ch0
  insn_or_ch0 insn_ori_ch0 insn_sb_ch0 insn_sh_ch0
  insn_sll_ch0 insn_slli_ch0 insn_slt_ch0 insn_slti_ch0 insn_sltiu_ch0
  insn_sltu_ch0 insn_sra_ch0 insn_srai_ch0 insn_srl_ch0 insn_srli_ch0
  insn_sub_ch0 insn_sw_ch0 insn_xor_ch0 insn_xori_ch0
)
# bmc consistency checks + cover.
AUX_CHECKS=(reg_ch0 pc_fwd_ch0 pc_bwd_ch0 cover)

# --- 1. Generate the checks (staged on native FS; emits CHECKS_DIR last) --------
GEN_OUT=$(python3 "${REPO_ROOT}/scripts/formal_m1_gen.py" "${REPO_ROOT}") \
  || { echo "formal_m1.sh: ERROR: check generation failed" >&2; exit 1; }
CHECKS_DIR=$(printf '%s\n' "${GEN_OUT}" | tail -1)

if [ "${MODE}" = "--smoke" ]; then
  # CI per-PR smoke: a fast bmc subset (mirrors the M0 stock-core subset).
  RUN_CHECKS=(insn_add_ch0 insn_sub_ch0 insn_xor_ch0 insn_lw_ch0 insn_sw_ch0
              insn_beq_ch0 insn_jal_ch0 insn_jalr_ch0 reg_ch0 pc_fwd_ch0
              pc_bwd_ch0 cover)
  # The generated insn checks are prove-mode; for the smoke, switch the subset
  # to bmc in a NATIVE scratch dir (fast, shallow -- the full prove suite is
  # nightly).
  SMOKE_DIR="${WORK_ROOT}-smoke"
  mkdir -p "${SMOKE_DIR}"
  for c in "${RUN_CHECKS[@]}"; do
    sed 's/^mode prove$/mode bmc/; /`define RISCV_FORMAL_UNBOUNDED/d' \
      "${CHECKS_DIR}/${c}.sby" > "${SMOKE_DIR}/${c}.sby"
  done
  CHECKS_DIR="${SMOKE_DIR}"
  echo "==> [formal-m1] smoke mode: bmc subset in ${SMOKE_DIR}"
else
  RUN_CHECKS=("${INSN_CHECKS[@]}" "${AUX_CHECKS[@]}")
fi

mkdir -p "${LOG_DIR}" "${WORK_ROOT}"

echo "==> [formal-m1] ${MODE} suite (${#RUN_CHECKS[@]} checks)"
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
    echo "    [formal-m1] ${c}: PASS  ($((end - start))s)"
  elif [ "${rc}" -eq 124 ]; then
    echo "    [formal-m1] ${c}: TIMEOUT  (${CHECK_TIMEOUT}s) -- log: ${out}"
  elif grep -q "DONE (FAIL" "${out}"; then
    echo "    [formal-m1] ${c}: FAIL  ($((end - start))s) -- counterexample in ${wd}"
    echo "        log: ${out}"
  else
    echo "    [formal-m1] ${c}: ERROR (rc=${rc}, $((end - start))s) -- log: ${out}"
  fi
}
export -f run_one
export CHECKS_DIR LOG_DIR CHECK_TIMEOUT WORK_ROOT

MISSING=0
for c in "${RUN_CHECKS[@]}"; do
  if [ ! -f "${CHECKS_DIR}/${c}.sby" ]; then
    echo "    [formal-m1] ${c}: MISSING (.sby not generated)"
    MISSING=1
  fi
done

if [ "${MISSING}" -eq 1 ]; then
  echo "formal_m1.sh: ERROR: generated checks missing" >&2
  exit 1
fi

FAILED=0
# xargs: one sby per slot, single-threaded each; collect PASS/FAIL.
tmp=$(mktemp)
printf '%s\n' "${RUN_CHECKS[@]}" | xargs -P "${PARALLEL}" -I{} bash -c 'run_one "$@"' _ {} > "${tmp}" 2>&1
cat "${tmp}"
rm -f "${tmp}"

# --- 3. Summary -----------------------------------------------------------------
for c in "${RUN_CHECKS[@]}"; do
  if ! grep -q "DONE (PASS" "${LOG_DIR}/${c}.log"; then
    FAILED=1
  fi
done

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "formal_m1.sh: PASS (all ${#RUN_CHECKS[@]} rv32i checks green)"
else
  echo "formal_m1.sh: FAIL (see logs above / ${LOG_DIR}/)"
fi

exit "${FAILED}"
