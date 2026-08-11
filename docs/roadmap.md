# up5k-rv Roadmap

**Read this first when starting any work.** It is the single source of truth
for what has been done, what is next, and what a session must record on exit.
See [handoff.md](handoff.md) for the session protocol.

## Current state

- Design **LOCKED** (docs/design.md, 2026-08-11).
- Docs/backbone committed to git.
- **Next action: M0** (repo scaffold + toolchain pin + formal toolchain smoke).
- Active milestone: **none** (M0 not yet started).

## Milestone tracking

| M | Milestone | Status | Exit criteria |
|---|---|---|---|
| M0 | Scaffold + toolchain smoke | **TODO** | Repo layout, toolchain pinned, lint gate green, riscv-formal submodule, **stock picorv32 binding green through sby in CI** |
| M1 | RV32I core + RVFI | TODO | RV32I multi-cycle core; riscv-formal `rv32i` prove passing in CI |
| M2 | C ext + traps + CSRs | TODO | `rv32imc` prove **and** live green (ALTOPS) |
| M3 | MUL/DIV units | TODO | Bounded-width formal + golden DV + determinism property green; full rv32imc suite green |
| M4 | CoreMark port + perf | TODO | CoreMark score in Verilator sim; spike cross-check; CPI target met |
| M5 | SoC v1 + bootloader | TODO | SBus + decoder + ROM + SPRAM + fake-UART + timer + GPIO; uart_loader.py; demos |
| M6 | FPGA bring-up (UPduino 3.1) | TODO | Timing closure ≥ 48 MHz; CoreMark on hardware; score report vs sim |
| M7 | Formal CI hardening + docs | TODO | Nightly full suite, per-PR smoke, docs review, risk review |
| M8 | Stretch: mtimer intr, SPI flash boot, DSP4 peripheral demo | TODO | As scoped when started |

Status legend: `TODO` / `IN PROGRESS` / `BLOCKED` / `DONE`.

## Milestone work protocol

- Each milestone is **one deepwork run** (high-cost orchestrator workflow with
  its own plan + review gates). When a milestone starts, note it in its section
  below with the date, the session, and the deepwork plan reference.
- A milestone is **DONE** only when its exit criteria are actually met and
  verified (formal suite green in CI, reports committed). Never mark DONE on
  intent.
- If a milestone finishes partially, leave it `IN PROGRESS` and record the
  blocker + where it stopped in the section's *Handoff notes*.

---

## M0 — Scaffold + toolchain smoke

- **Objective:** prove the toolchain and repo before writing our RTL.
- **Tasks:**
  1. Create repo layout (rtl/, formal/, dv/, sw/, tools/, scripts/, constraints/).
  2. Pin toolchain: OSS CAD Suite version (Yosys ≥ 0.67 w/ `read_slang`),
     riscv-gnu-toolchain (newlib) — record exact versions in a manifest.
  3. Lint gate: `yosys read_slang` + `verilator --lint-only` on a hello module.
  4. Add riscv-formal as submodule; run **stock picorv32 binding** through sby
     in CI (`rv32imc` prove, shallow depth first) — proves formal toolchain
     end-to-end including the read_slang↔read_verilog mixing.
  5. Commit + CI skeleton (or Makefiles if no CI available yet).
- **Exit criteria:** stock picorv32 formal proof green in CI; lint gate green.
- **Handoff notes:** *(empty — not started)*

## M1 — RV32I core + RVFI

- **Objective:** minimal core with formal prove early (catches fetch/decode/
  retire bugs at minimum scope).
- **Tasks:** fetch buffer + phase FSM; ALU; regfile; RVFI channel; wrapper +
  memory model; riscv-formal `rv32i` prove in CI.
- **Exit criteria:** `rv32i` prove green; RVFI channel conventions documented
  (incl. C-word masking plan for M2).
- **Handoff notes:** *(empty)*

## M2 — C extension + traps + CSRs

- **Objective:** rv32imc prove + live green.
- **Tasks:** C decoder; ecall/ebreak/illegal/misaligned traps; CSR set (D7);
  mcycle/mcycleh; liveness fairness constraints; `cover` depth calibration.
- **Exit criteria:** `rv32imc` prove **and** live green (ALTOPS); RVFI harness
  in SV via read_slang.
- **Handoff notes:** *(empty)*

## M3 — MUL/DIV units

- **Objective:** parameterized M unit closed three ways (design.md §5.2).
- **Tasks:** 4-bit/cycle shift-add MUL (8 cyc); non-restoring DIV (33 cyc);
  `M` parameter (default on); bounded-width formal proofs; golden-model cocotb
  DV; determinism property.
- **Exit criteria:** full rv32imc suite green; M-arithmetic closure evidence
  committed (golden DV + bounded proofs).
- **Handoff notes:** *(empty)*

## M4 — CoreMark port + performance

- **Objective:** CoreMark score in simulation, cross-checked against spike.
- **Tasks:** CoreMark port (barebones copy, ee_printf → fake-UART MMIO,
  rdcycle timing, MAIN_HAS_NOARGC=1, TOTAL_DATA_SIZE=2000); BSP (crt0, linker
  script, newlib syscalls); end-to-end sim; spike hash/score cross-check;
  tuning pass (fetch overlap, branch penalty) until CPI target.
- **Exit criteria:** valid ≥10 s CoreMark run in sim; CoreMark/MHz × Fmax(est)
  > 20 demonstrated; spike agreement.
- **Handoff notes:** *(empty)*

## M5 — SoC v1 + bootloader

- **Objective:** full SoC demo.
- **Tasks:** SBus + decoder; BRAM ROM; SPRAM wrapper; fake-UART (write-only
  reg + FIFO); timer; GPIO; ROM bootloader + UART download protocol;
  tools/uart_loader.py; demos (blink, echo, CoreMark runner); SoC decoder +
  bounded-response sby proves.
- **Exit criteria:** SoC formal proves green; CoreMark runs end-to-end in sim
  via loader path.
- **Handoff notes:** *(empty)*

## M6 — FPGA bring-up (UPduino 3.1)

- **Objective:** CoreMark on real silicon.
- **Tasks:** constraints (.pcf); synth_ice40 + nextpnr-ice40 + icetime;
  timing closure ≥ 48 MHz; iceprog; loader over real USB-UART; CoreMark on
  hardware; score report vs sim.
- **Exit criteria:** timing-closed bitstream; CoreMark score on hardware
  committed to the report.
- **Handoff notes:** *(empty)*

## M7 — Formal CI hardening + docs

- **Objective:** durable verification story.
- **Tasks:** nightly full suite with timeouts; per-PR smoke; docs review
  (design.md vs implementation drift); risk review; report drafting
  (honest formal statement per design.md §5.2).
- **Exit criteria:** CI pipeline stable; docs accurate; risk review done.
- **Handoff notes:** *(empty)*

## M8 — Stretch items

- mtimer interrupt (with its formal implications — revisit D8), SPI flash
  boot, DSP4 peripheral demo. Scope when started.

---

## Change log

- 2026-08-11 — Roadmap created from locked design (docs/design.md). M0–M8 as
  above.
