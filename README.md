# up5k-rv

A small, formally-verified **RV32IMC** RISC-V core and SoC for the **Lattice
iCE40 UP5K** FPGA, built with open-source tools (Yosys / nextpnr-ice40 /
icestorm, Verilator, SymbiYosys + riscv-formal, RISC-V GNU toolchain).

The core is a **multi-cycle, von Neumann** design optimized for **minimum
area** — it must leave most of the UP5K's 5280 logic cells free for the
customer's ADC + DSP logic — while clearing a **CoreMark/MHz × Fmax > 20**
performance bar (post-review projection: ~0.6–0.9 CM/MHz pre-tuning, ≥ 1.0
CM/MHz target after M4 tuning; long-term aspiration is the Pareto frontier in
[`docs/pareto_frontier.csv`](docs/pareto_frontier.csv) — see `docs/design.md`
§1.1).

"Educational" here means *well organized and clearly documented*, not a toy:
the RTL follows the lowRISC/Ibex coding style, the design decisions are
recorded in `docs/design.md`, and every milestone is tracked in
`docs/roadmap.md` so work can be picked up and handed off across sessions.

## Status

- Design phase **complete** — decisions locked and recorded in
  [`docs/design.md`](docs/design.md).
- Documentation/tracking backbone in place (this repo).
- **M0–M2 complete** — rv32imc formal prove green (78/78 checks).
- **Next action:** Milestone **M3** — real MUL/DIV units + M-arithmetic
  closure. See [`docs/roadmap.md`](docs/roadmap.md).

## Key facts

| | |
|---|---|
| ISA | RV32IMC (M parameterized, default on) |
| Microarchitecture | Multi-cycle, overlapped next-fetch, ~1.8–2.4k LC |
| Memory | Von Neumann, unified; custom SBus interface (valid/ready/byte-enables) |
| Target board | UPduino 3.1 (iCE40UP5K, on-board USB-UART) |
| Clock | HFOSC 48 MHz direct; 12 MHz XO + PLL → 48 MHz from M5 (UART-loader accuracy); Fmax target ≥ 48 MHz |
| Language | SystemVerilog (via Yosys `read_slang` frontend, built-in since Yosys ≥ 0.67) |
| Verification | riscv-formal `rv32imc` (prove + live) + golden-model DV + bounded-width formal for the M unit |
| Demo | CoreMark bare-metal, output to a memory-mapped "fake UART" write register |

## Documentation index

- [`docs/design.md`](docs/design.md) — full design: architecture, decisions,
  memory map, microarchitecture, formal verification plan, risks.
- [`docs/roadmap.md`](docs/roadmap.md) — milestones M0–M8, status tracking,
  deepwork usage, handoff notes. **Read this first when starting work.**
- [`docs/standards.md`](docs/standards.md) — coding style (lowRISC/Ibex) and
  SystemVerilog usage rules for this project.
- [`docs/handoff.md`](docs/handoff.md) — cross-session handoff protocol:
  how to record state so a fresh session can pick up cleanly.
- [`AGENTS.md`](AGENTS.md) — pointers for AI agents working in this repo.

## Repository layout (target)

```
├── rtl/            # core/ + soc/ (SystemVerilog)
├── formal/         # riscv-formal submodule, RVFI channel, mul/div proofs, .sby files
├── dv/             # cocotb golden-model DV, CoreMark end-to-end sim, spike cross-check
├── sw/             # bootrom, CoreMark port, BSP (crt0/ld/syscalls), demos
├── tools/          # uart_loader.py, elf2bin.py
├── scripts/        # build, formal CI, synth (nextpnr-ice40), lint
├── constraints/    # .pcf timing constraints
└── docs/           # this documentation
```

## Toolchain (pinned at M0)

- **OSS CAD Suite** (latest release): Yosys ≥ 0.67 (`read_slang`), nextpnr-ice40,
  icestorm (icepack/iceprog/icetime), Verilator, iverilog, SymbiYosys.
- **riscv-gnu-toolchain** (prebuilt, newlib): `riscv-none-elf-gcc` with
  `-march=rv32imc -mabi=ilp32` (pinned in MANIFEST.md).
- Exact versions pinned in CI at M0; see `docs/design.md` §Toolchain.
