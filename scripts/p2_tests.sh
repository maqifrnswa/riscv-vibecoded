#!/usr/bin/env bash
#
# up5k-rv -- M1 P2 directed tests (staged leaf tests + core integration).
#
# Runs the self-checking iverilog testbenches in dv/p2/ against the rtl/core
# modules. Each test prints "PASS <name>" and exits 0 on success. This is the
# per-stage verification gate from the M1 deepwork plan; the formal rv32i
# prove (P3) is the second, stronger gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# Load the pinned toolchain (PATH, REPO_ROOT). No-op if tools are absent.
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env.sh"

cd "${REPO_ROOT}"
mkdir -p build

# All core sources are compiled for every test; unused modules are harmless.
CORE_SRC="rtl/core/up5k_rv_pkg.sv rtl/core/decoder.sv rtl/core/regfile.sv \
rtl/core/alu.sv rtl/core/lsu.sv rtl/core/fetch_unit.sv rtl/core/rv32i_core.sv"

FAILED=0

run_test() {
  local name="$1"
  shift
  local out="build/tb_${name}"
  if iverilog -g2012 -o "${out}" "$@" 2>"${out}.err" \
      && vvp "${out}" >"${out}.log" 2>&1; then
    if grep -q "^PASS" "${out}.log"; then
      echo "==> p2: ${name}: PASS"
    else
      echo "==> p2: ${name}: FAIL (no PASS line)"
      sed -n '1,40p' "${out}.log"
      FAILED=1
    fi
  else
    echo "==> p2: ${name}: FAIL (compile/run)"
    grep -v "sorry" "${out}.err" | sed -n '1,40p'
    sed -n '1,40p' "${out}.log" 2>/dev/null
    FAILED=1
  fi
}

run_test regfile     ${CORE_SRC} dv/p2/tb_regfile.sv
run_test alu         ${CORE_SRC} dv/p2/tb_alu.sv
run_test decoder     ${CORE_SRC} dv/p2/tb_decoder.sv
run_test lsu         ${CORE_SRC} dv/p2/tb_lsu.sv
run_test fetch_unit  ${CORE_SRC} dv/p2/tb_fetch_unit.sv
run_test core        ${CORE_SRC} dv/p2/tb_core.sv

if [ "${FAILED}" -eq 0 ]; then
  echo "p2_tests.sh: PASS (all stages green)"
else
  echo "p2_tests.sh: FAIL (see above)"
fi

exit "${FAILED}"
