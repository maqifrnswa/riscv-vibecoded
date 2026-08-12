#!/usr/bin/env python3
"""up5k-rv -- RV32I instruction encoder for directed-test vectors.

Use this instead of hand-assembling 32-bit instruction words in testbenches.
Every encoding helper was verified against the decoder (rtl/core/decoder.sv)
and the core RVFI stream (dv/p2/tb_core.sv) in M1 P2 -- hand-assembled
vectors repeatedly produced wrong encodings and cost several debug rounds.

Usage (from a testbench or a Python-driven vector generator):

    from riscv_enc import itype, rtype, branch, load, store, jal, jalr, lui

    prog = [
        (0x0000, itype(0, 0, 1, 5)),          # addi x1, x0, 5
        (0x0004, branch(1, 8, 1, 8)),         # bne  x8, x1, +8
        (0x0010, load(2, 0, 10, 0x100)),      # lw   x10, 0x100(x0)
        (0x0014, store(0, 0, 1, 0x102)),      # sb   x1, 0x102(x0)
        (0x0018, jal(8, 7)),                  # jal  x7, +8
        (0x0040, jalr(7, 0, 0x28)),           # jalr x0, x7, 0x28
        (0x0050, lui(6, 0x12345)),            # lui  x6, 0x12345
    ]

funct3 constants follow the RV32I base ISA:
  R-type  f3: 000 add, 001 sll, 010 slt, 011 sltu, 100 xor, 101 srl, 110 or, 111 and
              (sub/sra: f7 = 0x20)
  I-type  f3: 000 addi, 001 slli, 010 slti, 011 sltiu, 100 xori, 101 srli/srai, 110 ori, 111 andi
  Branch  f3: 000 beq, 001 bne, 100 blt, 101 bge, 110 bltu, 111 bgeu
  Load    f3: 000 lb, 001 lh, 010 lw, 100 lbu, 101 lhu
  Store   f3: 000 sb, 001 sh, 010 sw
"""

FUNCT3_ADD  = 0b000
FUNCT3_SUB  = 0b000  # with f7 = 0x20
FUNCT3_BEQ  = 0b000
FUNCT3_BNE  = 0b001
FUNCT3_BLT  = 0b100
FUNCT3_BGE  = 0b101
FUNCT3_BLTU = 0b110
FUNCT3_BGEU = 0b111
FUNCT3_LB   = 0b000
FUNCT3_LH   = 0b001
FUNCT3_LW   = 0b010
FUNCT3_LBU  = 0b100
FUNCT3_LHU  = 0b101
FUNCT3_SB   = 0b000
FUNCT3_SH   = 0b001
FUNCT3_SW   = 0b010


def _mask32(v):
    return v & 0xFFFFFFFF


def rtype(f3, f7, rs1, rs2, rd):
    """Register-register ALU: add/sub/sll/slt/sltu/xor/srl/sra/or/and."""
    return _mask32((f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33)


def itype(f3, rs1, rd, imm):
    """Immediate ALU / shift (slli, srli, srai use shamt as imm)."""
    return _mask32(((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x13)


def lui(rd, imm20):
    """Load upper immediate."""
    return _mask32(((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37)


def auipc(rd, imm20):
    return _mask32(((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17)


def jal(imm, rd):
    """Unconditional jump with link (imm = byte offset, signed)."""
    return _mask32(
        (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12)
        | (rd << 7) | 0x6F)


def jalr(rs1, rd, imm):
    """Jump register with link (imm = byte offset, signed)."""
    return _mask32(((imm & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67)


def branch(f3, rs1, rs2, imm):
    """Conditional branch (imm = byte offset, signed; must be 2-aligned)."""
    return _mask32(
        (((imm >> 12) & 1) << 31) | (((imm >> 11) & 1) << 7)
        | (((imm >> 5) & 0x3F) << 25) | (((imm >> 1) & 0xF) << 8)
        | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | 0x63)


def load(f3, rs1, rd, imm):
    """Load: lb/lh/lw/lbu/lhu."""
    return _mask32(((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x03)


def store(f3, rs1, rs2, imm):
    """Store: sb/sh/sw."""
    return _mask32(
        (((imm >> 5) & 0x7F) << 25) | ((imm & 0x1F) << 7)
        | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | 0x23)


def fence():
    """fence (0x0f). fence.i = 0x0000100f; ecall = 0x73; ebreak = 0x00100073."""
    return 0x0000000F


if __name__ == "__main__":
    # Self-check against encodings verified by dv/p2 (M1 P2).
    assert itype(0, 0, 1, 5) == 0x00500093        # addi x1, x0, 5
    assert itype(0, 1, 2, 7) == 0x00708113        # addi x2, x1, 7
    assert rtype(0, 0x00, 1, 2, 3) == 0x002081B3  # add x3, x1, x2
    assert rtype(0, 0x20, 3, 1, 4) == 0x40118233  # sub x4, x3, x1
    assert itype(1, 4, 5, 2) == 0x00221293        # slli x5, x4, 2
    assert auipc(6, 0) == 0x00000317              # auipc x6, 0
    assert jal(8, 7) == 0x008003EF                # jal x7, +8
    assert branch(1, 8, 1, 8) == 0x00141463       # bne x8, x1, +8
    assert branch(0, 8, 8, 4) == 0x00840263       # beq x8, x8, +4
    assert store(2, 0, 1, 0x100) == 0x10102023    # sw x1, 0x100(x0)
    assert load(2, 0, 10, 0x100) == 0x10002503    # lw x10, 0x100(x0)
    assert store(0, 0, 1, 0x102) == 0x10100123    # sb x1, 0x102(x0)
    assert load(4, 0, 11, 0x102) == 0x10204583    # lbu x11, 0x102(x0)
    assert load(0, 0, 12, 0x102) == 0x10200603    # lb x12, 0x102(x0)
    assert jalr(7, 0, 0x28) == 0x02838067         # jalr x0, x7, 0x28
    assert itype(0, 0, 13, 0xAA) == 0x0AA00693    # addi x13, x0, 0xaa
    assert lui(6, 0x12345) == 0x12345337          # lui x6, 0x12345
    assert jal(-4, 1) == 0xFFDFF0EF               # jal x1, -4
    print("riscv_enc self-check: PASS")
