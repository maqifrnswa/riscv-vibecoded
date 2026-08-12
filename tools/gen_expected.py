#!/usr/bin/env python3
"""up5k-rv -- generate expected RVFI retire tables for iverilog directed tests.

The `dv/p2/tb_core.sv`-style tests check every retirement against an expected
RVFI table (order, insn, pc, rs/rd addr+rdata, mem fields). Hand-computing
those tables produced repeated wrong encodings and values in M1 P2 and M2
P1-4a (the tb_core C-section table was only right once a script generated it).
This tool builds a program from `tools/riscv_enc.py` encoders, emulates the
core's registers/memory, and emits the SV `set_exp(...)` table + memory
preload lines -- the same shape tb_core.sv uses.

Usage (from the repo root):
    python3 tools/gen_expected.py        # prints the set_exp table + preload
    python3 tools/gen_expected.py > /tmp/tbl.txt

The program, initial register/memory state, and the retire-count bound live in
`build_program()` -- edit those for a new test; the semantics handlers below
cover the RV32I + RV32C subset used so far. The output has been diffed against
the committed tb_core.sv C-section entries (order 19..47) to pin the emulation.

Note: this generates iverilog-directed-test tables. The M3 golden-DV goes the
cocotb/Verilator route (design.md D15), which is a different harness.
"""

import sys

sys.path.insert(0, "tools")
import riscv_enc as e


def m32(v):
    return v & 0xFFFFFFFF


def build_program():
    """(addr, word, kind, args...) list + initial regs/mem + retire bound.

    kind selects the RVFI computation in the emulation loop below. The operands
    are the known semantic values (registers/immediates); riscv_enc provides
    the words. Start register state is whatever the earlier program left.
    """
    regs = [0] * 32
    regs[1] = 0x1C; regs[2] = 12; regs[3] = 17; regs[4] = 12; regs[5] = 48
    regs[6] = 0x14; regs[7] = 0x1C; regs[10] = 5; regs[11] = 5; regs[12] = 5
    regs[13] = 0xAA; regs[14] = 5
    mem = {0x100: 0x00050005}

    prog = []
    def P(addr, word, kind, *args):
        prog.append((addr, word, kind, args))

    # sp setup (32-bit)
    P(0x54, e.lui(2, 0x10),        "lui",    2, 0x10000)
    P(0x58, e.itype(0, 2, 2, 0x200), "addi", 2, 2, 0x200)
    # base setup (32-bit): x8 = 0x100 (c.lw/c.sw base; CL imm max = 124)
    P(0x5C, e.itype(0, 0, 8, 0x100), "addi", 8, 0, 0x100)
    # C section
    P(0x60, e.c_li(14, 10),    "cli",    14, 10)
    P(0x62, e.c_li(15, 20),    "cli",    15, 20)
    P(0x64, e.c_add(14, 15),   "cadd",   14, 15)
    P(0x66, e.c_sub(14, 15),   "csub",   14, 15)
    P(0x68, e.c_slli(14, 2),   "cslli",  14, 2)
    P(0x6A, e.c_andi(14, -4),  "candi",  14, -4)
    P(0x6C, e.c_mv(17, 14),    "cmv",    17, 14)
    P(0x6E, e.c_beqz(14, 2),   "cbeqz",  14, 2)
    P(0x70, e.c_bnez(14, 4),   "cbnez",  14, 4)
    P(0x72, e.c_li(18, -3),    "cli",    18, -3)
    P(0x74, e.c_swsp(14, 4),   "cswsp",  14, 4)
    P(0x76, e.c_lwsp(20, 4),   "clwsp",  20, 4)
    P(0x78, e.c_lw(8, 13, 0),  "clw",    8, 13, 0)
    P(0x7A, e.c_sw(8, 14, 4),  "csw",    8, 14, 4)
    P(0x7C, e.c_addi(14, -1),  "caddi",  14, -1)
    P(0x7E, e.c_srai(14, 2),   "csrai",  14, 2)
    P(0x80, e.c_xor(14, 15),   "cxor",   14, 15)
    P(0x82, e.c_or(14, 15),    "cor",    14, 15)
    P(0x84, e.c_and(14, 15),   "cand",   14, 15)
    P(0x86, e.c_srli(14, 2),   "csrli",  14, 2)
    P(0x88, e.c_slli(14, 3),   "cslli",  14, 3)
    P(0x8A, e.c_jal(4),        "cjal",   4)
    P(0x8C, e.c_li(18, -3),    "cli",    18, -3)
    P(0x8E, e.c_li(18, 7),     "cli",    18, 7)
    P(0x90, e.c_jr(1),         "cjr",    1)
    return prog, regs, mem


