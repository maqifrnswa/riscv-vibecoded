# up5k-rv Design

Status: **LOCKED** (2026-08-11). This is the authoritative record of the
design. Change it deliberately and only through the change log at the end.

## 1. Product overview and goals

A small, formally-verified RISC-V core + SoC for the Lattice iCE40 UP5K FPGA,
built entirely with open-source tools.

- **Use case:** the core will run in a system that reads an ADC and does DSP on
  the same FPGA. The core must therefore be **small** — it leaves most of the
  5280-LC budget for the ADC + DSP logic — while still performing decently.
- **Performance bar (customer):** CoreMark/MHz × Fmax(MHz) > 20. Estimated
  outcome: ~2.0–2.5 CM/MHz × 48 MHz (HFOSC direct) = **96–120**, i.e. 5–6×
  margin. At stretch Fmax (60–80 MHz via PLL) the margin is larger.
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
| D12 | Clock: **HFOSC 48 MHz direct**; PLL only as stretch | Removes PLL config risk; bar met at 48 MHz; fallback divider to 32 MHz still clears the bar |
| D13 | Formal: riscv-formal `rv32imc` (prove/live) with ALTOPS; M-extension arithmetic closed by golden DV + bounded-width formal + determinism property | ALTOPS does **not** bit-verify mul/div results — the gap is explicitly owned (§5.2) |
| D14 | **SystemVerilog throughout**, consumed via Yosys **`read_slang`** (built-in since Yosys 0.67) for RTL, RVFI harness, *and* sby scripts. Interfaces/modports/structs/packages allowed. | sv-elab/slang frontend gives near-complete synthesizable SV; riscv-formal generated files stay on `read_verilog -sv` — mixing is supported. Toolchain must be pinned ≥ 0.67 |
| D15 | DV: Verilator (2-state) + cocotb; iverilog 4-state smoke for reset/X; spike cross-check of CoreMark binary | 2-state blind spots covered by formal + 4-state smoke |
| D16 | Coding style: **lowRISC/Ibex** style (see docs/standards.md) | Consistency + reviewability |
| D17 | Board: **UPduino 3.1**; benchmark: **our core only** (no VexRiscv comparison); deliverable: full SoC demo | Customer decisions |

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

Overlap schedule: for a sequential ALU op, `IF1(i+1)` runs during `EX(i)`,
`IF2(i+1)` during `MEM(i)` (free — ALU ops skip MEM). Loads occupy MEM+WB so
the next fetch shifts one slot (load-use ≈ +1 cycle). Taken branch: buffer
squashed, refetch → +2 cycles. `mret`/trap redirect: same +2.

### 3.2 Datapath and hazards

- One 32-bit ALU incl. funnel shifter (1 cycle). Regfile 2R1W, 32×32 in **LCs**
  (distributed — keeps BRAM for ROM).
- Full bypass MEM/WB→EX operand muxes; load-use stall only.
- MUL/DIV use shadow accumulators (no regfile port pressure).
  - MUL: 4-bit/cycle shift-add, **fixed 8 cycles**, LUT-based (see risk R4 —
    do *not* depend on DSP4 inference for the core multiplier).
  - DIV: non-restoring, **fixed 33 cycles**.
  - Both parameterizable out for the smallest config (`M` parameter, default on).

### 3.3 Control flow, CSRs, traps

- Branches/jumps: target computed in EX; buffer flush + 2-cycle refetch on
  taken. No BTB/BHT in v1 (documented optimization slot).
- CSRs per D7. `mcycle`/`mcycleh` are the CoreMark clock (`ee_start/ee_stop_time`
  via `rdcycle`). `wfi` = NOP, `fence.i` = NOP (no I-cache — spec-legal).
- `ecall`/`ebreak`/illegal/misaligned → trap with correct mcause/mepc/mtval.
  M-mode only, no delegation.

### 3.4 RVFI channel (formal contract)

Full RVFI: `order, insn, pc, rs1/rs2/rd (addr+data), mem (addr/rmask/wmask/
rdata/wdata), csr (addr/wdata/rdata), trap, halt, intr, mode, ixl`.

- **C instructions**: `rvfi_insn` carries the exact 16-bit word in `[15:0]`.
  Verify the masking convention against the riscv-formal spec during channel
  bring-up — this is the #1 source of "why does rv32imc prove fail" bugs.
- `rvfi_valid` low during reset and held until first retire; `rvfi_order`
  increments exactly 1 per retire.
- `rvfi_intr` tied low in v1 (D8); `rvfi_halt` deasserted (ebreak traps and
  continues).
- CSR channel reports mstatus/mtvec/mepc/mcause/mtval/mcycle family (match
  riscv-formal's counter model exactly during integration).

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
- **Depths** `(reset, exec, trigger)` = **(8, 48, 2)**: exec covers
  2 (IF1/IF2) + 1 (ID) + 33 (DIV) + 2 (WB) + margin. Fixed-latency MUL/DIV
  (D6) is what lets exec depth be a small constant.
- Modes: `prove` (bmc + induction; engines `smtbmc yices/z3` + `abc pdr`) for
  I/C coverage; `live` with fairness on reset-deassert (no deadlock); `cover`
  for reset→first-retire sanity.
- Memory model: the wrapper's RAM **is** the memory the core fetches and
  loads/stores from, and stores update the same array the checker reads —
  this catches fetch/execute coherence and execute-after-store. Von Neumann
  unification (D2) makes this trivially sound.

### 5.2 Closing the ALTOPS gap (M extension) — explicit ownership

riscv-formal with ALTOPS verifies mul/div *encoding, register semantics, and
determinism* but **not the arithmetic result**. Three layers close it:

1. **Golden-model DV (primary truth):** cocotb + Verilator, thousands of
   random + directed operand pairs; MUL/MULH*/MULHU/MULSU and DIV/DIVU/REM/
   REMU compared against an independent Python reference (different algorithm
   than RTL, e.g. long division vs non-restoring). Same tests compiled as
   bare-metal C (compiler-emitted mul/div) and cross-checked against **spike**.
2. **Bounded-width formal:** separate sby `prove` with operands truncated to
   8/16 bits against a *structurally different* reference (shift-add vs
   4-bit/cycle for mul; restoring vs non-restoring for div). Bit-blasting
   these widths with `abc pdr` is tractable and proves the datapath wiring —
   not just self-consistency. Full-width div proof explicitly out of scope.
3. **Determinism/purity property:** prove under ALTOPS that results are a pure
   function of rs1/rs2 — catches the classic sequential-divider state-leak bug.

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
| R1 | Fmax < 48 MHz (SPRAM→decode, WB paths) | M | H | Registered WB; shallow decode; 32 MHz divider fallback still clears bar; PLL stretch |
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
  handles); HFOSC 48 MHz accurate enough (no baud-rate-sensitive UART in v1 —
  fake UART is memory-mapped); reset button on UPduino 3.1 used for reset.
- Confirm UPduino 3.1 variant specifics (e.g., 5K vs 1K part) at M6 bring-up.

## Change log

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
