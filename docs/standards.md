# up5k-rv Coding Standards

The canonical reference is the **lowRISC Verilog Coding Style Guide**
(<https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md>,
CC-BY 4.0) as used by the lowRISC/Ibex project. This file records the subset
this project **mandates**, plus project-specific rules. When in doubt, follow
the canonical guide; justify any exception with a comment (and a lint waiver
pragma where appropriate).

## Language and files

- **SystemVerilog only** (IEEE 1800-2017), for RTL and testbenches.
- Extensions: `.sv` (compilation unit, **one module per file**, named after the
  module), `.svh` (headers, `include` only, never compiled standalone).
- ASCII only, UNIX line endings, **100 char max line**, no tabs, no trailing
  whitespace.
- **Frontend:** Yosys `read_slang` (sv-elab/slang, built-in since Yosys ≥ 0.67).
  Lint gate in CI: `yosys read_slang` **and** `verilator --lint-only` must both
  pass. (Verilator is stricter in places — keep it green.)

## Naming

| Construct | Style | Example |
|---|---|---|
| Modules, instances, signals, variables, functions | `lower_snake_case` | `fetch_buffer`, `alu_operand_a` |
| Tunable module parameters | `UpperCamelCase` | `MulEn`, `ResetVec` |
| Constants / `localparam` / macros | `ALL_CAPS` | `OP_JALR`, `MASK_IDLE` |
| Enumeration types | `lower_snake_case_e` | `phase_e` |
| Other typedefs | `lower_snake_case_t` | `word_t` |
| Enum values | `ALL_CAPS` | `PH_IF1`, `PH_WB` |

Signal suffix conventions (from the canonical guide):

- `_i` / `_o` / `_io` — module port direction
- `_d` / `_q` — combinational next-state vs registered state (`_q2`, `_q3`…)
- `_n` — active-low (first suffix, e.g. `rst_ni`)
- `_e` / `_t` — enum/typedef types

Mandatory:

- Ports: `clk_i` first, then `rst_ni` (active-low, asynchronous reset).
- Hierarchical consistency: a signal connecting to a port keeps the port's name.
- Group prefixes for related signals (`bus_valid`, `bus_ready`, `bus_data`).

## Clock and reset

- System clock named `clk` / port `clk_i`. Other domains: `clk_<domain>`.
- Resets are **active-low and asynchronous** by default: `rst_ni`, reset
  condition `if (!rst_ni)`.
- `always_ff @(posedge clk_i or negedge rst_ni) begin ... end` — never the
  sync-reset-only form unless justified.

## RTL rules

- `always_comb` and `always_ff` only — never bare `always` (except with
  `@*`-equivalent tools that fail; prefer always_comb).
- `logic` everywhere in RTL (no `reg`/`wire` in new code).
- Blocking (`=`) in `always_comb`; non-blocking (`<=`) in `always_ff`; never
  mix. No latches: any `always_comb` must assign every path (defaults first).
- Explicit widths on literals (`8'hA0`, not `'hA0` outside parameterized
  contexts; `'0` for zero-fill is allowed). No implicit width truncation at
  ports — use explicit concat/extension.
- Multi-bit signals must not be used in boolean context; compare explicitly
  (`if (x != '0)`).
- `case` statements: use `unique case` / `priority case` when intended; always
  include `default:`. Case-item statements must fit on one line or use
  `begin`/`end`.
- `begin`/`end` required for any statement that wraps past a single line;
  `end else begin` on one line.
- FSM state signals: named enum type `_e`, values `ALL_CAPS`, register `_q` /
  next `_d`. Store state in `always_ff`, compute next in `always_comb`.
- Module declaration: Verilog-2001 full port style (name, type, direction
  inline). Parameters block `#(...)` then ports block `(...)`, ports in order
  `clk_i, rst_ni, ...`.
- Instantiations: **named ports + named parameters only**, tabular-aligned,
  ports in declared order, `.port_name` shorthand when names match. No `.*`,
  no positional, no `defparam`.
- Package dependencies must be acyclic; declare project constants in one
  package (`up5k_rv_pkg` planned at M1).

## SystemVerilog usage split (design.md D14)

All tools consume the same SV sources, but with a deliberate split:

- **SoC glue / SBus / interconnects / peripherals (not formally verified):**
  free use of `interface` + `modport`, `typedef struct`, enums, packages —
  supported by read_slang, sby, and Verilator.
- **Core RTL (formally verified):** comfortable but disciplined subset.
  `always_ff/always_comb`, `logic`, packages, typedefs, enums, packed structs
  are all fine. Avoid: struct/array *literals*, unpacked arrays crossing the
  RVFI boundary, and anything that makes the read_slang↔read_verilog mixing
  fragile. The **RVFI/formal boundary is plain logic ports** (no interfaces),
  so riscv-formal's Verilog harness lines up cleanly — although the harness
  may itself be written in SV and read via read_slang (allowed per design.md
  D14), the *core top* exposes plain ports.

