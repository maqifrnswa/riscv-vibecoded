# up5k-rv Design

Status: **LOCKED** (2026-08-11). This is the authoritative record of the
design. Change it deliberately and only through the change log at the end.

## 1. Product overview and goals

A small, formally-verified RISC-V core + SoC for the Lattice iCE40 UP5K FPGA,
built entirely with open-source tools.

- **Use case:** the core will run in a system that reads an ADC and does DSP on
  the same FPGA. The core must therefore be **small** — it leaves most of the
  5280-LC budget for the ADC + DSP logic — while still performing decently.
- **Performance bar (customer):** CoreMark/MHz × Fmax(MHz) > 20. Review
  re-derivation (2026-08-12): from the §3.1 schedule (CPI ≈ 4–5, IPC ≈
  0.2–0.25) and CoreMark ≈ 0.3–0.4 M instructions/iteration (cross-checked
  against known cores, ±30%), the honest pre-tuning projection is
  **~0.6–0.9 CM/MHz**; the M4 D5-tuning target is **≥ 1.0 CM/MHz** (≤ ~1.1
  realistic ceiling). At HFOSC 48 MHz that is ~29–48 vs the bar of 20 — it
  clears with ~1.5–2× margin, **not** the earlier 5–6× claim (the old
  2.0–2.5 CM/MHz estimate was wrong — see change log 2026-08-12). The
  32 MHz fallback (~19–22) no longer clears the bar and is demoted to a
  debug clock only.
- **Performance aspiration (long-term):** approach, then exceed, the Pareto
  frontier in `docs/pareto_frontier.csv` (CM/MHz vs LUT area, from a sibling
  optimized core — see §1.1). v1 does not need to reach it: get a working
  system first (M4 baseline measure), then iterate on it.
- **"Educational" means:** well organized, clearly documented, follow the
  lowRISC/Ibex coding style. Not a toy; a real, usable core.
- **Acceptance demo:** run CoreMark bare-metal with output written to a
  memory-mapped "fake UART" register (no real UART hardware needed).

### Target fabric facts (iCE40 UP5K)

| Resource | Value |
|---|---|
| Logic cells | 5280 (each = LUT4 + carry + DFF) |
| DSP blocks | 8 (UltraPlus DSP4, 16×16) |
| Block RAM | 120 Kbit dual-port (30 × 4 Kbit) |
| SPRAM | 1 Mbit / 128 KB single-port async-read (`SB_SPRAM256KA`), UltraPlus-only |
| PLLs | 2 |
| Oscillators | 10 kHz LPOSC, 48 MHz HFOSC (on-chip) |

Open-source support: Yosys (`synth_ice40`), nextpnr-ice40, icestorm — all
first-class for UP5K.

### 1.1 Pareto frontier reference (`docs/pareto_frontier.csv`)

`docs/pareto_frontier.csv` is the data of record: 15 Pareto-optimal configs
from a sibling optimized core's design-space sweep (the figure in
`docs/pareto_frontier.png`, if present, is just its plot). Columns: six
feature flags (REG_MISPREDICT_TOTAL, PARALLEL_EQUAL, USE_AGU, USE_BRANCH_AGU,
USE_BRANCH_PREDICTOR, USE_ZMMUL), LUTs, Fmax (MHz), CoreMark/MHz, and
Fmax × CoreMark/MHz (Y). The frontier is a **two-step curve**:

| Frontier region | Area (LUTs) | CM/MHz | Y (Fmax × CM/MHz) |
|---|---|---|---|
| Tier 1 (no ZMMUL) | 1632–1734 | 0.68–0.78 | 12.9–15.9 |
| gap (no points) | 1734–1843 | — | — |
| Tier 2 (ZMMUL) | 1843–1931 | 1.61–1.82 | 29.0–37.5 |

