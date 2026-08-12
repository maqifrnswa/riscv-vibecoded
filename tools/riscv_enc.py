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


# ---------------------------------------------------------------------------
# RV32C (compressed) encoders.
# Field layouts are reproduced verbatim from the riscv-formal instruction
# models in formal/riscv-formal/insns/insn_c_*.v (the referee). All C encoders
# return the 16-bit instruction zero-extended to a 32-bit word (high 16 bits
# zero), matching what the core's RVFI channel reports for a C instruction.
#
# C layout cheatsheet (insn[15:0]):
#   opcode  = insn[1:0]            (0b00/01/10; 0b11 is reserved/32-bit)
#   funct3  = insn[15:13]  funct4 = insn[15:12]  funct6 = insn[15:10]
#   SPN reg = {1'b1, insn[4:2]} -> x8..x15 ; SP = x2 hardcoded
# ---------------------------------------------------------------------------

C_OPC_QUAD0 = 0b00  # CIW/CL/CB/CS: addi4spn, lw/sw, beqz/bnez, sub/and/or/xor
C_OPC_QUAD1 = 0b01  # CI/CSS/CJ: addi, li, lui, andi, srli/srai, j/jal, lwsp/swsp
C_OPC_QUAD2 = 0b10  # CR/CI: add/mv/jr/jalr, slli


def _spn(r):
    """Map a register 8..15 to its 3-bit compressed SP-number (x8->0 .. x15->7)."""
    if not (8 <= r <= 15):
        raise ValueError("compressed SPN register must be in x8..x15, got %d" % r)
    return r - 8


def _ci_imm(imm):
    """CI-type 6-bit signed immediate: {insn[12], insn[6:2]} (c.addi/c.li/c.andi)."""
    return (((imm >> 5) & 1) << 12) | ((imm & 0x1F) << 2)


def c_cr(funct4, rs1, rs2):
    """Generic CR-type (opcode=0b10): c.add/c.mv/c.jr/c.jalr/c.ebreak."""
    return _mask32((funct4 << 12) | (rs1 << 7) | (rs2 << 2) | C_OPC_QUAD2)


def c_add(rs1, rs2, rd=None):
    """c.add rd, rs1, rs2 (CR). rd and rs1 share one field (must be equal).

    With rs1=rd=0, rs2=0 this reproduces 0x9002 == c.ebreak (the c.add/ebreak
    encoding overlap in insn_c_add.v / insn_c_ebreak: funct4=1001, opcode=10).
    """
    if rd is not None and rd != rs1:
        raise ValueError("c.add rd must equal rs1")
    return c_cr(0x9, rs1, rs2)


def c_mv(rd, rs2):
    """c.mv rd, rs2 (CR, funct4=1000, rs2 != 0)."""
    return c_cr(0x8, rd, rs2)


def c_jr(rs1):
    """c.jr rs1 (CR, funct4=1000, rs2=0)."""
    return c_cr(0x8, rs1, 0)


def c_jalr(rs1):
    """c.jalr rs1 (CR, funct4=1001, rs2=0); rd=x1 hardcoded."""
    return c_cr(0x9, rs1, 0)


def c_ebreak():
    """c.ebreak = 0x9002 (CR funct4=1001, rs1=rd=0, rs2=0)."""
    return c_cr(0x9, 0, 0)


def c_addi(rs1, imm):
    """c.addi rs1, imm (CI, funct3=000, opcode=01)."""
    return _mask32((0b000 << 13) | (rs1 << 7) | _ci_imm(imm) | C_OPC_QUAD1)


def c_li(rd, imm):
    """c.li rd, imm (CI, funct3=010, opcode=01)."""
    return _mask32((0b010 << 13) | (rd << 7) | _ci_imm(imm) | C_OPC_QUAD1)


def c_lui(rd, imm):
    """c.lui rd, imm (CI, funct3=011): imm = $signed({insn[12],insn[6:2]}) << 12."""
    return _mask32(
        (0b011 << 13) | (rd << 7)
        | (((imm >> 17) & 1) << 12) | (((imm >> 12) & 0x1F) << 2)
        | C_OPC_QUAD1)


