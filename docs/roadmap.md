# up5k-rv Roadmap

**Read this first when starting any work.** It is the single source of truth
for what has been done, what is next, and what a session must record on exit.
See [handoff.md](handoff.md) for the session protocol.

## Current state

- Design **LOCKED** (docs/design.md, 2026-08-11).
- Docs/backbone committed to git.
- **Next action: M3** (MUL/DIV units — M-arithmetic closure).
- Active milestone: **M2 done** (2026-08-12; see M2 section).
- Post-M2 design/workplan review complete (2026-08-12): perf estimate
  corrected, D18 → core-side ALTOPS substitution, M3 formal re-tune
  (liveness window), Pareto frontier aspiration (design.md §1.1). The M3–M7
  task lists below incorporate it.

## Milestone tracking

| M | Milestone | Status | Exit criteria |
|---|---|---|---|
| M0 | Scaffold + toolchain smoke | **DONE** (2026-08-11, deepwork) | Repo layout, toolchain pinned, lint gate green, riscv-formal submodule, **stock picorv32 binding green through sby in CI** |
| M1 | RV32I core + RVFI | **DONE** (2026-08-12, deepwork) | RV32I multi-cycle core; riscv-formal `rv32i` prove passing in CI |
| M2 | C ext + traps + CSRs | **DONE** (2026-08-12) | `rv32imc` prove **and** live green (ALTOPS) |
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

- **Status: DONE** (2026-08-11). Oracle review gate: APPROVE WITH FIXES; all
  fixes applied and re-verified.
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
- **Result / evidence:** all criteria met. 15-check representative subset of
  the stock picorv32 `rv32imc` binding green via sby (bmc depth 20, engine
  smtbmc boolector): ALU/load/store/branch/jal/jalr/C×2/M×2/reg/pc_fwd/pc_bwd,
  9–162 s/check, `make formal-smoke` exits 0. Full 87-check suite + prove mode
  deferred to M3 (see design.md R10–R12).
- **Pins:** MANIFEST.md (yosys 0.68+48, nextpnr-ice40 0.11, verilator 5.051,
  iverilog 14.0, sby 0.68, riscv-none-elf-gcc 15.2.0 newlib, riscv-formal
  `c992aa61`, picorv32.v vendored @ `a473fc8f`).
- **Known constraints:** toolchains live in /home/agent/up5k-tools (repo's
  Windows mount blocks symlinks); override with `UP5K_TOOLS_ROOT`.
- **Handoff notes:** Next action is M1 (RV32I core + RVFI). M1 must start
  with the two toolchain-validity tasks from design.md R10/R11: (a) one
  `abc pdr` prove run on the stock binding, (b) the first SV RVFI wrapper +
  trivial core through sby (exercises the read_slang↔read_verilog mixing).
  Working commands: `make env`, `make lint`, `make sim-hello`,
  `make formal-smoke`.
  Note (2026-08-12 review): the "in CI" exit-criteria wording — no CI exists
  yet (Makefiles were the M0 fallback); real CI lands at M7.

## M1 — RV32I core + RVFI

- **Objective:** minimal core with formal prove early (catches fetch/decode/
  retire bugs at minimum scope).
- **Tasks:** fetch buffer + phase FSM; ALU; regfile; RVFI channel; wrapper +
  memory model; riscv-formal `rv32i` prove in CI.
- **Exit criteria:** `rv32i` prove green; RVFI channel conventions documented
  (incl. C-word masking plan for M2).
- **Handoff notes:** P2 (core RTL) DONE 2026-08-12, staged per deepwork plan
  (`.slim/deepwork/m1-core-rvfi.md`): `rtl/core/{up5k_rv_pkg,regfile,alu,
  decoder,lsu,fetch_unit,rv32i_core}.sv` with per-stage directed tests in
  `dv/p2/` — `make p2-tests` green (6 tests) and `make lint` green. P3 (RVFI
  wrapper + memory model + `rv32i` prove) DONE 2026-08-12: **41-check rv32i
  prove suite green** (`make formal-m1`; 37 insn checks + pc_fwd by
  k-induction via smtbmc yices, reg/pc_bwd by bmc, cover non-vacuous). Oracle
  gate APPROVE WITH FIXES (findings closed in P5). Formal artifacts:
  `formal/up5k_rv/{wrapper.sv,checks.cfg}`, `scripts/formal_m1.sh` +
  `formal_m1_gen.py`. **Next action: M2** (C-ext + traps + CSRs). M1 exit
  criteria met: `rv32i` prove green; RVFI conventions documented in
  `formal/rvfi_channel/README.md` incl. the C-word masking plan for M2.
  M1 scoping note: the trap-less core is proven under aligned-access
  assumptions (checks.cfg `[assume]`); unaligned cases become spec_trap=1
  checks when D9 traps land in M2. Known formal gap (recorded in design.md
  §5.1 change log): load data path not pinned by the insn checks — DV covers
  it; shared-RAM wrapper or dmem checks at M2/M5. Tooling: sby workdirs must
  be on native FS (virtiofs breaks them) — the runner handles this. Working
  commands: `make lint`, `make p2-tests`, `make formal-m1`,
  `make formal-m1-smoke`.