- **The Tier-2 step is the Zmmul multiply unit** — every Tier-2 config sets
  USE_ZMMUL=1; it costs ~200 LUTs (flag-identical pairs) and buys ~2.3×
  CM/MHz. (The figure's "discrete feature boundary" was exactly this.) The
  sibling's Fmax is 16.5–23.3 MHz — its own clock target, not ours — so
  **CM/MHz vs LUTs is the portable comparison**; Y is the figure's axis only.
- No frontier config uses USE_BRANCH_PREDICTOR (prediction never won in this
  sweep) — supporting D4. Within a tier, REG_MISPREDICT_TOTAL=1 trades
  CM/MHz for Fmax (Tier 2: 1.82 → 1.61 CM/MHz, 17.3 → 23.3 MHz).
- Frontier endpoints: min area 1632 LUTs (0.78 CM/MHz, Y 12.9); max CM/MHz
  1.82 at 1843 LUTs (Y 29.0); max Y 37.5 at 1931 LUTs (1.61 CM/MHz, config
  1,1,1,0,0,1).
- up5k-rv position: the ~1800–2400 LC core budget sits inside the gap/Tier 2.

**Aspiration ladder (start small, iterate on the working system):**

1. M4: working CoreMark system in sim; measure real CM/MHz; D5 tuning to the
   ≥ 1.0 CM/MHz target (already above Tier 1's 0.78, midway to Tier 2's
   1.61).
2. M5/M6: silicon measure; goal: approach the Tier-2 band (~1.6 CM/MHz at
   ~1850–1930 LUTs — the real M unit from M3 is exactly the feature that got
   the sibling there).
3. Stretch (M6+/M8): exceed the frontier — > 1.82 CM/MHz, or ≥ 1.6 CM/MHz at
   < 1843 LUTs — via microarch iteration (fetch buffer depth, branch
   handling, tighter overlap) and Fmax (PLL 60–80 MHz, which also lifts Y at
   our higher clock).

The frontier is the long-term target, not a v1 gate; each step re-runs the
formal suite and re-measures.

## 2. Decision summary

| # | Decision | Rationale |
|---|---|---|
| D1 | Multi-cycle, one instruction in flight, **overlapped next-fetch** | Fmax-friendly (no long pipeline paths) + formal tractability; overlap is the CoreMark lever |
| D2 | **Von Neumann, unified** address space, **single** memory port | IF and LSU phases never overlap → no arbitration; single-port SPRAM suffices; fetch/store coherence with formal memory model is automatic |
| D3 | 32-bit fetch buffer, 16-bit fetch granularity | C extension → ~2 instr/word, halves fetch traffic; #1 CPI win for a fetch-bound core |
| D4 | Branches resolved in EX; taken = refetch (+2 cyc); no prediction | Simple; CoreMark branches ~20–25%, amortized by the fetch buffer |
| D5 | Full forwarding EX/MEM→WB; load-use = 1 stall | Cheap, standard, formal-innocuous |
| D6 | **MUL: 4-bit/cycle shift-add, fixed 8 cycles. DIV: non-restoring, fixed 33 cycles** (no early termination) | Deterministic latency → fixed formal depth, trivial properties; div rare in CoreMark |
| D7 | Minimal CSRs: mcycle/mcycleh, mstatus, mtvec, mepc, mcause, mtval (+ rvfi_csr reporting) | CoreMark timing via `rdcycle`; misaligned-access traps (mcause 4/6) exercised by riscv-formal |
| D8 | **No interrupts in v1** (polling peripherals); mtimer interrupt in v2 | Removes the hardest formal dimension (interrupt injection); CoreMark doesn't need them |
| D9 | Misaligned load/store → **machine trap**, not hardware split | Spec-compliant, halves LSU logic, keeps formal bounded |
| D10 | Core↔SoC bus: minimal single-master **"SBus"** (valid/ready, byte-enables, no pipelining) | One master, ≤1 outstanding request; ~200 lines; formal-friendly; wrap with an adapter later if a peripheral demands it |
| D11 | Memory map: 8 KB BRAM ROM @0x0, 32 KB SPRAM @0x10000, MMIO @0x2000_0000+; unmapped → read-0/write-ignore | ROM too small for CoreMark image; SPRAM has no reliable bitstream init → UART loader is the robust boot path |
| D12 | Clock: **HFOSC 48 MHz direct**; PLL only as stretch | Removes PLL config risk; bar met at 48 MHz. **Amended (2026-08-12 review):** the 32 MHz fallback no longer clears the bar under the corrected §1 estimate, and the M5/M6 real-UART bootloader is baud-rate-sensitive — HFOSC ±5% exceeds UART tolerance at 115200. The UPduino 3.1 has a 12 MHz on-board oscillator: plan is 12 MHz XO + PLL → 48 MHz from M5. HFOSC remains fine for M4 (sim-only) and early bring-up |
| D13 | Formal: riscv-formal `rv32imc` (prove/live) with ALTOPS; M-extension arithmetic closed by golden DV + bounded-width formal + determinism property | ALTOPS does **not** bit-verify mul/div results — the gap is explicitly owned (§5.2) |
| D14 | **SystemVerilog throughout**, consumed via Yosys **`read_slang`** (built-in since Yosys 0.67) for RTL, RVFI harness, *and* sby scripts. Interfaces/modports/structs/packages allowed. | sv-elab/slang frontend gives near-complete synthesizable SV; riscv-formal generated files stay on `read_verilog -sv` — mixing is supported. Toolchain must be pinned ≥ 0.67 |
| D15 | DV: Verilator (2-state) + cocotb; iverilog 4-state smoke for reset/X; spike cross-check of CoreMark binary | 2-state blind spots covered by formal + 4-state smoke |
| D16 | Coding style: **lowRISC/Ibex** style (see docs/standards.md) | Consistency + reviewability |
| D17 | Board: **UPduino 3.1**; benchmark: **our core only** (no VexRiscv comparison); deliverable: full SoC demo | Customer decisions |
| D18 | **ALTOPS M-ops in the core until M3**: the 8 M instructions implement `(rs1±rs2)^mask` combinationally | The rv32imc models assert `rvfi_rd_wdata` byte-exact (ALTOPS is a fake-op contract, not "determinism only"); real MUL/DIV (D6) land in M3 with **core-side** ALTOPS substitution (a `FormalAltops` parameter inside the M unit, the picorv32 pattern — `RISCV_FORMAL_ALTOPS` in `third_party/picorv32.v`): the real 8/33-cycle sequencer stays in the proof, only the arithmetic result is substituted. Wrapper-side compensation is rejected (2026-08-12 review): the core would write real results to the regfile while the channel reports fake ones, breaking the `reg` check's shadow-regfile consistency and making the M checks vacuous |
| D19 | **mcycle/mcycleh are read-only** (spec-legal); csrw writes are reported on the rvfi channel but not applied | The riscv-formal csrc_upcnt/inc counter checks require a strictly monotonic counter — their write-tracking (`csr_written`) is cleared by any intervening retirement, so a writable counter cannot satisfy them; `rdcycle` (M4 CoreMark timing) only reads |

## 3. Microarchitecture

### 3.1 Phase structure

Six phases per instruction — `IF1 → IF2 → ID → EX → MEM → WB` — with the
**next instruction's fetch overlapping the current instruction's EX/MEM/WB**
(one instruction in flight ⇒ IF and LSU can never contend, D2).

- **IF1**: drive 32-bit word address `{PC[31:2], 2'b0}` to memory.
- **IF2**: capture word into the 32-bit **instruction buffer**; select the
  16-bit half by `PC[1]` (C-extension granularity).
- **ID**: decode; compute sequential next-PC (`PC+2`/`PC+4`); read register file.
- **EX**: ALU; branch compare/target; multi-cycle MUL (8) / DIV (33) hold EX.
- **MEM**: LSU address cycle (loads/stores only).
- **WB**: writeback, CSR update, **retire** (RVFI asserted here).

Overlap schedule (as implemented, M1): the execute pipeline is
`ID → EX → (MEM) → WB → IDLE → ID`, i.e. WB always retires into one IDLE
cycle before the next ID. This makes the schedule **hazard-free by
construction**: ID reads the register file a full cycle after the previous
instruction's WB commit edge, so there is no forwarding and no load-use stall
for correctness (CPI ≈ 4 for ALU/branch, ≈ 5 for load/store). The next
instruction's fetch overlaps the current instruction's EX/MEM/WB: `F_REQ(i+1)`
is issued during `EX(i)` for ALU/branch instructions (at the ID→EX edge) and
during `WB(i)` for loads/stores (at the MEM→WB edge); the fetched word is
accepted at the IDLE→ID edge. Taken branch/jal/jalr: the sequential successor
is fetched speculatively; a taken branch redirects the fetch unit at the
EX→WB edge (target = `(rs1+imm)&~1` for jalr, else `pc+imm`), squashing the
pending word — with a combinational memory slave the taken path costs ~0 extra
cycles. `mret`/trap redirect: same redirect path (M2). D5 forwarding/overlap
tuning is deferred to M4 (CPI target there).

### 3.2 Datapath and hazards

- One 32-bit ALU incl. funnel shifter (1 cycle). Regfile 2R1W, 32×32 in **LCs**
  (distributed — keeps BRAM for ROM).
- **No forwarding muxes and no load-use stall in the M1 schedule** — the
  IDLE cycle between WB and ID (see §3.1) makes RAW hazards structurally
  impossible. D5's full bypass MEM/WB→EX and tighter overlap are the M4
  tuning lever.
- MUL/DIV use shadow accumulators (no regfile port pressure).
  - MUL: 4-bit/cycle shift-add, **fixed 8 cycles**, LUT-based (see risk R4 —
    do *not* depend on DSP4 inference for the core multiplier).
  - DIV: non-restoring, **fixed 33 cycles**.
  - Both parameterizable out for the smallest config (`M` parameter, default on).

### 3.3 Control flow, CSRs, traps

**Control flow (M1, unchanged):** branches/jumps resolve in EX; a taken branch
redirects the fetch unit at the EX→WB edge (≈0 extra cycles with the
combinational slave, D4). No BTB/BHT in v1.

**M2 cheat-sheet** — ratified unprivileged/privileged specs 20250508 (vendored
in `docs/specs/`, CC-BY 4.0 NOTICE). The riscv-formal models are the formal
referee; the spec text is the architectural cross-check.

CSR table (D7; M-mode only, no delegation):

| CSR | Addr | M2 semantics |
|---|---|---|
| mstatus | 0x300 | MIE, MPIE, MPP (the bits we implement) |
| mtvec | 0x305 | direct mode (MODE=0): trap PC = `mtvec & ~3`; reset 0 |
| mepc | 0x341 | PC of the trapping instruction |
| mcause | 0x342 | exception code, bit31 (interrupt) = 0 in v1 (D8) |
| mtval | 0x343 | faulting address (misaligned load/store), else 0 |
| mcycle | 0xB00 | free-running cycle counter (`rdcycle`; CoreMark clock) |
| mcycleh | 0xB80 | high 32 bits of mcycle |

mcause codes: 0 instruction-address-misaligned, 2 illegal-instruction,
3 breakpoint (ebreak), 4 load-address-misaligned, 6 store-address-misaligned,
11 environment-call-from-M-mode (ecall).

Trap entry (M-mode): `mepc ← PC` of the trapping instruction; `mtval ←` faulting
address for misaligned load/store, else 0 (ecall/ebreak/illegal → mtval=0);
`mcause ← code`; `mstatus ← {MPIE=MIE, MIE=0, MPP=11}`; `PC ← mtvec & ~3`.
Trap exit (`mret`): `mstatus ← {MIE=MPIE, MPIE=1, MPP=11}`; `PC ← mepc`.
In this M-mode-only core **MPP is WARL=M** (spec: without U-mode, xPP must
hold M) — the M2 RTL sets MPP←00 on mret and makes MPP writable
(`rtl/core/csr_file.sv:95,118`); the one-line fix is scheduled in M3.
`wfi` = NOP; `fence`/`fence.i` = NOP (spec-legal, no I-cache).

**M2 design decisions (Gate-1 reviewed):**

- **Model-matched trap conditions.** With C enabled (ialign16=1): lh/lhu/sh trap
  iff effective address bit0; lw/sw trap iff bits[1:0]; lb/lbu/sb never trap
  (`RISCV_FORMAL_ALIGNED_MEM` semantics); branches and jal trap iff target PC
  odd; jalr never traps (target bit0 masked); `c.beqz`/`c.bnez` trap iff PC
  odd; other C instructions fetched at an odd PC execute without trapping;
  `c.j`/`c.jal` have no target-alignment trap. **32-bit instructions at an odd
  PC (reachable via `csrrw mepc` + `mret`) also execute without trapping** —
  there is no blanket odd-PC fetch trap; only c.beqz/c.bnez, branches, and jal
  trap on odd PC/target. The M1 alignment `[assume]` block in
  `formal/up5k_rv/checks.cfg` is deleted; the unaligned cases become
  `spec_trap=1` checks.
- **ALTOPS M-ops (D18):** the 8 M instructions implement the ALTOPS fake ops
  `(rs1±rs2)^mask` combinationally — the rv32imc models assert `rvfi_rd_wdata`
  byte-exact. Masks truncate to `[31:0]` (XLEN=32). Real fixed-latency MUL/DIV
  (D6) land in M3 with **core-side** ALTOPS substitution (see D18, amended
  2026-08-12).
- **c_ebreak (0x9002):** matches **no** insn model — the `c_add` model requires
  rs2≠0 (`insn_c_add.v:44`; 0x9002 has rs2=00000) and `c_jalr` requires rs1≠0
  (0x9002 has rs1=00000). The core traps on c.ebreak (mcause=3, spec-compliant)
  with **no scoping assumption needed** (an early draft of this decision claimed
  a c_add overlap — incorrect: the encoding fails the model's rs2 guard). The
  32-bit ecall/ebreak (SYSTEM opcode) also match no insn model and trap freely.
- **Coverage note:** trap-entry CSR semantics (mepc/mcause/mtval/mstatus
  values) are NOT pinned by riscv-formal (no ecall/ebreak/mret models) —
  directed tests carry them. Formal coverage of traps is `spec_trap ==
  rvfi_trap` + the pc chain.

### 3.4 RVFI channel (formal contract)

Full RVFI: `order, insn, pc, rs1/rs2/rd (addr+data), mem (addr/rmask/wmask/
rdata/wdata), csr (addr/wdata/rdata), trap, halt, intr, mode, ixl`.

- **C instructions**: `rvfi_insn` carries the exact 16-bit word in `[15:0]`
  with `[31:16]` clean zeros; `rvfi_pc_rdata` is the 2-aligned C address and
  `rvfi_pc_wdata` advances +2 for C, +4 for 32-bit. (Masking plan pinned in
  M1; implemented in M2.)
- `rvfi_valid` low during reset and held until first retire; `rvfi_order`
  increments exactly 1 per retire.
- `rvfi_intr` tied low in v1 (D8); `rvfi_halt` deasserted (ebreak traps and
  continues). `rvfi_mode` = 3 (M-mode) from M2 — the [csrs] checks assert a
  trap on M-CSR access when mode<3; the M1 `RISCV_FORMAL_UMODE` define is
  dropped from checks.cfg.
- CSR channel (M2): `rvfi_csr_<name>_{rmask,wmask,rdata,wdata}` for the D7
  set — mcycle/mcycleh reported as 64-bit ports (riscv-formal convention);
  match the counter model exactly during integration (upcnt: strictly
  increasing, no writes; csrw: full rmask, writes to one half must not alter
  the other). `rvfi_trap` asserted for the trapping retirement; the trap's
  redirect (PC → mtvec) chains through pc_wdata/pc_rdata like a branch.

### 3.5 Resource and timing budget

- Core: **~1,800–2,400 LC** (PicoRV32-class + CSR/trap/RVFI + fetch buffer).
  SoC total **~3,000–3,500 LC of 5,280** — comfortable for DSP room.
- BRAM: 8 KB ROM = 16 blocks of 30. SPRAM: 8192×32 (32 KB), single-port,
  registered read (matches IF1/IF2 and MEM/WB two-cycle accesses), byte-enables
  for 4 lanes, **no reset/init — contents undefined at power-up** (loader owns
  this; see §4.3).
- Critical paths: SPRAM read→buffer→decode; ALU→WB; divider adder. Mitigations:
  register WB inputs, shallow decode, 32 MHz fallback divider (bar still met).

## 4. Memory interface and SoC

### 4.1 SBus (D10)

Single master port:

```
req_valid, req_we, req_addr[31:0], req_be[3:0], req_wdata[31:0]
  → rsp_valid, rsp_rdata[31:0]
```

Slaves ack in a **bounded cycle count (1–2)** — required for core liveness in
formal `live` mode. This port is the core's only memory interface: in formal
its slave is the shared checker memory model; in SoC it is the address decoder.

### 4.2 Memory map (D11)

```
0x0000_0000 – 0x0000_1FFF   ROM    (BRAM, 8 KB)   reset vector + bootloader
0x0001_0000 – 0x0001_7FFF   SRAM   (SPRAM, 32 KB) code + data + stack
0x2000_0000                 UART   (fake: write-only TX reg + status; 16-deep FIFO)
0x2000_1000                 TIMER  (64-bit mtime + compare; demos; CoreMark uses rdcycle)
0x2000_2000                 GPIO   (in/out/oe)
0x2000_3000                 SPI    (v2 stretch: flash boot)
unmapped → read 0 / ignore write
```

Power-of-2 boundaries keep the decoder a few wide-NORs. Decoder correctness
(exactly-one-slave per address, unmapped behavior) is a cheap sby prove (§5.4).

### 4.3 Boot flow

ROM bootloader → UART download protocol (magic, addr, len, data, CRC16) →
image written to SPRAM → jump `0x0001_0000`. Host tool `tools/uart_loader.py`
sends the CoreMark ELF converted to flat binary. Rationale: SPRAM has no
reliable bitstream init, and 8 KB ROM cannot hold a CoreMark image + data.
Also makes iteration cheap (no re-synthesis per test).

### 4.4 Clocking / reset

HFOSC 48 MHz direct (D12). Synchronous reset via 2-flop synchronizer +
external button; internal reset held ≥ 8 cycles (formal reset depth).

## 5. Formal verification strategy

### 5.1 Core: riscv-formal `rv32imc`

- Own binding (RVFI channel + wrapper + shared memory model), modeled on the
  official picorv32 binding; riscv-formal pinned as a **submodule**.
- **M0 de-risk:** run the *stock* picorv32 binding through sby in CI before a
  line of our RTL exists — proves the formal toolchain first.
- Config: `spec = rv32imc`; ALTOPS on (default); intr channel constrained low.
- **Depths:** `insn 48` (covers 2 fetch + 1 ID + 33 DIV + 1 WB + margin),
  `reg 8 17`, `pc_fwd 8 48`, `pc_bwd 8 21`, `cover 1 15`, `liveness 1 10 30`,
  `csrw 48`, `csrc_* 1 48` (the "(reset, exec, trigger)" tuple of earlier
  drafts is not this binding's config). **M3 re-tune required:** the fixed
  33-cycle DIV stretches the retire-to-retire gap to ~36–38 cycles, breaking
  the 20-cycle liveness window (`liveness 1 10 30`) — retune to
  `liveness 1 10 50` before the real M units land. Same for the bmc smoke
  subset: each check fires at one exact cycle (48), so `insn_div` needs a
  reachable check cycle or it is vacuously green (the M0 R12 lesson).
- Modes: `prove` (bmc + induction; engine `smtbmc yices` — z3 rejected at M1
  P1a, and `abc pdr` never converged here: M0 timeout at 1800 s, M1
  oscillation) for I/C coverage; `live` with fairness on reset-deassert (no
  deadlock; at M2 proven as bmc-mode bounded progress — see the roadmap M2
  honest statement); `cover` for reset→first-retire sanity.
- Memory model: the M1/M2 wrapper exposes **free-input read data** — it has
  no RAM array, so today the insn checks pin opcode/address/rmask lanes but
  **not load data**, and no fetch/execute-coherence or execute-after-store
  property is checked (an earlier draft overclaimed this). Von Neumann
  unification (D2) makes the planned shared-RAM wrapper trivially sound: when
  the wrapper's RAM is the memory the core fetches and stores to, stores
  update the same array the checker reads. Closing this gap (shared-RAM
  wrapper / dmem checks) is an explicit M5 task.

### 5.2 Closing the ALTOPS gap (M extension) — explicit ownership

riscv-formal with ALTOPS verifies mul/div *encoding, register semantics, and
determinism* but **not the arithmetic result**. Three layers close it:

1. **Golden-model DV (primary truth):** cocotb + Verilator, thousands of
   random + directed operand pairs; MUL/MULH*/MULHU/MULSU and DIV/DIVU/REM/
   REMU compared against an independent Python reference (different algorithm
   than RTL, e.g. long division vs non-restoring). Same tests compiled as
   bare-metal C (compiler-emitted mul/div) and cross-checked against **spike**.
2. **Bounded-width formal:** separate sby runs with operands truncated to
   8/16 bits against a *genuinely* different reference — the combinational
   `*`/`%` operators (or a per-bit restoring divider), NOT shift-add at a
   different radix, so a shared sign-extension bug can't hide in both.
   **bmc-first with `smtbmc`** (unroll the fixed 33-cycle sequencer, depth
   ≈ 38; a bit-blasted 16-bit divide is comfortably in boolector/yices
   range): `abc pdr` has never converged in this repo (M0 timeout 1800 s,
   M1 oscillation) and is demoted to a stretch engine. 16-bit is the primary
   width (8-bit misses lane-dependent wiring). Full-width div proof
   explicitly out of scope.
3. **Determinism:** with core-side ALTOPS substitution (D18 amended) the real
   sequencer stays in the proof, and determinism of the real result is
   implied by the (2) equivalence proof over the unrolled sequencer
   (result == f(rs1, rs2)). A separate wrapper-side "determinism property"
   was dropped in the 2026-08-12 review as redundant/vacuous.

**Honest formal statement for the report:** "ISA-level proof for I/C + trap/CSR
semantics; M extension proven for opcode/operand semantics formally, arithmetic
closed by (1)+(2)."

### 5.3 What formal can't see (covered by DV)

SoC peripherals, UART loader round-trip, timer rollover, GPIO — plus
**end-to-end CoreMark in simulation with score/hash cross-checked against
spike** on the identical binary. (Bonus: RVFI trace diff against spike.)

### 5.4 SoC-level formal (light, cheap)

- Decoder: exactly-one-slave mapping, unmapped read-0/write-ignore
  (combinational sby prove).
- Peripherals: bounded-response (ack within N cycles) for liveness; small FSM
  proves for UART TX and timer.
- Not attempted: full-chip riscv-formal — core-only is the standard scope.

## 6. Demo: CoreMark on the fake UART

- CoreMark port: copy `barebones/` to `sw/coremark/`; stub `ee_printf` to write
  to the fake-UART MMIO location (write-only register); `ee_start/ee_stop_time`
  via `rdcycle`; `MAIN_HAS_NOARGC=1`, `TOTAL_DATA_SIZE=2000`.
- Build: `-O2 -march=rv32imc -mabi=ilp32`, newlib, linker script per memory map
  (see docs/standards.md → build flags section; M4 pins the exact recipe).
- A valid run needs ≥ 10 s and a passing validation run (CRC seeds
  `0,0,0x66` and `0x3415,0x3415,0x66`).
- Score reported as `CoreMark 1.0 : N / ...`; **CoreMark/MHz = N ÷ clock MHz.**
- Capture: in simulation, the testbench reads the fake-UART register; on
  hardware (M6), the loader console shows the MMIO writes. A real UART can be
  added later without touching the core.

## 7. Toolchain and CI

- **Language frontend:** Yosys `read_slang` (sv-elab/slang, **built-in since
  Yosys ≥ 0.67**) for our SV — RTL, RVFI harness, and in sby `[script]`.
  riscv-formal's generated checker files stay on `read_verilog -sv`; mixing is
  supported. Gotchas: all modules must be defined (provide blackboxes for iCE40
  primitives before elaboration); file ordering matters; `read_slang` runs
  `proc` internally.
- **Toolchain:** OSS CAD Suite (yosys/nextpnr/icestorm/verilator/iverilog/sby),
  pinned versions in CI; prebuilt riscv-gnu-toolchain (newlib) — never built
  from source in CI.
- **CI gates:** lint (`yosys read_slang` + `verilator --lint-only`), per-PR
  shallow bmc smoke + CoreMark sim, nightly full formal suite with timeouts.
- **Synthesis:** `synth_ice40` → nextpnr-ice40 → `icetime` Fmax report → bitstream.

## 8. Risks

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Fmax < 48 MHz (SPRAM→decode, WB paths) | M | H | Registered WB; shallow decode; 32 MHz divider demoted to a debug clock (2026-08-12 review — under the corrected §1 estimate it no longer clears the bar); PLL to 60–80 MHz is the real margin lever |
| R2 | Formal div-depth blowup (exec=48, 33-cycle div) | M | M | I/C-only prove first; M via bmc + operand-constrained proofs; determinism property is cheap; arithmetic truth lives in golden DV |
| R3 | C-ext RVFI convention / decode bugs | M | H | Follow reference binding exactly; directed tests per C opcode; riscv-formal rv32imc enumerates all C encodings |
| R4 | SPRAM/DSP4 quirks (registered read, no init, DSP inference version-dependent) | M | M | Core multiplier is LUT shift-add, not DSP4; document + early hardware test (M6); loader owns undefined SPRAM contents |
| R5 | CoreMark port pitfalls (ee_printf, rdcycle, flags) | L | M | Known-good recipe; score sanity vs spike on same binary |
| R6 | SV-subset / tool drift (read_slang vs Verilator vs iverilog) | M | M | CI lint gates on both Yosys and Verilator; avoid struct/array literals in formally-verified core RTL |
| R7 | Verilator 2-state hiding X bugs | M | L | Formal covers; iverilog 4-state reset smoke |
| R8 | Feature creep (interrupts/SPI before core stable) | M | M | Milestone gates: formal green before any peripheral beyond v1 |
| R9 | Toolchain availability in CI | L | M | Pinned prebuilt; documented fallback |
| R10 | Formal engines unproven beyond `smtbmc boolector` (yices/z3, `abc pdr` needed for M1 prove/M3 div proofs) | M | M | M1's first formal task: one pdr-engine run on the stock binding; verify `verilator --cc` compile path |
| R11 | `read_slang`↔`read_verilog` mixing in sby unproven (M0 stock binding used `read -sv` only; D14 claim not yet exercised) | M | H | M1 first task after pdr check: SV RVFI wrapper + trivial core through sby; keep wrapper conservative (plain ports/`logic`, no interfaces/struct literals in formally-verified path) |
| R12 | bmc depth-20 vacuity (picorv32 MUL latency > 20 cyc — mul/mulh green is likely vacuous) | M | M | Our checks.cfg must override generated defaults: RESET_CYCLES 1→8, insn depth 20→48 (design §5.1); vacuity closed by prove/live/cover at M2/M3 |
| R13 | Unpinned picorv32.v fetch (was moving-target) | — | — | **MITIGATED at M0:** vendored `third_party/picorv32.v` pinned to commit a473fc8fca393771d83b0ffcf0b14db3393339d8; recorded in MANIFEST.md |
| R14 | Hardcoded toolchain path (single-host scaffold) | — | — | **MITIGATED at M0:** `UP5K_TOOLS_ROOT` env override in scripts/env.sh; recorded in MANIFEST.md |
| R15 | riscv tool naming drift: xPack ships `riscv-none-elf-*`, common recipes use `riscv32-unknown-elf-*` | L | M | `make env` checks `riscv-none-elf-gcc` first; naming recorded in MANIFEST.md/standards; will bite at M4 (CoreMark) otherwise |

## 9. Open items / assumptions

- None blocking. Assumptions: SPRAM contents undefined at power-up (loader
  handles); HFOSC 48 MHz is fine for the sim-only M4 fake UART (memory-mapped),
  but the M5/M6 real-UART loader is baud-rate-sensitive → clock path becomes
  12 MHz XO + PLL from M5 (D12 amended); reset button on UPduino 3.1 used for
  reset.
- Confirm UPduino 3.1 variant specifics (e.g., 5K vs 1K part) and the
  programming path (SPI flash vs FTDI-SRAM) at M6 bring-up.

## Change log

- 2026-08-12 — **M0–M2 design/workplan review** (oracle + explorer + observer;
  fixes folded into this doc): (1) **performance estimate corrected** —
  2.0–2.5 CM/MHz was incompatible with the §3.1 CPI≈4–5 schedule; honest
  projection ~0.6–0.9 pre-tuning, ≥ 1.0 CM/MHz M4 target (≤ ~1.1 ceiling);
  bar still clears at 48 MHz (~1.5–2×) but the 32 MHz fallback no longer
  does (R1 mitigation amended). (2) **Pareto frontier aspiration added**
  (§1.1, data of record `docs/pareto_frontier.csv` — 15 Pareto-optimal
  configs, CM/MHz vs LUTs): v1 starts small and iterates toward Tier 2
  (CM/MHz 1.61–1.82 at 1843–1931 LUTs); stretch exceeds the 1.82 CM/MHz /
  Y 37.5 frontier max. The Tier-2 step is the sibling's Zmmul unit — the
  M unit is the big CM/MHz lever. (3) **D18 amended** — wrapper-side ALTOPS
  compensation rejected (breaks `reg`-check consistency; makes the M checks
  vacuous); core-side `FormalAltops` substitution in the M unit (picorv32
  pattern, `picorv32.v:2417/2497/2516`) instead. (4) **M3 formal re-tune
  recorded** — the fixed 33-cycle DIV stretches the retire gap to ~36–38
  cycles, breaking the 20-cycle liveness window: retune `liveness 1 10 50`;
  bmc-smoke `insn_div` exact-cycle vacuity to be re-checked. (5) **§5.2
  revised** — bounded-width proofs bmc-first with `smtbmc` (abc pdr never
  converged in this repo); reference must be genuinely different
  (combinational `*`/`%`, not shift-add at another radix); determinism
  property folded into the equivalence proof. (6) **§5.1 fixed** — wrapper
  is free-input read-data (execute-after-store overclaim corrected); engine
  list corrected; depth config spelled out. (7) **mstatus.MPP WARL=M** —
  M-mode-only core must hold MPP=11; M2 RTL writes 00 on mret
  (`csr_file.sv:118`) — fix scheduled M3. (8) **D12 amended** — the M5/M6
  real-UART loader is baud-rate-sensitive; HFOSC ±5% fails at 115200 →
  12 MHz XO + PLL from M5. (9) M5 gap items scheduled (shared-RAM wrapper,
  fetch_unit stale-response suppression, real UART peripheral); spike +
  cocotb pinned at M3; CI wording vs no-CI reality noted in roadmap M0.
- 2026-08-12 — **M2 DONE** (deepwork P1–P3; oracle gates 1+2 APPROVE): C
  extension, traps, CSRs. `rv32imc` prove green (78/78 checks, `make
  formal-m2`); liveness green in bmc mode (reference-binding-equivalent
  bounded progress — honest statement in roadmap M2 handoff). RTL: C-ext
  decode/fetch (PC[1] halfword select, seq_pc +2/+4, decoder-driven regfile
  read at ID), model-matched traps (mcause 0/2/3/4/6/11, LSU suppression),
  mret, D7 CSR set, csrrw/csrrs/csrrc ±i, rvfi_csr channel (mcycle 64-bit,
  **mcycle/mcycleh read-only — D19**). Three bugs found by the formal suite
  and fixed: (1) ALTOPS masks used the HIGH 32 bits of the models' 64-bit
  constants — the model XORs at 64-bit width then truncates, so the effective
  RV32 mask is the LOW 32 bits; (2) reserved SYSTEM funct3=100 executed as an
  invisible CSR write (the csr checks require insn[13:12]!=0) — now illegal;
  (3) writable mcycle broke the counter checks — read-only (D19).
- 2026-08-12 — M2 P0 (deepwork): spec gate + M2 design. Ratified spec pin
  updated to **20250508** (unpriv + priv; both re-ratified since the M1 note's
  20240411/20211203) and vendored to `docs/specs/` with CC-BY 4.0 NOTICE.
  §3.3 expanded into the M2 cheat-sheet (CSR table D7, mcause codes, trap
  entry/exit sequence). Design decisions recorded: model-matched trap
  conditions (M1 alignment assumes deleted; unaligned cases become
  spec_trap=1 checks), ALTOPS M-ops in core until M3 (D18), c_ebreak/0x9002
  c_add-model overlap scoped by a documented `[assume]`. Recon finding that
  corrects the §5.2 framing: ALTOPS asserts `rvfi_rd_wdata` byte-exact (the
  models implement fake ops the core must reproduce), not merely determinism.
- 2026-08-12 — M1 P3: **rv32i formal prove green** (deepwork oracle gate:
  APPROVE WITH FIXES). The M1 core is proven against the riscv-formal RV32I
  model suite: 36 instruction checks + pc_fwd by k-induction (smtbmc yices,
  RESET_CYCLES 8, insn depth 48), reg/pc_bwd by bmc (their forward-looking
  checker state is not induction-friendly), cover non-vacuous. §3.1/3.2 body
  updated to the implemented hazard-free schedule (IDLE between WB and ID, no
  forwarding; D5 deferred to M4 — see deepwork file). Formal wrapper +
  memory model at formal/up5k_rv/; runner `make formal-m1` / `formal-m1-smoke`.
  M1 scoping assumptions (checks.cfg [assume]): retired PCs, load/store
  addresses, and control-flow targets 4-aligned — the trap-less M1 core cannot
  produce the models' spec_trap=1 for unaligned accesses; D9 traps land in M2
  and the assumptions drop. Known formal gap (reference-consistent, recorded
  per §5.1): load *data* path is not pinned by the insn checks (spec extracts
  from the core's own rvfi_mem_rdata) — covered by DV (tb_lsu/tb_core); a
  shared-RAM wrapper or dmem checks are M2/M5. Two core bugs found by the
  suite and fixed: branch compare used the immediate instead of rs2 (decoder
  alu_b_sel), and rvfi_rd_addr leaked the raw rd field on non-writing
  retirements (poisoned the reg-check shadow). Also fixed: reserved OP
  encodings with funct7=0100000 and funct3∉{000,101} now decode as NOP.
- 2026-08-12 — M1 P2: hazard-free phase schedule implemented (deepwork
  refinement, pending P4 oracle approval). ID→EX→(MEM)→WB with one IDLE cycle
  inserted between WB and ID, so the ID-stage register read happens a full
  cycle after the previous instruction's WB commit edge — RAW hazards are
  structurally impossible. Overlapped next-fetch kept: F_REQ during EX for
  ALU/branch instructions, during WB for loads/stores. Branches/jumps fetch
  the sequential successor speculatively and redirect the fetch unit at the
  EX→WB edge when taken (target = (rs1+imm)&~1 for jalr, else pc+imm).
  Forwarding and the load-use stall (D5) are deferred to M4 tuning. RVFI
  memory reporting: word-aligned mem_addr with byte enables in rmask/wmask,
  raw word in mem_rdata (matches the riscv-formal memory model). Core memory
  slave must respond combinationally in M1 (formal path); registered-latency
  SoC slaves are an M5 adapter concern (fetch_unit notes stale-response
  suppression).
- 2026-08-11 — Initial locked design. D1–D17 as above. Supersedes draft notes.
  Key revisions during interview: M extension parameterized (not fixed),
  misaligned→trap (not split), full SoC demo as first deliverable, SV via
  read_slang for RTL + RVFI harness + sby (after verifying the sv-elab/slang
  frontend, built-in since Yosys 0.67), lowRISC/Ibex style, UPduino 3.1,
  polling-only v1, no VexRiscv benchmark.
- 2026-08-11 — M0 complete (see roadmap). Toolchains relocated to
  /home/agent/up5k-tools (repo's Windows mount blocks symlinks; fresh
  extraction on native FS, 0 broken symlinks). Pins in MANIFEST.md.
  Added R10–R15 (M0 review findings: engine coverage, read_slang-in-sby,
  bmc-depth vacuity, picorv32 pin, portability, tool naming).