def c_addi16sp(imm):
    """c.addi16sp sp, imm (CI/SP, funct3=011); rd = sp = x2 hardcoded.
    imm = $signed({insn[12],insn[4:3],insn[5],insn[2],insn[6]}) << 4."""
    return _mask32(
        (0b011 << 13) | (2 << 7)
        | (((imm >> 9) & 1) << 12) | (((imm >> 8) & 1) << 4)
        | (((imm >> 7) & 1) << 3) | (((imm >> 6) & 1) << 5)
        | (((imm >> 5) & 1) << 2) | (((imm >> 4) & 1) << 6)
        | C_OPC_QUAD1)


def c_addi4spn(rd, imm):
    """c.addi4spn rd, imm (CIW, funct3=000, opcode=00); rs1=sp hardcoded.
    imm = {insn[10:7],insn[12:11],insn[5],insn[6],2'b00}."""
    return _mask32(
        (0b000 << 13) | (_spn(rd) << 2)
        | (((imm >> 9) & 1) << 10) | (((imm >> 8) & 1) << 9)
        | (((imm >> 7) & 1) << 8) | (((imm >> 6) & 1) << 7)
        | (((imm >> 5) & 1) << 12) | (((imm >> 4) & 1) << 11)
        | (((imm >> 3) & 1) << 5) | (((imm >> 2) & 1) << 6)
        | C_OPC_QUAD0)


def c_slli(rs1, shamt):
    """c.slli rs1, shamt (CI, funct3=000, opcode=10); shamt={insn[12],insn[6:2]}."""
    return _mask32(
        (0b000 << 13) | (rs1 << 7)
        | (((shamt >> 5) & 1) << 12) | ((shamt & 0x1F) << 2) | C_OPC_QUAD2)


def _c_shift(rs1, funct2, shamt):
    """Shared c.srli/c.srai body (funct3=100, funct2 in insn[11:10], opcode=01)."""
    return _mask32(
        (0b100 << 13) | (funct2 << 10) | (_spn(rs1) << 7)
        | (((shamt >> 5) & 1) << 12) | ((shamt & 0x1F) << 2) | C_OPC_QUAD1)


def c_srli(rs1, shamt):
    """c.srli rs1, shamt (funct2=00)."""
    return _c_shift(rs1, 0b00, shamt)


def c_srai(rs1, shamt):
    """c.srai rs1, shamt (funct2=01)."""
    return _c_shift(rs1, 0b01, shamt)


def c_andi(rs1, imm):
    """c.andi rs1, imm (funct3=100, funct2=10, imm={insn[12],insn[6:2]} signed)."""
    return _mask32(
        (0b100 << 13) | (0b10 << 10) | (_spn(rs1) << 7) | _ci_imm(imm) | C_OPC_QUAD1)


def _c_alu(rs1, rs2, funct2):
    """Shared CS ALU body (funct6=100011, funct2 in insn[6:5], opcode=01)."""
    return _mask32(
        (0b100011 << 10) | (_spn(rs1) << 7) | (funct2 << 5) | (_spn(rs2) << 2)
        | C_OPC_QUAD1)


def c_sub(rs1, rs2):
    """c.sub rd, rs1, rs2 (funct2=00)."""
    return _c_alu(rs1, rs2, 0b00)


def c_xor(rs1, rs2):
    """c.xor rd, rs1, rs2 (funct2=01)."""
    return _c_alu(rs1, rs2, 0b01)


def c_or(rs1, rs2):
    """c.or rd, rs1, rs2 (funct2=10)."""
    return _c_alu(rs1, rs2, 0b10)


def c_and(rs1, rs2):
    """c.and rd, rs1, rs2 (funct2=11)."""
    return _c_alu(rs1, rs2, 0b11)


