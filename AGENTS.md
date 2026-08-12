# Project Guidance — up5k-rv

A small, formally-verified RV32IMC RISC-V core + SoC for the Lattice iCE40
UP5K (target board: UPduino 3.1), built with open-source tools.

## For agents working in this repo

**Start every session by reading the docs — they are the shared memory:**

1. `docs/roadmap.md` — current state, active milestone, next action.
   **Read this first.**
2. `docs/handoff.md` — session entry/exit protocol (mandatory).
3. `docs/design.md` — locked architecture and decisions.
4. `docs/standards.md` — lowRISC/Ibex coding style; read before writing RTL.

**Rules:**

- Follow the handoff protocol in `docs/handoff.md` on entry and exit.
- Never mark a milestone `DONE` unless its exit criteria are met and verified.
- Record design changes in `docs/design.md` (decisions table + change log),
  never edit locked decisions silently.
- Coding style: lowRISC/Ibex (docs/standards.md). SystemVerilog via Yosys
  `read_slang` (Yosys ≥ 0.67).
- Language/toolchain facts and target specs live in `docs/design.md` — do not
  re-derive them.

**Delegation notes (learned in M1 — verify before trusting a specialist result):**

- A returned task result that is EMPTY is not a success, even if the session
  is bookkept as "completed". Before treating any delegated session as done
  (or resuming/reusing it), verify its expected write-scope artifacts actually
  exist on disk (`git status`, `ls` the declared output paths).
- If a session returns empty with no artifacts, do NOT resume it repeatedly.
  After one empty return, switch strategy: fresh session, smaller bounded
  lane, or direct implementation.
- Large multi-module RTL generation has repeatedly returned empty from fixer
  sessions here. Prefer direct implementation or single-module lanes with a
  fixed interface contract over one large delegation for RTL. Fixer is
  reliable for toolchain install, scaffolding, and bounded mechanical edits.

## Environment notes

- Sandbox network policy controls outbound research (see AGENTS.md above this
  repo for sandbox/network docs).
- Toolchain pinning happens at M0 (OSS CAD Suite, riscv-gnu-toolchain newlib).
  Until then, do not assume specific Yosys/sby versions beyond `read_slang`
  availability (Yosys ≥ 0.67).
