# up5k-rv — M1 Phase 1b: RVFI channel + formal frontend-mixing smoke

This directory contains a deliberately trivial SystemVerilog RV32I core
(`smoke_core.sv`) and its RVFI adapter (`rvfi_wrapper.sv`) that prove two
things for the M1 core work:

1. **The D14/R11 frontend-mixing path works.** Our SystemVerilog RTL is read by
   Yosys `read_slang`, while the riscv-formal Verilog checker harness is read
   by `read_verilog -sv`, in the *same* SymbiYosys run — and the formal proof
   is green.
2. **The RVFI channel conventions are validated** against a real riscv-formal
   instruction checker (`rvfi_insn_addi`), pinning the contract the real M1
   core must implement.

## What the smoke proves

- The trivial core retires exactly one instruction class — `addi` — and the
  riscv-formal `rvfi_insn_addi` checker confirms that retirement is
  architecturally correct (rd_wdata = rs1_rdata + sext(imm), pc += 4, no
  memory access, no trap).
- The instruction word under test is driven by a **free primary input**
  (`insn_i` on the wrapper, deliberately left unconnected by the harness so it
  becomes a free variable). The checker constrains it to a valid `addi`
  encoding via `assume(spec_valid)` on the model, and the core must decode
  whatever `addi` it is given. This mirrors how a real core presents the
  retired instruction on `rvfi_insn`.
- The run uses `mode bmc`, depth 20, engine `smtbmc boolector` — the fastest
  engine from the M0 smoke.

## How to run

```sh
source scripts/env.sh
sby -f build/m1/insn_addi_ch0.sby
```

Expected result: `DONE (PASS, rc=0)` in ~1 s.

The `.sby` in `build/m1/` reuses the existing riscv-formal harness and checker
files (read-only) and only adds our two SV files via `read_slang`. `build/m1/`
is scratch and gitignored.

The new SV files lint clean with `read_slang`:

```sh
yosys -Q -p "read_slang formal/rvfi_channel/smoke_core.sv formal/rvfi_channel/rvfi_wrapper.sv; check"
# -> 0 errors, 0 warnings
```

## RVFI conventions pinned here (for the real M1 core)

Mirroring the picorv32 reference binding, validated by `rvfi_insn_addi`:

- **`rvfi_valid`** — asserted for the cycle(s) an instruction retires. Here the
  core retires one instruction per cycle (out of reset).
- **`rvfi_order`** — zero-based, gap-free retired-instruction index (64-bit),
  incremented per retirement. Must never repeat.
- **`rvfi_insn`** — the full `ILEN`-bit retired instruction word (32 bits for
  RV32).
- **`rvfi_rs1_addr` / `rvfi_rs2_addr` / `rvfi_rd_addr`** — decoded register
  fields. `rvfi_rs1_rdata`/`rvfi_rs2_rdata` are the **pre-state** values; `x0`
  reads as 0. `rvfi_rd_wdata` is the **post-state** result and must be 0 when
  `rd == x0`.
- **`rvfi_pc_rdata`** — address of the retired instruction; **`rvfi_pc_wdata`**
  — address of the next instruction (pc + 4 for a non-branch such as `addi`).
- **`rvfi_mem_*`** — all tied to 0 for `addi` (no memory access). When a core
  does access memory it must drive `mem_addr` + `mem_rmask`/`mem_wmask` and
  the corresponding data per the RVFI spec (see
  `formal/riscv-formal/docs/source/rvfi.rst`).
- **`rvfi_trap`** — 0 here (legal instruction). **`rvfi_halt`** / **`rvfi_intr`**
  — 0 (never halting, not a trap-handler boundary).
- **`rvfi_mode`** — 0 (U-Mode, per `RISCV_FORMAL_UMODE`). **`rvfi_ixl`** — 1
  (XLEN=32).

### Wrapper port contract

`rvfi_wrapper` is the module the riscv-formal `rvfi_testbench` instantiates
(`.clock`, `.reset`, and the base RVFI channel). Because no optional
riscv-formal features (extamo / rollback / mem_fault / CSR / bus) are defined,
`RVFI_CONN` in the harness expands to exactly the 21 base channel signals, so
the wrapper declares exactly those ports explicitly (no dependence on
`rvfi_macros.vh`, which is what allows it to be read by `read_slang`). The
harness `reset` maps to the core's active-low async `rst_ni`.