## M2 — C extension + traps + CSRs

- **Status: DONE** (2026-08-12, deepwork). Oracle gates 1 + 2: APPROVE.
- **Objective:** rv32imc prove + live green.
- **Tasks:** C decoder; ecall/ebreak/illegal/misaligned traps; CSR set (D7);
  mcycle/mcycleh; liveness fairness constraints; `cover` depth calibration.
- **Exit criteria:** `rv32imc` prove **and** live green (ALTOPS); RVFI harness
  in SV via read_slang.
- **Result / evidence:**
  - `make formal-m2` = **78/78 rv32imc checks green** (70 insn checks: 37 I +
    25 C + 8 M ALTOPS; reg/pc_fwd/pc_bwd consistency; csrw/csrc mcycle counter;
    liveness; cover). Runner: `scripts/formal_m2.sh` + `formal_m2_gen.py`,
    checks.cfg `isa rv32imc` + `[csrs] mcycle inc upcnt` (M1 alignment
    `[assume]`s deleted — the M2 core traps on the model-pinned unaligned
    cases).
  - `make p2-tests` = 10 directed tests green (incl. tb_trap, tb_csr_pipe,
    tb_m, tb_core 48-retire program).
  - **Honest "live green" statement:** liveness is proven as **bmc-mode
    bounded progress** — every retirement is followed by the next within the
    20-cycle window, with `RISCV_FORMAL_FAIRNESS` — byte-for-byte the
    picorv32 reference binding's liveness configuration. Unbounded liveness
    (sby `mode live` / aiger suprove) is NOT proven: suprove in the pinned
    toolchain returns "could not determine engine status" (rc=16); revisit at
    M7 when the toolchain updates.
- **Handoff notes:**
  - RTL: C-ext decode + fetch granularity (PC[1] halfword, seq_pc +2/+4,
    decoder-driven regfile read at ID), model-matched traps (mcause 0/2/3/4/
    6/11, LSU suppression), mret, D7 CSR set, csrrw/csrrs/csrrc ±i, rvfi_csr
    channel (mcycle 64-bit). **mcycle/mcycleh are read-only (D19)** — csrw
    writes are reported on the channel but not applied; CoreMark (M4) uses
    rdcycle reads only, so no BSP conflict.
  - Three bugs the formal suite found and fixed (recorded in design.md change
    log): ALTOPS masks use the LOW 32 bits of the models' 64-bit constants;
    reserved SYSTEM funct3=100 → illegal (was an invisible CSR write); writable
    mcycle → read-only.
  - Known formal gap (design.md §5.1): load *data* path not pinned by the insn
    checks (DV covers; shared-RAM wrapper/dmem checks at M2/M5).
  - Next action: M3 (MUL/DIV units + M-arithmetic closure: golden DV + bounded
    proofs + determinism; wrapper-side ALTOPS compensation once real units land).

## M3 — MUL/DIV units

- **Objective:** parameterized M unit closed three ways (design.md §5.2).
- **Tasks:** 4-bit/cycle shift-add MUL (8 cyc); non-restoring DIV (33 cyc);
  `M` parameter (default on); bounded-width formal proofs (**bmc-first**,
  §5.2 revised); golden-model cocotb DV; **core-side ALTOPS substitution** in
  the M unit (`FormalAltops` param, D18 amended — wrapper-side compensation
  rejected); **formal re-tune before the real units land**: `liveness 1 10 50`
  (the 33-cycle DIV breaks the 20-cycle window — retire gap ~36–38) and
  bmc-smoke `insn_div` check-cycle re-tune (exact-cycle semantics — vacuity
  risk); **pin spike + cocotb** in MANIFEST.md/env.sh (load-bearing for the
  exit criteria); DIV/DIVU/REM/REMU corner cases in DV (÷0, INT_MIN/−1,
  REM-by-0, MULH/MULHSU/MULHU sign patterns); **mstatus.MPP WARL=M fix**
  (csr_file.sv — M-mode-only core; mret sets MPP=11, not 00); `M=0` policy
  (document `M=1` as the proven config, or add a separate `rv32ic` run).
