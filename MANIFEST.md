# up5k-rv — M0 Toolchain & Dependency Manifest

Durable version record for the up5k-rv project (M0 provisioning + Phase 2
formal-toolchain smoke). This file is tracked in git; the per-session deepwork
progress files under `.slim/deepwork/` are git-ignored and are **not** the
version record.

## Tool pins

| Tool | Version |
|------|---------|
| yosys | 0.68+48 (git sha1 ff5817c34-dirty, Release) |
| nextpnr-ice40 | 0.11-1-g62e659ed |
| verilator | 5.051 devel (rev v5.050-159-g490bd3896) |
| iverilog | 14.0 devel (s20260301-359-g008b76eae-dirty) |
| sby | 0.68 |
| riscv gcc | riscv-none-elf-gcc (xPack) 15.2.0-1 (newlib) |
| riscv-formal | c992aa61fdfe0846c5ed90324c596202a1c69b76 |
| picorv32.v (vendored) | a473fc8fca393771d83b0ffcf0b14db3393339d8 (blob cc45fa998f1857b06a856ea59b931f6c37e06b34) |

## Toolchain location

Tools are installed outside the repo at `/home/agent/up5k-tools` (native Linux
FS). This is deliberate: the repo lives on a Windows-backed mount
(`/c/Users/...`) that cannot create symlinks, which the OSS CAD Suite and the
xPack toolchain require. Override the location with the `UP5K_TOOLS_ROOT`
environment variable if a different install path is in use.

## Smoke evidence (M0 Phase 2 — riscv-formal toolchain de-risk)

Stock **picorv32** binding from riscv-formal, **rv32imc** spec, before any own
core RTL existed. 15 representative checks run via SymbiYosys:

- Mode: `bmc`, depth 20 (from `cores/picorv32/checks.cfg`), engine `smtbmc boolector`.
- Result: **15/15 PASS** (all green).
- Coverage: ALU (add/sub/xor), load (lw), store (sw), branch (beq),
  jal/jalr, compressed C (c_add/c_lw), M-extension (mul/mulh), consistency
  (reg, pc_fwd, pc_bwd).
- Date: 2026-08-11.
- Wired into `make formal-smoke` (see scripts/formal_smoke.sh).

The full 87-check suite and prove-mode proofs are **M3+ scope**, not M0.

### prove-mode engine sanity check (oracle recommendation, closes R-1)

- Check: `insn_xor_ch0`, mode `prove` (unbounded induction), engine `abc pdr`.
- Result: **TIMEOUT** — ran the full pipeline (yosys aig + `pdr` on the AIG),
  reached frame 14 with increasing per-output timeouts, but did not complete the
  unbounded proof within 1800 s. No counterexample found (not a FAIL). The
  prove-mode engine path is validated as functional; full PDR convergence on the
  stock picorv32 is deferred to M3 prove coverage.

## How to reproduce

```sh
source scripts/env.sh      # pin PATH (tools at /home/agent/up5k-tools)
make lint                  # yosys read_slang + verilator --lint-only
make formal-smoke          # 15 green stock-picorv32 checks, ~7-8 min
make formal-smoke-generate # (optional) regenerate the .sby checks explicitly
```