def arith(op, a, b):
    return {"add": lambda: m32(a + b), "sub": lambda: m32(a - b),
            "xor": lambda: a ^ b, "or": lambda: a | b, "and": lambda: a & b,
            "sll": lambda: m32(a << b), "srl": lambda: a >> b,
            "sra": lambda: (a >> b) if a < 0x80000000
                    else (((a >> b) & 0x7FFFFFFF) | (0xFFFFFFFF << (32 - b)) if b else a)}[op]()


def emulate(prog, regs, mem, start_pc, order0, max_retires):
    """Run the program, returning (retires, final regs/mem).

    Each retire: (insn, pc_rdata, pc_wdata, rs1a, rs1d, rs2a, rs2d,
    rda, rdw, mem_addr, rmask, wmask, mem_rdata, mem_wdata). Skips unreached
    instructions naturally (control-flow redirects change pc).
    """
    pc_map = {a: (w, k, a_) for a, w, k, a_ in prog}
    ret = []
    pc = start_pc
    while len(ret) < max_retires:
        w, k, a_ = pc_map[pc]
        r1a = r2a = rda = 0; r1d = r2d = rdw = 0
        ma = rm = wm = mrd = mwd = 0; pcw = None
        if k == "lui":
            rda, rdw = a_[0], a_[1]; pcw = pc + 4
            # RVFI raw-field convention: rs1_addr = insn[19:15] (part of the
            # immediate), rs1_rdata = the pre-state value at that address.
            r1a = (w >> 15) & 0x1F; r1d = regs[r1a]
        elif k == "addi":
            r1a = a_[1]; r1d = regs[r1a]; rda = a_[0]
            rdw = m32(regs[r1a] + a_[2]); pcw = pc + 4
        elif k == "cli":
            rda = a_[0]; rdw = m32(a_[1]); pcw = pc + 2
        elif k == "cadd":
            r1a = rda = a_[0]; r2a = a_[1]; r1d = regs[r1a]; r2d = regs[r2a]
            rdw = m32(regs[r1a] + regs[r2a]); pcw = pc + 2
        elif k == "csub":
            r1a = rda = a_[0]; r2a = a_[1]; r1d = regs[r1a]; r2d = regs[r2a]
            rdw = m32(regs[r1a] - regs[r2a]); pcw = pc + 2
        elif k == "cslli":
            r1a = rda = a_[0]; r1d = regs[r1a]
            rdw = m32(regs[r1a] << a_[1]); pcw = pc + 2
        elif k == "csrli":
            r1a = rda = a_[0]; r1d = regs[r1a]
            rdw = regs[r1a] >> a_[1]; pcw = pc + 2
        elif k == "csrai":
            r1a = rda = a_[0]; r1d = regs[r1a]
            rdw = (regs[r1a] >> a_[1]) if regs[r1a] < 0x80000000 else \
                (((regs[r1a] >> a_[1]) & 0x7FFFFFFF) | (0xFFFFFFFF << (32 - a_[1])))
            pcw = pc + 2
        elif k == "candi":
            r1a = rda = a_[0]; r1d = regs[r1a]
            rdw = regs[r1a] & m32(a_[1]); pcw = pc + 2
        elif k == "cmv":
            r2a = a_[1]; r2d = regs[r2a]; rda = a_[0]; rdw = regs[r2a]; pcw = pc + 2
        elif k in ("cbeqz", "cbnez"):
            r1a = a_[0]; r1d = regs[r1a]
            cond = (regs[r1a] == 0) if k == "cbeqz" else (regs[r1a] != 0)
            pcw = (pc + a_[1]) if cond else (pc + 2)
        elif k == "cswsp":
            r1a = 2; r1d = regs[2]; r2a = a_[0]; r2d = regs[r2a]
            addr = regs[2] + a_[1]
            ma = addr & ~3; wm = 0xF; mwd = regs[r2a]; pcw = pc + 2
        elif k == "clwsp":
            r1a = 2; r1d = regs[2]; rda = a_[0]
            addr = regs[2] + a_[1]
            ma = addr & ~3; rm = 0xF; rdw = mem[ma]; mrd = mem[ma]; pcw = pc + 2
        elif k == "clw":
            r1a = a_[0]; r1d = regs[r1a]; rda = a_[1]
            addr = regs[r1a] + a_[2]
            ma = addr & ~3; rm = 0xF; rdw = mem[ma]; mrd = mem[ma]; pcw = pc + 2
        elif k == "csw":
            r1a = a_[0]; r1d = regs[r1a]; r2a = a_[1]; r2d = regs[r2a]
            addr = regs[r1a] + a_[2]
            ma = addr & ~3; wm = 0xF; mwd = regs[r2a]; pcw = pc + 2
        elif k == "caddi":
            r1a = rda = a_[0]; r1d = regs[r1a]
            rdw = m32(regs[r1a] + a_[1]); pcw = pc + 2
        elif k in ("cxor", "cor", "cand"):
            r1a = rda = a_[0]; r2a = a_[1]; r1d = regs[r1a]; r2d = regs[r2a]
            rdw = arith(k[1:], regs[r1a], regs[r2a]); pcw = pc + 2
        elif k == "cjal":
            rda = 1; rdw = pc + 2; pcw = pc + a_[0]
        elif k == "cjr":
            r1a = a_[0]; r1d = regs[r1a]; pcw = regs[r1a] & ~1
        else:
            raise ValueError("unknown kind: %s" % k)
        ret.append((w, pc, pcw, r1a, r1d, r2a, r2d, rda, rdw, ma, rm, wm, mrd, mwd))
        if rda:
            regs[rda] = rdw
        if wm:
            mem[ma] = mwd
        pc = pcw
    return ret


