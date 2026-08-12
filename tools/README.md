# tools/

**This directory is for project tooling only** (e.g. `uart_loader.py` and
similar helper scripts).

## RV32I test-vector encoder — `riscv_enc.py`

`python3 tools/riscv_enc.py` runs a self-check (asserts against encodings
verified by `dv/p2`). Use the helpers to build instruction words for directed
tests instead of hand-assembling hex constants — hand-assembled vectors
produced repeated wrong encodings in M1 P2. See the module docstring for the
funct3 tables and a usage example. Self-check is part of the M1 lint/test
habit: `python3 tools/riscv_enc.py && make p2-tests`.

## sby counterexample retire-stream extractor — `sby_retire_stream.py`

`python3 tools/sby_retire_stream.py <trace.vcd> [--all-instances] [--detail]`

When a riscv-formal check fails, prints one line per retirement in the sby
trace VCD (order, pc_rdata/pc_wdata, insn, rs/rd, mem fields, `spec_trap` vs
`rvfi_trap`, and the `check`-cycle marker) so the disagreement is visible at a
glance. Handles the flattened-trace pitfalls learned in M1 P3: `anyinit_*`
wires are init-state drivers (excluded), VCD value blocks lag their `#T` line,
and duplicated signal instances (`rvfi_trap`, `spec_trap`) resolve to the
first instance by default (`--all-instances` shows every one). `--detail`
adds the pipeline state (`phase_q`, `word_pending_q`, fetch state).

The actual toolchain installs (OSS CAD Suite and the xPack RISC-V toolchain)
**do NOT live here anymore.** They were relocated to `/home/agent/up5k-tools`:

| Toolchain | Location | Contents |
|---|---|---|
| OSS CAD Suite | `/home/agent/up5k-tools/oss-cad-suite` | yosys, nextpnr-ice40, icestorm, verilator, iverilog, sby |
| RISC-V toolchain | `/home/agent/up5k-tools/riscv-toolchain/xpack-riscv-none-elf-gcc-15.2.0-1` | riscv-gnu-toolchain (newlib) |

### Why they moved

The repo lives on a **Windows-backed mount** (`/c/Users/...`) that **cannot
create symlinks**. The OSS CAD Suite and the xPack toolchain rely on symlinks
for critical pieces (`lib/libvvp.so`, plugin `.so` files, `py3bin/python3`,
GCC `bin` links), so an in-repo install was broken. `/home/agent` is native
Linux and symlink-capable, so the installs now live there.

`scripts/env.sh` points at `/home/agent/up5k-tools` (not in-repo). It is
idempotent and tolerant of a missing RISC-V toolchain. The top-level `Makefile`
and `scripts/lint.sh` source it before invoking any tool.

The old in-repo copies under `tools/oss-cad-suite/` and `tools/riscv-toolchain/`
were broken and have been removed.