def _c_cb_imm(imm):
    """CB-type branch immediate:
    {insn[12],insn[6:5],insn[2],insn[11:10],insn[4:3],1'b0}."""
    return (((imm >> 8) & 1) << 12) | (((imm >> 6) & 0x3) << 5) \
        | (((imm >> 5) & 1) << 2) | (((imm >> 3) & 0x3) << 10) \
        | (((imm >> 1) & 0x3) << 3)


def c_beqz(rs1, imm):
    """c.beqz rs1, imm (CB, funct3=110)."""
    return _mask32((0b110 << 13) | (_spn(rs1) << 7) | _c_cb_imm(imm) | C_OPC_QUAD1)


def c_bnez(rs1, imm):
    """c.bnez rs1, imm (CB, funct3=111)."""
    return _mask32((0b111 << 13) | (_spn(rs1) << 7) | _c_cb_imm(imm) | C_OPC_QUAD1)


def _c_cj_imm(imm):
    """CJ-type jump immediate:
    {insn[12],insn[8],insn[10],insn[9],insn[6],insn[7],insn[2],insn[11],
     insn[5],insn[4],insn[3],1'b0}."""
    return (((imm >> 11) & 1) << 12) | (((imm >> 10) & 1) << 8) \
        | (((imm >> 9) & 1) << 10) | (((imm >> 8) & 1) << 9) \
        | (((imm >> 7) & 1) << 6) | (((imm >> 6) & 1) << 7) \
        | (((imm >> 5) & 1) << 2) | (((imm >> 4) & 1) << 11) \
        | (((imm >> 3) & 1) << 5) | (((imm >> 2) & 1) << 4) \
        | (((imm >> 1) & 1) << 3)


def c_j(imm):
    """c.j imm (CJ, funct3=101); rd=x0."""
    return _mask32((0b101 << 13) | _c_cj_imm(imm) | C_OPC_QUAD1)


def c_jal(imm):
    """c.jal imm (CJ, funct3=001); rd=x1 hardcoded (link)."""
    return _mask32((0b001 << 13) | _c_cj_imm(imm) | C_OPC_QUAD1)


def _c_cl_imm(imm):
    """CL-type load/store immediate (byte offset, multiple of 4).

    The model's CL imm is the byte offset: {insn[5],insn[12:10],insn[6],2'b00}.
    The encoder maps the byte offset's bits [6:2] to those insn bits.
    """
    return (((imm >> 6) & 1) << 5) | (((imm >> 5) & 1) << 12) \
        | (((imm >> 4) & 1) << 11) | (((imm >> 3) & 1) << 10) \
        | (((imm >> 2) & 1) << 6)


def c_lw(rs1, rd, imm):
    """c.lw rd, imm(rs1) (CL, funct3=010, opcode=00)."""
    return _mask32(
        (0b010 << 13) | (_spn(rs1) << 7) | _c_cl_imm(imm) | (_spn(rd) << 2)
        | C_OPC_QUAD0)


def c_sw(rs1, rs2, imm):
    """c.sw rs2, imm(rs1) (CL, funct3=110, opcode=00)."""
    return _mask32(
        (0b110 << 13) | (_spn(rs1) << 7) | _c_cl_imm(imm) | (_spn(rs2) << 2)
        | C_OPC_QUAD0)


def c_lwsp(rd, imm):
    """c.lwsp rd, imm(sp) (CI/LSP, funct3=010, opcode=10); rs1=sp hardcoded.
    imm = {insn[3:2],insn[12],insn[6:4],2'b00}."""
    return _mask32(
        (0b010 << 13) | (rd << 7)
        | (((imm >> 7) & 1) << 3) | (((imm >> 6) & 1) << 2)
        | (((imm >> 5) & 1) << 12) | (((imm >> 4) & 1) << 6)
        | (((imm >> 3) & 1) << 5) | (((imm >> 2) & 1) << 4)
        | C_OPC_QUAD2)


