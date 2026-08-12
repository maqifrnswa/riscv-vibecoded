#!/usr/bin/env python3
"""up5k-rv -- M2 P2: generate + post-process riscv-formal checks for the RV32IMC core.

Runs riscv-formal genchecks.py for our binding and rewrites the generated
.sby files so the proof uses the pinned frontends and depths:

  * The generated `read -sv <check>.sv <wrapper.sv>` line is split into:
      - `read_slang <pkg> <core modules> <wrapper>`   (our SystemVerilog -- D14)
      - `read_verilog -sv <check>.sv`                 (riscv-formal harness)
    This is the read_slang <-> read_verilog mixing path validated in M1 P1b.
  * `RISCV_FORMAL_RESET_CYCLES 1` -> 8 for the insn checks (design.md §5.1).

M2 changes vs formal_m1_gen.py:
  - rtl/core/csr_file.sv added to the core SV set.
  - The csrc_* checks (accumulating shadow state, not k-induction-friendly)
    join reg/pc_bwd in bmc mode.

Build-time binding dir: formal/riscv-formal/cores/up5k_rv/ (inside the pinned
submodule -- ephemeral, gitignored). The committed sources live in
formal/up5k_rv/ (wrapper.sv, checks.cfg) and rtl/core/.

Usage: formal_m2_gen.py <REPO_ROOT>
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

# Core SV file order: package first (slang resolves imports per-file), then the
# leaf modules, then the top, then the formal wrapper.
CORE_SV = [
    "rtl/core/up5k_rv_pkg.sv",
    "rtl/core/decoder.sv",
    "rtl/core/regfile.sv",
    "rtl/core/alu.sv",
    "rtl/core/lsu.sv",
    "rtl/core/fetch_unit.sv",
    "rtl/core/csr_file.sv",
    "rtl/core/rv32i_core.sv",
    "formal/up5k_rv/wrapper.sv",
]


def main() -> None:
    repo = os.path.abspath(sys.argv[1])
    # The repo lives on a virtiofs mount whose dentry cache is invalidated by
    # rmtree() of a subdirectory; run from a NATIVE-FS cwd (see M1 notes).
    os.chdir(tempfile.gettempdir())
    rf_dir = os.path.join(repo, "formal", "riscv-formal")
    src_dir = os.path.join(repo, "formal", "up5k_rv")

    # Stage the whole generation on NATIVE FS (virtiofs corrupts getcwd()).
    native_root = os.path.join(tempfile.gettempdir(), "up5k-rv-formal-m2")
    bind_dir = os.path.join(native_root, "cores", "up5k_rv")
    checks_dir = os.path.join(bind_dir, "checks")

    # 1. (Re)create the native binding dir and mirror the riscv-formal layout.
    shutil.rmtree(bind_dir, ignore_errors=True)
    os.makedirs(bind_dir)
    for sub in ("checks", "insns"):
        link = os.path.join(native_root, sub)
        if not os.path.islink(link):
            os.symlink(os.path.join(rf_dir, sub), link)
    for f in ("wrapper.sv", "checks.cfg"):
        shutil.copy(os.path.join(src_dir, f), os.path.join(bind_dir, f))

    # 2. Run genchecks.py from the native binding dir.
    print(f"==> [m2-gen] genchecks.py (isa from checks.cfg) into {checks_dir}")
    subprocess.run(
        ["python3", os.path.join(rf_dir, "checks", "genchecks.py")],
        cwd=bind_dir,
        check=True,
    )

    # 3. Post-process each generated .sby.
    read_line_re = re.compile(r"^read -sv (\S+\.sv) (.+?wrapper\.sv)$", re.MULTILINE)
    reset_re = re.compile(r"RISCV_FORMAL_RESET_CYCLES 1\b")
    # Consistency checks whose checker has forward-looking / accumulating state
    # (reg shadow, pc_bwd look-ahead, csrc shadow counters) are not
    # k-induction-friendly: prove reports spurious UNKNOWNs. bmc from reset is
    # real but bounded. pc_fwd stays prove.
    bmc_checks = {
        "reg_ch0",
        "pc_bwd_ch0",
        "csrc_inc_mcycle_ch0",
        "csrc_upcnt_mcycle_ch0",
        "liveness_ch0",
    }
    sv_read = "read_slang " + " ".join(
        os.path.join(repo, p) for p in CORE_SV
    )

    for fname in sorted(os.listdir(checks_dir)):
        if not fname.endswith(".sby"):
            continue
        path = os.path.join(checks_dir, fname)
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        # Split the read line into read_slang (our SV) + read_verilog (harness).
        content = read_line_re.sub(
            lambda m: f"{sv_read}\nread_verilog -sv {m.group(1)}",
            content,
        )
        # Insn checks hardcode RESET_CYCLES 1 in genchecks; design requires 8.
        content = reset_re.sub("RISCV_FORMAL_RESET_CYCLES 8", content)

        # bmc-mode consistency checks (see note above).
        check = fname[:-4]
        if check in bmc_checks:
            content = content.replace("mode prove", "mode bmc", 1)
            content = re.sub(r"`define RISCV_FORMAL_UNBOUNDED\n", "", content, count=1)

        with open(path, "w", encoding="utf-8") as f:
            f.write(content)

    print(f"==> [m2-gen] post-processed {len(os.listdir(checks_dir))} files in {checks_dir}")
    # Final stdout line: the native checks dir, for scripts/formal_m2.sh to use.
    print(checks_dir)


if __name__ == "__main__":
    main()
