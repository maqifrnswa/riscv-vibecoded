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
- **`rvfi_rd_addr`** — decoded register field. `rvfi_rd_wdata` is the
  **post-state** result and must be 0 when `rd == x0`.
- **`rvfi_rd_addr` is 0 for ANY non-writing retirement** — not just
  branches/stores. The M1 core enforces this at the RVFI drive site
  (`rvfi_rd_addr = dec_rd_we ? dec_rd_addr : 0` in `rtl/core/rv32i_core.sv`):
  NOPs, ecall/ebreak, csr encodings, fence, and unsupported/illegal encodings
  all retire without a register write and must report `rd_addr == 0`. The
  riscv-formal `reg` check builds its shadow register file from
  `rvfi_rd_addr`/`rvfi_rd_wdata` of *every* retirement; a non-writing
  retirement that leaks its raw `insn[11:7]` field poisons the shadow with a
  spurious write of 0, and a later real read of that register spuriously
  fails. (The decoder also forces `rd_addr` to 0 for branches/stores, whose rd
  field is part of the immediate.)
- **`rvfi_pc_rdata`** — address of the retired instruction; **`rvfi_pc_wdata`**
  — address of the next instruction (pc + 4 for a non-branch such as `addi`).
- **`rvfi_mem_*`** — all tied to 0 for `addi` (no memory access). When a core
  does access memory it must drive `mem_addr` + `mem_rmask`/`mem_wmask` and
  the corresponding data per the RVFI spec (see
  `formal/riscv-formal/docs/source/rvfi.rst`).

### Convention gotchas (from M1 P2 test bring-up)

- **`rvfi_rs2_addr` (and `rs1_addr`) is the raw decoded field**, even for
  instructions whose rs fields overlap the immediate (e.g. `addi`'s rs2 field
  is `imm[4:0]`, `jal`'s rs1/rs2 fields are part of the J-immediate). The
  riscv-formal models read the regfile at that address, so the core must
  report the decoded field and the corresponding pre-state value — never
  force 0 for "not used".
- **`rvfi_mem_addr` is word-aligned** (`{addr[31:2], 2'b00}`); byte selection
  lives in `rvfi_mem_rmask`/`rvfi_mem_wmask`. `rvfi_mem_rdata` is the raw
  32-bit word read from memory (not the extracted/sign-extended byte), and
  `rvfi_mem_wdata` is the store data in its byte-lane position.
- `rvfi_rd_addr` is **0 for every non-writing retirement** (branches/stores,
  NOPs, ecall/ebreak, csr encodings, fence, illegal encodings — see the
  `rd_addr` rule above) and `rvfi_rd_wdata` must be 0 when `rd == x0`.
- **`rvfi_trap`** — 0 here (legal instruction). **`rvfi_halt`** / **`rvfi_intr`**
  — 0 (never halting, not a trap-handler boundary).
- **`rvfi_mode`** — 0 (U-Mode, per `RISCV_FORMAL_UMODE`). **`rvfi_ixl`** — 1
  (XLEN=32).

### C-word masking plan (M2) — M1 exit-criterion documentation

When the C extension lands (M2), compressed (16-bit) instructions must be
reported on the RVFI channel per the riscv-formal convention. This is the
predicted #1 source of "why does rv32imc prove fail" bugs (design.md §3.4):

- **`rvfi_insn`** carries the exact 16-bit word in `[15:0]`, with `[31:16]`
  zeroed. Do NOT sign-extend, do NOT re-encode to 32 bits.
- **`rvfi_pc_rdata`** is the 2-aligned address of the compressed instruction
  (the PC advances by 2, not 4).
- **`rvfi_pc_wdata`** is the address of the *next* instruction (pc+2 for a
  sequential C instruction).
- The riscv-formal checker slices `rvfi_insn[1:0] == 2'b11` to distinguish
  compressed from 32-bit retirements; `rvfi_insn[31:16]` must be clean zeros
  for C retirements so the 32-bit models do not see a spurious top half.
- Bring-up verification: run the full `rv32imc` prove suite and check the C
  instruction models (`insns/isa_rv32imc.txt`) individually; the masking
  convention is what the models compare against byte-for-byte.

The M1 RV32I core reports `rvfi_insn` = the full 32-bit word and `pc += 4`;
M2's fetch unit (16-bit granularity) and RVFI drive must add the masking.

### Wrapper port contract

`rvfi_wrapper` is the module the riscv-formal `rvfi_testbench` instantiates
(`.clock`, `.reset`, and the base RVFI channel). Because no optional
riscv-formal features (extamo / rollback / mem_fault / CSR / bus) are defined,
`RVFI_CONN` in the harness expands to exactly the 21 base channel signals, so
the wrapper declares exactly those ports explicitly (no dependence on
`rvfi_macros.vh`, which is what allows it to be read by `read_slang`). The
harness `reset` maps to the core's active-low async `rst_ni`.
