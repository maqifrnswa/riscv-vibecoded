#!/usr/bin/env bash
#
# up5k-rv lint gate.
#
# Runs the two mandatory lint checks from docs/standards.md:
#   1. yosys read_slang (frontend/lint)
#   2. verilator --lint-only (stricter SV check)
# on the current set of RTL modules.
#
# Exits non-zero on any failure and prints a clear PASS/FAIL summary.
#
# NOTE: This will fail right now if the OSS CAD Suite is not yet installed
# (M0 provisioning is still in progress). The script itself is complete.

set -euo pipefail

# Resolve the repo root relative to this script (scripts/ is one level below
# the repo root) -- same pattern as scripts/env.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# Load the pinned toolchain (PATH, REPO_ROOT). No-op if tools are absent.
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/env.sh"

cd "${REPO_ROOT}"

# Modules to lint (sources, no testbenches).
HELLO_SRC="rtl/hello/hello.sv"
CORE_SRC="rtl/core/up5k_rv_pkg.sv rtl/core/decoder.sv rtl/core/regfile.sv \
rtl/core/alu.sv rtl/core/lsu.sv rtl/core/fetch_unit.sv rtl/core/rv32i_core.sv"

FAILED=0

# --- 1. yosys read_slang lint -----------------------------------------------
echo "==> [lint] yosys read_slang: ${HELLO_SRC}"
if yosys -Q -p "read_slang ${HELLO_SRC}; check"; then
  echo "    [lint] yosys read_slang (hello): PASS"
else
  echo "    [lint] yosys read_slang (hello): FAIL"
  FAILED=1
fi

echo "==> [lint] yosys read_slang: ${CORE_SRC}"
if yosys -Q -p "read_slang ${CORE_SRC}; check"; then
  echo "    [lint] yosys read_slang (core): PASS"
else
  echo "    [lint] yosys read_slang (core): FAIL"
  FAILED=1
fi

# --- 2. verilator --lint-only ------------------------------------------------
# --timing is intentionally omitted: not required for these modules and avoids
# depending on the installed Verilator having it enabled.
echo "==> [lint] verilator --lint-only: ${HELLO_SRC}"
if verilator --lint-only -Wall -Wno-fatal ${HELLO_SRC}; then
  echo "    [lint] verilator --lint-only (hello): PASS"
else
  echo "    [lint] verilator --lint-only (hello): FAIL"
  FAILED=1
fi

echo "==> [lint] verilator --lint-only: ${CORE_SRC}"
if verilator --lint-only -Wall -Wno-fatal ${CORE_SRC}; then
  echo "    [lint] verilator --lint-only (core): PASS"
else
  echo "    [lint] verilator --lint-only (core): FAIL"
  FAILED=1
fi

# --- Summary ----------------------------------------------------------------
if [ "${FAILED}" -eq 0 ]; then
  echo "lint.sh: PASS (all gates clean)"
else
  echo "lint.sh: FAIL (see above)"
fi

exit "${FAILED}"
