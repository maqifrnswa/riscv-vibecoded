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