def c_swsp(rs2, imm):
    """c.swsp rs2, imm(sp) (CSS, funct3=110, opcode=10); rs1=sp hardcoded.
    imm = {insn[8:7],insn[12:9],2'b00}."""
    return _mask32(
        (0b110 << 13) | (rs2 << 2)
        | (((imm >> 7) & 1) << 8) | (((imm >> 6) & 1) << 7)
        | (((imm >> 5) & 1) << 12) | (((imm >> 4) & 1) << 11)
        | (((imm >> 3) & 1) << 10) | (((imm >> 2) & 1) << 9)
        | C_OPC_QUAD2)


# ---------------------------------------------------------------------------
# RV32M encoders (R-type, opcode 0x33, funct7 = 0000001).
# ---------------------------------------------------------------------------

FUNCT7_M = 0x01  # 0000001


def mop(f3, rs1, rs2, rd):
    """Generic M-extension R-type op."""
    return rtype(f3, FUNCT7_M, rs1, rs2, rd)


def mul(rs1, rs2, rd):
    """mul rd, rs1, rs2 (funct3=000)."""
    return mop(0b000, rs1, rs2, rd)


def mulh(rs1, rs2, rd):
    """mulh rd, rs1, rs2 (funct3=001)."""
    return mop(0b001, rs1, rs2, rd)


def mulhsu(rs1, rs2, rd):
    """mulhsu rd, rs1, rs2 (funct3=010)."""
    return mop(0b010, rs1, rs2, rd)


def mulhu(rs1, rs2, rd):
    """mulhu rd, rs1, rs2 (funct3=011)."""
    return mop(0b011, rs1, rs2, rd)


def div(rs1, rs2, rd):
    """div rd, rs1, rs2 (funct3=100)."""
    return mop(0b100, rs1, rs2, rd)


def divu(rs1, rs2, rd):
    """divu rd, rs1, rs2 (funct3=101)."""
    return mop(0b101, rs1, rs2, rd)


def rem(rs1, rs2, rd):
    """rem rd, rs1, rs2 (funct3=110)."""
    return mop(0b110, rs1, rs2, rd)


def remu(rs1, rs2, rd):
    """remu rd, rs1, rs2 (funct3=111)."""
    return mop(0b111, rs1, rs2, rd)


# ---------------------------------------------------------------------------
# CSR encoders (I-type, opcode 0x73 = 1110011; csr addr in insn[31:20]).
# ---------------------------------------------------------------------------

def csr(f3, csr_addr, rs1_or_zimm, rd):
    """Generic CSR instruction; for *i variants rs1_or_zimm is the zimm field."""
    return _mask32(((csr_addr & 0xFFF) << 20) | ((rs1_or_zimm & 0x1F) << 15)
                   | (f3 << 12) | (rd << 7) | 0x73)


def csrrw(csr_addr, rs1, rd):
    """csrrw rd, csr, rs1 (funct3=001)."""
    return csr(0b001, csr_addr, rs1, rd)


def csrrs(csr_addr, rs1, rd):
    """csrrs rd, csr, rs1 (funct3=010)."""
    return csr(0b010, csr_addr, rs1, rd)


def csrrc(csr_addr, rs1, rd):
    """csrrc rd, csr, rs1 (funct3=011)."""
    return csr(0b011, csr_addr, rs1, rd)


def csrrwi(csr_addr, zimm, rd):
    """csrrwi rd, csr, zimm (funct3=101)."""
    return csr(0b101, csr_addr, zimm, rd)


def csrrsi(csr_addr, zimm, rd):
    """csrrsi rd, csr, zimm (funct3=110)."""
    return csr(0b110, csr_addr, zimm, rd)


def csrrci(csr_addr, zimm, rd):
    """csrrci rd, csr, zimm (funct3=111)."""
    return csr(0b111, csr_addr, zimm, rd)


def ecall():
    """ecall = 0x00000073."""
    return 0x00000073


def ebreak():
    """ebreak = 0x00100073."""
    return 0x00100073


def mret():
    """mret = 0x30200073."""
    return 0x30200073


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