## Formal RTL hygiene

- Full reset semantics, no X/Z in reset states; all registers get reset values.
- No combinational loops; no latches (lint catches these).
- Handshake semantics documented per module so sby properties can be written
  without guessing (ack latency bounds, valid/ready invariants).

## Directed-test gotchas (iverilog)

Learned in M1 P2 while bringing up `dv/p2/` (each of these cost a
compile/run cycle before being understood):

- **Enum ternaries need an explicit cast or `if/else`.** `x ? ENUM_A : ENUM_B`
  fails elaboration with "This assignment requires an explicit cast" — use
  `if/else` (read_slang and Verilator are fine with the ternary; only iverilog
  complains).
- **Packed-struct arrays indexed by a variable crash iverilog** (internal
  assertion in `elab_expr.cc`). Use parallel unpacked arrays
  (`logic [31:0] exp_insn [0:18];` per field) for expected-value tables.
- **Declarations must precede use** at module scope: iverilog binds identifiers
  textually, so declare signals before instantiations that reference them.
- **Benign iverilog warnings** (filter with `grep -v sorry` in test runners):
  "constant selects in always_* processes" (part-selects make the process
  sensitive to all bits — harmless), "Case unique/unique0 qualities are
  ignored", and Verilator's `UNUSEDPARAM` on a package compiled standalone
  (consumers silence it once they import the package).
- **Hand-assembled instruction encodings in test vectors are error-prone.**
  Use `tools/riscv_enc.py` (see `tools/README.md`) to generate instruction
  words; its self-check asserts against encodings verified by `dv/p2`.
- Directed tests are the fast loop; the riscv-formal `rv32i` prove (P3) is the
  strong gate that subsumes leaf correctness — keep leaf tests small and
  focused on one module's contract.

## Formal tooling gotchas (sby / riscv-formal)

Learned in M1 P3 while bringing up the `rv32i` prove suite (each cost a
debug cycle or several before being understood):

- **The repo's virtiofs mount breaks sby workdirs.** `rmtree()` of a leftover
  workdir (a child of the sby cwd) transiently invalidates the process cwd —
  `os.getcwd()` returns `FileNotFoundError` and sby crashes; parallel
  `read_slang` on the mount is also flaky ("tree cannot be null"). **Run sby
  with `-d` on native FS** (e.g. `/tmp/up5k-m1-sby`) — the generated `.sby`
  files may stay in the repo; `scripts/formal_m1.sh` already does this.
  The same corruption hits any python that `rmtree`s a repo subdir from a
  repo-root cwd (genchecks.py) — run such tools from a native cwd.
- **Judge sby status from the log, never the exit code.** Generated `.sby`
  files use `expect pass,fail`, so sby returns rc=0 for a real counterexample
  FAIL too. Grep for `DONE (PASS` in the log.
- **Invoke riscv-formal `genchecks.py` by absolute path** from the binding
  dir: the relocated OSS-CAD python breaks on a relative `sys.path[0]`.
- **Consistency checks are bmc, not prove.** `reg` and `pc_bwd` checkers keep
  forward-looking state (register shadow / next-retirement look-ahead) that
  k-induction misfires on — the induction step fires the check on a stale
  checker pre-state (spurious UNKNOWN) and the `reg` basecase is intractable.
  `pc_fwd` looks backward and proves fine. See `formal/up5k_rv/checks.cfg`.
- **`RESET_CYCLES 1 → 8` and the read_slang/read_verilog split must be
  post-processed** into the generated checks (genchecks hardcodes 1; the
  harness stays on `read_verilog -sv`). `scripts/formal_m1_gen.py` does both.
- **riscv-formal models require traps for misaligned accesses and control-flow
  targets.** A trap-less M1 core must scope the proof via `[assume]` (aligned
  PCs, load/store addresses, branch/jal/jalr targets); D9 traps land in M2 and
  the assumptions drop. Counterexample triage: `tools/sby_retire_stream.py`
  extracts the retire stream from a trace VCD.

## Comments

- `//` C++ style preferred; header-style section banners (`////////`) for major
  module regions (FSM, datapath, etc.).
- Every module gets a one-line description header + parameter docs.
- TODO/note style follows Google C++ guide (`// TODO(username): ...`).
- Units in constant names (`FooLengthBytes`, `SYS_CLK_HZ`).

## Build flags (software, M4)

- `-O2 -march=rv32imc -mabi=ilp32`, newlib, per-memory-map linker script.
- CoreMark: `PORT_DIR=sw/coremark` (barebones copy), `ee_printf` → fake-UART
  MMIO, `rdcycle` timing, `MAIN_HAS_NOARGC=1`, `TOTAL_DATA_SIZE=2000`.