- **Exit criteria:** full rv32imc suite green — **ALTOPS config**: the real-M
  *control path* is proven, arithmetic truth carried by golden DV + bounded
  proofs + spike cross-check (state it this way in the report); golden DV +
  bounded proofs committed.
- **Handoff notes:** *(empty)*

## M4 — CoreMark port + performance

- **Objective:** working CoreMark system in sim (start small — the Pareto
  frontier is a long-term target, not a v1 gate; see design.md §1.1), then
  the first tuning pass.
- **Tasks:** CoreMark port (barebones copy, ee_printf → **TB-level fake-UART
  MMIO stub** @0x2000_0000 + flat SBus SPRAM model — the SoC is M5;
  rdcycle timing, MAIN_HAS_NOARGC=1); **TOTAL_DATA_SIZE=2000 vs the 32 KB
  SPRAM budget check in sim** (likely overflow — fallback 1500 or a 64 KB
  map); BSP (crt0, linker script, newlib syscalls); end-to-end sim; spike
  hash/score cross-check; D5 tuning pass (forwarding, tighter overlap,
  remove the IDLE cycle).
- **Exit criteria:** valid ≥10 s CoreMark run in sim (reduced iterations for
  iteration loops — the 10 s certification run costs ~480M cycles);
  **measured CM/MHz ≥ 1.0 in sim** (numeric CPI target — replaces the
  unquantified "CPI target met" and the unfalsifiable Fmax(est) term);
  **`make formal-m2` full suite re-green after the schedule change** (D5
  edits rtl/core/); spike agreement.
- **Handoff notes:** *(empty)*

## M5 — SoC v1 + bootloader

- **Objective:** full SoC demo.
- **Tasks:** SBus + decoder; BRAM ROM; SPRAM wrapper; fake-UART (write-only
  reg + FIFO); **real UART RX/TX peripheral + RX register in the memory map**
  (the bootloader and echo demo need one — previously unscheduled); timer;
  GPIO; ROM bootloader + UART download protocol; tools/uart_loader.py; demos
  (blink, echo, CoreMark runner); **shared-RAM/dmem formal wrapper — closes
  the load-data-path + execute-after-store gap** (design.md §5.1, deferred
  from M2); **fetch_unit stale-response suppression** for registered-latency
  slaves (M1 note) + `make formal-m2` re-run after the rtl/core/ edit;
  **D12 clock decision**: 12 MHz XO + PLL → 48 MHz (UART accuracy — HFOSC
  ±5% fails at 115200); SoC decoder + bounded-response sby proves.
- **Exit criteria:** SoC formal proves green; CoreMark runs end-to-end in sim
  via the loader path; load-data/execute-after-store checks green.
- **Handoff notes:** *(empty)*

## M6 — FPGA bring-up (UPduino 3.1)

- **Objective:** CoreMark on real silicon.
- **Tasks:** constraints (.pcf); synth_ice40 + nextpnr-ice40 + icetime;
  timing closure ≥ 48 MHz; **confirm the programming path (SPI flash vs
  FTDI-SRAM)**; iceprog; loader over real USB-UART; CoreMark on hardware;
  score report vs sim.
- **Exit criteria:** timing-closed bitstream; CoreMark score on hardware
  committed to the report **with the Pareto frontier comparison (design.md
  §1.1) — the first real data point for the aspiration ladder**.
- **Handoff notes:** *(empty)*

## M7 — Formal CI hardening + docs

- **Objective:** durable verification story.
- **Tasks:** nightly full suite with timeouts; per-PR smoke; **revisit sby
  `mode live` / suprove** (deferred from M2 — pending a toolchain update);
  docs review (design.md vs implementation drift); risk review; report
  drafting (honest formal statement per design.md §5.2).
- **Exit criteria:** CI pipeline stable; docs accurate; risk review done.
- **Handoff notes:** *(empty)*

## M8 — Stretch items

- mtimer interrupt (with its formal implications — revisit D8), SPI flash
  boot, DSP4 peripheral demo. Scope when started.

---

## Change log

- 2026-08-11 — Roadmap created from locked design (docs/design.md). M0–M8 as
  above.