def emit_sv(prog, ret, order0):
    print("// generated by tools/gen_expected.py (order %d..%d)" %
          (order0, order0 + len(ret) - 1))
    for i, (w, pc, pcw, r1a, r1d, r2a, r2d, rda, rdw, ma, rm, wm, mrd, mwd) in enumerate(ret):
        o = order0 + i
        print("    set_exp(%d, 32'h%08x, 32'h%08x, 32'h%08x, 5'd%d, 32'h%08x, 5'd%d, 32'h%08x," %
              (o, w, pc, pcw, r1a, r1d, r2a, r2d))
        print("             5'd%d, 32'h%08x, 32'h%08x, 4'h%x, 4'h%x, 32'h%08x, 32'h%08x);" %
              (rda, rdw, ma, rm, wm, mrd, mwd))

    print("// preload words:")
    preload = {}
    for a, w, k, _ in prog:
        idx = a >> 2
        if k in ("lui", "addi"):
            preload[idx] = w                 # 32-bit instruction fills the word
        elif (a & 3) == 0:
            preload.setdefault(idx, 0)
            preload[idx] = (preload[idx] & 0xFFFF0000) | (w & 0xFFFF)
        else:
            preload.setdefault(idx, 0)
            preload[idx] = (preload[idx] & 0x0000FFFF) | ((w & 0xFFFF) << 16)
    for idx in sorted(preload):
        print("    mem[0x%04x >> 2] = 32'h%08x;  // word @0x%04x" %
              (idx << 2, preload[idx], idx << 2))


def main() -> int:
    prog, regs, mem = build_program()
    # The tb_core C-extension section runs after 19 earlier retires; the
    # program here covers 3 setup + 26 C instructions.
    ret = emulate(prog, regs, mem, start_pc=0x54, order0=19, max_retires=29)
    assert len(ret) == 29, len(ret)
    emit_sv(prog, ret, order0=19)
    return 0


if __name__ == "__main__":
    sys.exit(main())
