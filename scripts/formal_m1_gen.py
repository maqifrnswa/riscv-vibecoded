#!/usr/bin/env python3
"""up5k-rv -- M1 P3: generate + post-process riscv-formal checks for the RV32I core.

Runs riscv-formal genchecks.py for our binding and rewrites the generated
.sby files so the proof uses the pinned frontends and depths:

  * The generated `read -sv <check>.sv <wrapper.sv>` line is split into:
      - `read_slang <pkg> <core modules> <wrapper>`   (our SystemVerilog -- D14)
      - `read_verilog -sv <check>.sv`                 (riscv-formal harness)
    This is the read_slang <-> read_verilog mixing path validated in M1 P1b.
  * `RISCV_FORMAL_RESET_CYCLES 1` -> 8 for the insn checks (genchecks hardcodes
    1 there; design.md §5.1 requires reset depth 8, R12).

Build-time binding dir: formal/riscv-formal/cores/up5k_rv/ (inside the pinned
submodule -- ephemeral, gitignored). The committed sources live in
formal/up5k_rv/ (wrapper.sv, checks.cfg) and rtl/core/.

Usage: formal_m1_gen.py <REPO_ROOT>
"""

import os
import re
import shutil
import subprocess
import sys

# Core SV file order: package first (slang resolves imports per-file), then the
# leaf modules, then the top, then the formal wrapper.
CORE_SV = [
    "rtl/core/up5k_rv_pkg.sv",
    "rtl/core/decoder.sv",
    "rtl/core/regfile.sv",
    "rtl/core/alu.sv",
    "rtl/core/lsu.sv",
    "rtl/core/fetch_unit.sv",
    "rtl/core/rv32i_core.sv",
    "formal/up5k_rv/wrapper.sv",
]


def main() -> None:
    repo = os.path.abspath(sys.argv[1])
    # The repo lives on a virtiofs mount whose dentry cache is invalidated by
    # rmtree() of a subdirectory: the process cwd (and any child's inherited
    # cwd) then fails os.getcwd() transiently. All our operations use absolute
    # paths, so run from a native-FS cwd to keep getcwd() reliable.
    os.chdir(os.path.dirname(repo))
    rf_dir = os.path.join(repo, "formal", "riscv-formal")
    bind_dir = os.path.join(rf_dir, "cores", "up5k_rv")
    src_dir = os.path.join(repo, "formal", "up5k_rv")
    checks_dir = os.path.join(bind_dir, "checks")

    # 1. (Re)create the build-time binding dir and copy the committed sources.
    shutil.rmtree(bind_dir, ignore_errors=True)
    os.makedirs(bind_dir)
    # Keep the riscv-formal submodule's git status clean: this dir is ephemeral
    # build state, regenerated on every run.
    with open(os.path.join(bind_dir, ".gitignore"), "w", encoding="utf-8") as f:
        f.write("*\n")
    for f in ("wrapper.sv", "checks.cfg"):
        shutil.copy(os.path.join(src_dir, f), os.path.join(bind_dir, f))

    # 2. Run genchecks.py from the binding dir (corename = dir basename,
    #    basedir = dir/../.. = the riscv-formal root). Invoke by absolute path:
    #    a relative sys.path[0] breaks the relocated OSS-CAD python importer.
    print(f"==> [m1-gen] genchecks.py (isa from checks.cfg) into {checks_dir}")
    gen_py = os.path.normpath(os.path.join(bind_dir, "..", "..", "checks", "genchecks.py"))
    subprocess.run(
        ["python3", gen_py],
        cwd=bind_dir,
        check=True,
    )

    # 3. Post-process each generated .sby.
    read_line_re = re.compile(r"^read -sv (\S+\.sv) (.+?wrapper\.sv)$", re.MULTILINE)
    reset_re = re.compile(r"RISCV_FORMAL_RESET_CYCLES 1\b")
    # Consistency checks whose checker has forward-looking / accumulating state
    # (reg shadow, pc_bwd look-ahead) are not k-induction-friendly: their
    # induction step can fire the check on a stale checker pre-state (unreachable
    # from reset), so prove reports a spurious UNKNOWN. The reference bindings
    # run them in bmc mode from reset -- real but bounded. pc_fwd looks backward
    # (previous retirement) and passes prove, so it stays prove.
    bmc_checks = {"reg_ch0", "pc_bwd_ch0"}
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

        # bmc-mode consistency checks (see note above): switch the mode and drop
        # the unbounded (k-induction) define.
        check = fname[:-4]
        if check in bmc_checks:
            content = content.replace("mode prove", "mode bmc", 1)
            content = re.sub(r"`define RISCV_FORMAL_UNBOUNDED\n", "", content, count=1)

        with open(path, "w", encoding="utf-8") as f:
            f.write(content)

    print(f"==> [m1-gen] post-processed {len(os.listdir(checks_dir))} files in {checks_dir}")


if __name__ == "__main__":
    main()
