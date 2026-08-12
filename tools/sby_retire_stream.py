#!/usr/bin/env python3
"""up5k-rv -- extract the retire stream from a SymbiYosys counterexample VCD.

When a riscv-formal check fails, the first question is "what did the core
actually retire, and where does the checker disagree?" The trace VCDs sby
dumps are from the FLATTENED design, which makes naive parsing misleading:

  - signals named `anyinit_*` are the *initial-state drivers*, not live state
    (the real registers are the bare flattened names: `phase_q`, `word_pending_q`,
    `rvfi_pc_rdata`, ...);
  - VCD value blocks for time T come AFTER the `#T` line (sample at the next
    `#`, using the values accumulated so far);
  - some signal names appear multiple times (e.g. `rvfi_trap`, `spec_trap` in
    the checker and wrapper) -- this tool shows the first instance per name by
    default and every instance with --all-instances.

Usage:
  python3 tools/sby_retire_stream.py <trace.vcd> [--all-instances] [--detail]

Prints one line per cycle where the core's `rvfi_valid` is asserted (a retire):
cycle, rvfi_order, pc_rdata, pc_wdata, insn, rs1/rs2 addr+rdata, rd, mem
fields, and -- when present -- the checker's `spec_trap` next to the core's
`rvfi_trap` (the usual trap-scoping counterexample) and the `check` cycle
marker. With --detail, also prints the pipeline state (phase_q, word_pending_q,
fetch state) on state changes.

Was written from M1 P3's repeated counterexample triage; keep it generic (it
should work for any riscv-formal core binding, not just up5k-rv).
"""

import re
import sys

# Signals shown in the per-retire line (first instance by default).
RETIRE_SIGNALS = [
    "rvfi_order", "rvfi_insn", "rvfi_pc_rdata", "rvfi_pc_wdata",
    "rvfi_rs1_addr", "rvfi_rs1_rdata", "rvfi_rs2_addr", "rvfi_rs2_rdata",
    "rvfi_rd_addr", "rvfi_rd_wdata",
    "rvfi_mem_addr", "rvfi_mem_rmask", "rvfi_mem_wmask",
    "rvfi_mem_rdata", "rvfi_mem_wdata",
    "rvfi_trap", "spec_trap", "check",
]
# Extra pipeline state for --detail.
DETAIL_SIGNALS = [
    "phase_q", "word_pending_q", "fetch_phase_q", "fetch_pc_q", "word_pc_q",
    "insn_exe_q", "pc_exe_q", "order_q",
]


def base_name(name: str) -> str:
    """Last path component; the flattened trace keeps hierarchy in dots."""
    return name.split(".")[-1]


def fmt(v) -> str:
    return "?" if v is None else (f"0x{v:x}" if isinstance(v, int) else str(v))


def parse_vcd(path: str):
    """Yield (time, signal_values) snapshots, one per `#T` line.

    `signal_values` maps base-name -> list of values (one per instance, in
    $var declaration order), excluding anyinit_* init drivers. The snapshot
    for time T reflects the state after the previous value blocks -- i.e. the
    state AT time T once its own block has been consumed.
    """
    instances = {}  # wire id -> full name
    vals = {}       # wire id -> int value
    last_t = None
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("$var"):
            m = re.match(r"\$var (\w+) (\d+) (\S+) (\S+)", line)
            if m and not m.group(4).startswith("anyinit_"):
                instances[m.group(3)] = m.group(4)
            continue
        if line.startswith("#"):
            if last_t is not None:
                yield last_t, snapshot(instances, vals)
            last_t = int(line[1:])
            continue
        if line.startswith("b"):
            m = re.match(r"b([01xXzZ]+)\s+(\S+)", line)
            if m and m.group(2) in instances:
                vals[m.group(2)] = int(m.group(1), 2)
            continue
        if len(line) > 1 and line[0] in "01xXzZ" and line[1:] in instances:
            vals[line[1:]] = 1 if line[0] == "1" else 0
    if last_t is not None:
        yield last_t, snapshot(instances, vals)


def snapshot(instances, vals):
    """Base-name -> list of per-instance values."""
    out = {}
    for wid, name in instances.items():
        out.setdefault(base_name(name), []).append(vals.get(wid))
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    detail = "--detail" in sys.argv
    all_inst = "--all-instances" in sys.argv
    if not args:
        print(__doc__)
        return 1

    want = set(RETIRE_SIGNALS + (DETAIL_SIGNALS if detail else []))
    seen_phases = set()
    last_key = None
    for t, sig in parse_vcd(args[0]):
        valid = sig.get("rvfi_valid", [None])[0]
        if valid == 1:
            # The same retire is sampled across several VCD time steps (the
            # clock-edge window); print it once.
            key = (sig.get("rvfi_order", [None])[0], sig.get("rvfi_pc_rdata", [None])[0])
            if key == last_key:
                continue
            last_key = key
            parts = [f"t={t}"]
            for name in RETIRE_SIGNALS:
                vs = sig.get(name, [None])
                if name in ("check", "rvfi_trap", "spec_trap"):
                    parts.append(f"{name}={'|'.join(fmt(v) for v in vs) if all_inst else fmt(vs[0])}")
                else:
                    parts.append(f"{name}={fmt(vs[0])}")
            print("  ".join(parts))
        if detail:
            phase = sig.get("phase_q", [None])[0]
            if phase is not None and phase not in seen_phases:
                seen_phases.add(phase)
                parts = [f"t={t}"]
                for name in DETAIL_SIGNALS:
                    if name == "phase_q":
                        continue
                    parts.append(f"{name}={fmt(sig.get(name, [None])[0])}")
                print("      " + "  ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
