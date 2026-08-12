// up5k-rv -- M2 P1-1 testbench for decoder.sv (RV32I + RV32C + M + Zicsr).
//
// Directed, self-checking: one (or few) representative encoding per supported
// instruction plus the edge cases that define the NOP/illegal boundary. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_decoder rtl/core/up5k_rv_pkg.sv \
//     rtl/core/decoder.sv dv/p2/tb_decoder.sv && vvp build/tb_decoder
// Expected: "PASS tb_decoder", exit 0.
//
// M2 changes vs M1: unsupported/reserved encodings are `is_illegal` (trap)
// instead of `is_nop`; ecall/ebreak/mret/csr are classified; C and M
// encodings decode to the same control bundle as their 32-bit counterparts.

module tb_decoder;

  import up5k_rv_pkg::*;

  logic [31:0] insn;

  logic [ 4:0] rs1_addr;
  logic [ 4:0] rs2_addr;
  logic [ 4:0] rd_addr;
  logic        rd_we;
  logic [31:0] imm;
  alu_a_sel_e  alu_a_sel;
  alu_b_sel_e  alu_b_sel;
  alu_op_e     alu_op;
  logic [ 2:0] branch_funct3;
  logic        is_branch;
  logic        is_jal;
  logic        is_jalr;
  logic        is_load;
  logic        is_store;
  logic [ 2:0] lsu_funct3;
  logic        is_nop;
  logic        is_c;
  logic        is_csr;
  logic [11:0] csr_addr;
  csr_op_e     csr_op;
  logic        csr_imm;
  logic        is_ecall;
  logic        is_ebreak;
  logic        is_mret;
  logic        is_illegal;

  int fail_count = 0;

  decoder u_dut (
    .insn_i         (insn),
    .rs1_addr_o     (rs1_addr),
    .rs2_addr_o     (rs2_addr),
    .rd_addr_o      (rd_addr),
    .rd_we_o        (rd_we),
    .imm_o          (imm),
    .alu_a_sel_o    (alu_a_sel),
    .alu_b_sel_o    (alu_b_sel),
    .alu_op_o       (alu_op),
    .branch_funct3_o(branch_funct3),
    .is_branch_o    (is_branch),
    .is_jal_o       (is_jal),
    .is_jalr_o      (is_jalr),
    .is_load_o      (is_load),
    .is_store_o     (is_store),
    .lsu_funct3_o   (lsu_funct3),
    .is_nop_o       (is_nop),
    .is_c_o         (is_c),
    .is_csr_o       (is_csr),
    .csr_addr_o     (csr_addr),
    .csr_op_o       (csr_op),
    .csr_imm_o      (csr_imm),
    .is_ecall_o     (is_ecall),
    .is_ebreak_o    (is_ebreak),
    .is_mret_o      (is_mret),
    .is_illegal_o   (is_illegal)
  );

  // ---- check helpers ---------------------------------------------------------

  task automatic check32(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check5(logic [4:0] got, logic [4:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %05b exp %05b", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check3(logic [2:0] got, logic [2:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %03b exp %03b", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_bit(logic got, logic exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %b exp %b", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_enum(int got, int exp, string name);
    if (got != exp) begin
      $display("FAIL %s: got %0d exp %0d", name, got, exp);
      fail_count++;
    end
  endtask

  // Drive a fresh instruction and let the combinational logic settle.
  task automatic dec(logic [31:0] word);
    insn = word;
    #1;
  endtask

  // Check the "not a trap, not a NOP, executes" precondition for valid insns.
  task automatic exec_ok(string name);
    check_bit(is_nop,     1'b0, {name, " nop"});
    check_bit(is_illegal, 1'b0, {name, " illegal"});
    check_bit(is_ecall,   1'b0, {name, " ecall"});
    check_bit(is_ebreak,  1'b0, {name, " ebreak"});
    check_bit(is_mret,    1'b0, {name, " mret"});
  endtask

  // ---- tests -----------------------------------------------------------------

  initial begin
    insn = 32'd0;
    #1;

    // ==== RV32I (M1, expectations updated for M2 trap classification) =========

    // addi x1, x2, -1  (imm 0xfff sign-extended)
    dec(32'hfff1_0093);
    check5 (rs1_addr, 5'd2,  "addi rs1");
    check5 (rd_addr,  5'd1,  "addi rd");
    check32(imm,      32'hffff_ffff, "addi imm");
    check_bit(rd_we,  1'b1,  "addi rd_we");
    check_enum(alu_op, ALU_ADD, "addi alu_op");
    check_bit(is_c, 1'b0, "addi is_c");
    exec_ok("addi");

    // slti x5, x1, -8
    dec(32'hff80_a293);
    check_enum(alu_op, ALU_SLT, "slti alu_op");
    check32(imm, 32'hffff_fff8, "slti imm");

    // sltiu x5, x1, 100
    dec(32'h0640_b293);
    check_enum(alu_op, ALU_SLTU, "sltiu alu_op");

    // xori x4, x3, 0xabc
    dec(32'h0551_c213);
    check_enum(alu_op, ALU_XOR, "xori alu_op");

    // ori x4, x3, -1
    dec(32'hfff1_e213);
    check_enum(alu_op, ALU_OR, "ori alu_op");

    // andi x4, x3, 0x1ff
    dec(32'h1ff1_f213);
    check_enum(alu_op, ALU_AND, "andi alu_op");

    // slli x4, x1, 5
    dec(32'h0050_9093);
    check_enum(alu_op, ALU_SLL, "slli alu_op");
    check32(imm, 32'd5, "slli imm");

    // srli / srai
    dec(32'h0050_d093);
    check_enum(alu_op, ALU_SRL, "srli alu_op");
    dec(32'h4050_d093);
    check_enum(alu_op, ALU_SRA, "srai alu_op");

    // slli with invalid funct7 -> illegal
    dec(32'h4050_9093);
    check_bit(is_illegal, 1'b1, "slli bad funct7 illegal");
    check_bit(rd_we,      1'b0, "slli bad funct7 rd_we");

    // srli with invalid funct7 -> illegal
    dec(32'h2050_d093);
    check_bit(is_illegal, 1'b1, "srli bad funct7 illegal");

    // add / sub
    dec(32'h0020_81b3);
    check5 (rs1_addr, 5'd1, "add rs1");
    check5 (rs2_addr, 5'd2, "add rs2");
    check5 (rd_addr,  5'd3, "add rd");
    check_enum(alu_op, ALU_ADD, "add alu_op");
    check_enum(alu_b_sel, OPB_RS2, "add alu_b RS2");
    exec_ok("add");
    dec(32'h4020_81b3);
    check_enum(alu_op, ALU_SUB, "sub alu_op");

    // sll/slt/sltu/xor/srl/sra/or/and
    dec(32'h0020_91b3); check_enum(alu_op, ALU_SLL, "sll alu_op");
    dec(32'h0020_a1b3); check_enum(alu_op, ALU_SLT, "slt alu_op");
    dec(32'h0020_b1b3); check_enum(alu_op, ALU_SLTU, "sltu alu_op");
    dec(32'h0020_c1b3); check_enum(alu_op, ALU_XOR, "xor alu_op");
    dec(32'h0020_d1b3); check_enum(alu_op, ALU_SRL, "srl alu_op");
    dec(32'h4020_d1b3); check_enum(alu_op, ALU_SRA, "sra alu_op");
    dec(32'h0020_e1b3); check_enum(alu_op, ALU_OR, "or alu_op");
    dec(32'h0020_f1b3); check_enum(alu_op, ALU_AND, "and alu_op");

    // invalid funct7 in OP -> illegal
    dec(32'h1020_81b3);
    check_bit(is_illegal, 1'b1, "op bad funct7 illegal");

    // reserved 0100000 in OP with a non-sub/sra funct3 -> illegal
    dec(32'h4020_91b3);  // funct7=0100000, funct3=001 (SLL)
    check_bit(is_illegal, 1'b1, "op 0100000 sll illegal");
    dec(32'h4020_8033);  // sub x0,x1,x0 stays legal
    check_bit(is_illegal, 1'b0, "sub legal");
    check_enum(alu_op, ALU_SUB, "sub alu_op");

    // lui / auipc
    dec(32'h1234_5337);
    check_enum(alu_a_sel, OPA_X0,  "lui alu_a X0");
    check_enum(alu_b_sel, OPB_UIMM, "lui alu_b UIMM");
    check32(imm, 32'h1234_5000, "lui imm");
    dec(32'h0000_1397);
    check_enum(alu_a_sel, OPA_PC, "auipc alu_a PC");
    check32(imm, 32'h0000_1000, "auipc imm");

    // jal / jalr
    dec(32'h0040_00ef);
    check_bit(is_jal, 1'b1, "jal is_jal");
    check5 (rd_addr, 5'd1, "jal rd");
    check32(imm, 32'd4, "jal imm");
    dec(32'h0001_00e7);
    check_bit(is_jalr, 1'b1, "jalr is_jalr");
    check5 (rs1_addr, 5'd2, "jalr rs1");
    dec(32'h0011_60e7);
    check_bit(is_illegal, 1'b1, "jalr bad funct3 illegal");
    check_bit(is_jalr,    1'b0, "jalr bad funct3 not jalr");

    // branches
    dec(32'h0020_8263);
    check_bit(is_branch, 1'b1, "beq is_branch");
    check3 (branch_funct3, FUNCT3_BEQ, "beq funct3");
    check5 (rd_addr, 5'd0, "beq rd_addr forced 0");
    dec(32'h0020_9263); check3 (branch_funct3, FUNCT3_BNE, "bne funct3");
    dec(32'h0020_c263); check3 (branch_funct3, FUNCT3_BLT, "blt funct3");
    dec(32'h0020_d263); check3 (branch_funct3, FUNCT3_BGE, "bge funct3");
    dec(32'h0020_e263); check3 (branch_funct3, FUNCT3_BLTU, "bltu funct3");
    dec(32'h0020_f263); check3 (branch_funct3, FUNCT3_BGEU, "bgeu funct3");
    dec(32'h0020_a063);
    check_bit(is_illegal, 1'b1, "branch bad funct3 illegal");

    // loads / stores
    dec(32'h0000_8403);
    check_bit(is_load, 1'b1, "lb is_load");
    check3 (lsu_funct3, FUNCT3_LB, "lb lsu_funct3");
    dec(32'h0040_9483); check3 (lsu_funct3, FUNCT3_LH, "lh lsu_funct3");
    dec(32'hff80_a503); check3 (lsu_funct3, FUNCT3_LW, "lw lsu_funct3");
    dec(32'h0000_c583); check3 (lsu_funct3, FUNCT3_LBU, "lbu lsu_funct3");
    dec(32'h0000_d603); check3 (lsu_funct3, FUNCT3_LHU, "lhu lsu_funct3");
    dec(32'h0000_b483);
    check_bit(is_illegal, 1'b1, "load bad funct3 illegal");

    dec(32'h0020_8023);
    check_bit(is_store, 1'b1, "sb is_store");
    check3 (lsu_funct3, FUNCT3_SB, "sb lsu_funct3");
    dec(32'h0020_9323); check3 (lsu_funct3, FUNCT3_SH, "sh lsu_funct3");
    dec(32'hfe20_ae23); check3 (lsu_funct3, FUNCT3_SW, "sw lsu_funct3");
    dec(32'h0020_b023);
    check_bit(is_illegal, 1'b1, "store bad funct3 illegal");

    // fence / fence.i remain NOPs
    dec(32'h0000_000f);
    check_bit(is_nop, 1'b1, "fence nop");
    check_bit(rd_we,  1'b0, "fence rd_we");
    dec(32'h0000_100f);
    check_bit(is_nop, 1'b1, "fence.i nop");

    // ecall / ebreak / mret / wfi
    dec(32'h0000_0073);
    check_bit(is_ecall, 1'b1, "ecall is_ecall");
    check_bit(is_nop,   1'b0, "ecall not nop");
    dec(32'h0010_0073);
    check_bit(is_ebreak, 1'b1, "ebreak is_ebreak");
    dec(32'h3020_0073);
    check_bit(is_mret, 1'b1, "mret is_mret");
    dec(32'h1050_0073);
    check_bit(is_nop, 1'b1, "wfi nop");

    // reserved SYSTEM funct12 -> illegal
    dec(32'h0020_0073);
    check_bit(is_illegal, 1'b1, "sys bad funct12 illegal");

    // unknown opcode -> illegal
    dec(32'hffff_ffff);
    check_bit(is_illegal, 1'b1, "unknown opcode illegal");
    check_bit(is_nop,     1'b0, "unknown opcode not nop");

    // ==== M-extension (ALTOPS fake ops, D18) ====================================

    dec(32'h0220_81b3);  // mul  x3, x1, x2
    check5 (rs1_addr, 5'd1, "mul rs1");
    check5 (rs2_addr, 5'd2, "mul rs2");
    check5 (rd_addr,  5'd3, "mul rd");
    check_bit(rd_we,  1'b1, "mul rd_we");
    check_enum(alu_op, ALU_MUL_ALT, "mul alu_op");
    check_enum(alu_b_sel, OPB_RS2, "mul alu_b RS2");
    exec_ok("mul");
    dec(32'h0220_91b3); check_enum(alu_op, ALU_MULH_ALT,  "mulh alu_op");
    dec(32'h0220_a1b3); check_enum(alu_op, ALU_MULHSU_ALT, "mulhsu alu_op");
    dec(32'h0220_b1b3); check_enum(alu_op, ALU_MULHU_ALT,  "mulhu alu_op");
    dec(32'h0220_c1b3); check_enum(alu_op, ALU_DIV_ALT,    "div alu_op");
    dec(32'h0220_d1b3); check_enum(alu_op, ALU_DIVU_ALT,   "divu alu_op");
    dec(32'h0220_e1b3); check_enum(alu_op, ALU_REM_ALT,    "rem alu_op");
    dec(32'h0220_f1b3); check_enum(alu_op, ALU_REMU_ALT,   "remu alu_op");

    // ==== C-extension =============================================================

    // -- quad0 (op=00): c.addi4spn / c.lw / c.sw
    dec(32'h0000_0044);  // c.addi4spn x9, sp, 4
    check_bit(is_c,    1'b1, "addi4spn is_c");
    check5 (rs1_addr,  5'd2, "addi4spn rs1=sp");
    check5 (rd_addr,   5'd9, "addi4spn rd");
    check32(imm,       32'd4, "addi4spn imm");
    check_enum(alu_a_sel, OPA_RS1, "addi4spn alu_a RS1");
    check_enum(alu_b_sel, OPB_IMM, "addi4spn alu_b IMM");
    check_enum(alu_op, ALU_ADD, "addi4spn alu_op");
    exec_ok("addi4spn");

    dec(32'h0000_0004);  // c.addi4spn imm==0 -> hint NOP
    check_bit(is_nop, 1'b1, "addi4spn imm0 hint");
    check_bit(rd_we,  1'b0, "addi4spn imm0 rd_we");

    dec(32'h0000_4044);  // c.lw x9, 4(x8)
    check_bit(is_c, 1'b1, "c_lw is_c");
    check5 (rs1_addr, 5'd8, "c_lw rs1");
    check5 (rd_addr,  5'd9, "c_lw rd");
    check32(imm, 32'd4, "c_lw imm");
    check3 (lsu_funct3, FUNCT3_LW, "c_lw lsu_funct3");
    check_bit(is_load, 1'b1, "c_lw is_load");
    check_bit(rd_we,   1'b1, "c_lw rd_we");

    dec(32'h0000_c044);  // c.sw x8, x9, 4
    check5 (rs1_addr, 5'd8, "c_sw rs1");
    check5 (rs2_addr, 5'd9, "c_sw rs2");
    check32(imm, 32'd4, "c_sw imm");
    check3 (lsu_funct3, FUNCT3_SW, "c_sw lsu_funct3");
    check_bit(is_store, 1'b1, "c_sw is_store");
    check_bit(rd_we,    1'b0, "c_sw rd_we");

    dec(32'h0000_2000);  // quad0 reserved funct3=001
    check_bit(is_illegal, 1'b1, "quad0 f3 001 illegal");

    // -- quad1 (op=01)
    dec(32'h0000_12fd);  // c.addi x5, -1
    check5 (rs1_addr, 5'd5, "c_addi rs1");
    check5 (rd_addr,  5'd5, "c_addi rd");
    check32(imm, 32'hffff_ffff, "c_addi imm");
    check_enum(alu_op, ALU_ADD, "c_addi alu_op");
    exec_ok("c_addi");

    dec(32'h0000_0001);  // c.addi x0, 0 (c.nop) executes (model-valid)
    check5 (rd_addr, 5'd0, "c_nop rd");
    check_bit(rd_we, 1'b1, "c_nop rd_we");
    check_bit(is_nop, 1'b0, "c_nop not nop");

    dec(32'h0000_2011);  // c.jal +4
    check_bit(is_jal, 1'b1, "c_jal is_jal");
    check5 (rd_addr,  5'd1, "c_jal rd");
    check_bit(rd_we,  1'b1, "c_jal rd_we");
    check32(imm, 32'd4, "c_jal imm");

    dec(32'h0000_5379);  // c.li x6, -2
    check5 (rd_addr, 5'd6, "c_li rd");
    check32(imm, 32'hffff_fffe, "c_li imm");
    check_enum(alu_a_sel, OPA_X0, "c_li alu_a X0");

    dec(32'h0000_6385);  // c.lui x7, 0x1000
    check5 (rd_addr, 5'd7, "c_lui rd");
    check32(imm, 32'h0000_1000, "c_lui imm");
    check_enum(alu_a_sel, OPA_X0, "c_lui alu_a X0");
    dec(32'h0000_6381);  // c.lui imm==0 -> hint NOP
    check_bit(is_nop, 1'b1, "c_lui imm0 hint");

    dec(32'h0000_6141);  // c.addi16sp sp, 16
    check5 (rs1_addr, 5'd2, "c_addi16sp rs1=sp");
    check5 (rd_addr,  5'd2, "c_addi16sp rd=sp");
    check32(imm, 32'd16, "c_addi16sp imm");
    dec(32'h0000_6101);  // c.addi16sp imm==0 -> hint NOP
    check_bit(is_nop, 1'b1, "c_addi16sp imm0 hint");

    dec(32'h0000_800d);  // c.srli x8, 3
    check5 (rs1_addr, 5'd8, "c_srli rs1");
    check32(imm, 32'd3, "c_srli shamt");
    check_enum(alu_op, ALU_SRL, "c_srli alu_op");
    dec(32'h0000_840d);  // c.srai x8, 3
    check_enum(alu_op, ALU_SRA, "c_srai alu_op");

    dec(32'h0000_9871);  // c.andi x8, -4
    check5 (rs1_addr, 5'd8, "c_andi rs1");
    check32(imm, 32'hffff_fffc, "c_andi imm");
    check_enum(alu_op, ALU_AND, "c_andi alu_op");

    dec(32'h0000_8c05);  // c.sub x8, x9
    check5 (rs1_addr, 5'd8, "c_sub rs1");
    check5 (rs2_addr, 5'd9, "c_sub rs2");
    check5 (rd_addr,  5'd8, "c_sub rd");
    check_enum(alu_op, ALU_SUB, "c_sub alu_op");
    dec(32'h0000_8c25); check_enum(alu_op, ALU_XOR, "c_xor alu_op");
    dec(32'h0000_8c45); check_enum(alu_op, ALU_OR,  "c_or alu_op");
    dec(32'h0000_8c65); check_enum(alu_op, ALU_AND, "c_and alu_op");

    dec(32'h0000_a011);  // c.j +4
    check_bit(is_jal, 1'b1, "c_j is_jal");
    check_bit(rd_we,  1'b0, "c_j rd_we");
    check32(imm, 32'd4, "c_j imm");

    dec(32'h0000_c011);  // c.beqz x8, +4
    check_bit(is_branch, 1'b1, "c_beqz is_branch");
    check3 (branch_funct3, FUNCT3_BEQ, "c_beqz funct3");
    check5 (rs1_addr, 5'd8, "c_beqz rs1");
    check32(imm, 32'd4, "c_beqz imm");
    check_enum(alu_b_sel, OPB_RS2, "c_beqz compares x0");
    dec(32'h0000_e011);  // c.bnez x8, +4
    check3 (branch_funct3, FUNCT3_BNE, "c_bnez funct3");

    dec(32'h0000_9c01);  // quad1 funct3=100 funct2=11 funct6!=100011 -> illegal
    check_bit(is_illegal, 1'b1, "quad1 c_alu bad funct6 illegal");

    // -- quad2 (op=10)
    dec(32'h0000_028a);  // c.slli x5, 2
    check5 (rs1_addr, 5'd5, "c_slli rs1");
    check32(imm, 32'd2, "c_slli shamt");
    check_enum(alu_op, ALU_SLL, "c_slli alu_op");
    dec(32'h0000_1002);  // c.slli shamt[5] -> illegal on RV32
    check_bit(is_illegal, 1'b1, "c_slli shamt5 illegal");

    dec(32'h0000_829a);  // c.mv x5, x6
    check5 (rd_addr,  5'd5, "c_mv rd");
    check5 (rs2_addr, 5'd6, "c_mv rs2");
    check_enum(alu_a_sel, OPA_X0, "c_mv alu_a X0");
    check_enum(alu_b_sel, OPB_RS2, "c_mv alu_b RS2");

    dec(32'h0000_8282);  // c.jr x5
    check_bit(is_jalr, 1'b1, "c_jr is_jalr");
    check5 (rs1_addr,  5'd5, "c_jr rs1");
    check_bit(rd_we,   1'b0, "c_jr rd_we");
    dec(32'h0000_8002);  // c.jr rs1=0 -> reserved illegal
    check_bit(is_illegal, 1'b1, "c_jr x0 illegal");

    dec(32'h0000_929a);  // c.add x5, x6
    check5 (rs1_addr, 5'd5, "c_add rs1");
    check5 (rs2_addr, 5'd6, "c_add rs2");
    check5 (rd_addr,  5'd5, "c_add rd");
    check_enum(alu_op, ALU_ADD, "c_add alu_op");

    dec(32'h0000_9282);  // c.jalr x5
    check_bit(is_jalr, 1'b1, "c_jalr is_jalr");
    check5 (rs1_addr,  5'd5, "c_jalr rs1");
    check5 (rd_addr,   5'd1, "c_jalr rd");
    check_bit(rd_we,   1'b1, "c_jalr rd_we");

    dec(32'h0000_9002);  // c.ebreak
    check_bit(is_ebreak, 1'b1, "c_ebreak is_ebreak");
    check_bit(is_c,      1'b1, "c_ebreak is_c");
    check_bit(is_nop,    1'b0, "c_ebreak not nop");

    dec(32'h0000_4282);  // c.lwsp x5, 0(sp)
    check_bit(is_load, 1'b1, "c_lwsp is_load");
    check5 (rs1_addr,  5'd2, "c_lwsp rs1=sp");
    check5 (rd_addr,   5'd5, "c_lwsp rd");
    check3 (lsu_funct3, FUNCT3_LW, "c_lwsp lsu_funct3");
    check32(imm, 32'd0, "c_lwsp imm");
    dec(32'h0000_4002);  // c.lwsp rd=0 -> hint NOP
    check_bit(is_nop, 1'b1, "c_lwsp rd0 hint");

    dec(32'h0000_c01a);  // c.swsp x6, 0(sp)
    check_bit(is_store, 1'b1, "c_swsp is_store");
    check5 (rs1_addr, 5'd2, "c_swsp rs1=sp");
    check5 (rs2_addr, 5'd6, "c_swsp rs2");

    dec(32'h0000_2002);  // quad2 reserved funct3=001
    check_bit(is_illegal, 1'b1, "quad2 f3 001 illegal");

    // ==== CSR instructions (Zicsr subset) =========================================

    dec(32'h3001_10f3);  // csrrw x1, x2, mstatus(0x300)
    check_bit(is_csr,  1'b1, "csrrw is_csr");
    check32(csr_addr,  12'h300, "csrrw csr_addr");
    check_enum(csr_op, CSR_RW, "csrrw csr_op");
    check_bit(csr_imm, 1'b0, "csrrw not imm");
    check5 (rs1_addr,  5'd2, "csrrw rs1");
    check5 (rd_addr,   5'd1, "csrrw rd");
    check_bit(rd_we,   1'b1, "csrrw rd_we");
    exec_ok("csrrw");

    dec(32'h3001_20f3);  // csrrs x1, x2, mstatus
    check_enum(csr_op, CSR_RS, "csrrs csr_op");
    dec(32'h3001_30f3);  // csrrc x1, x2, mstatus
    check_enum(csr_op, CSR_RC, "csrrc csr_op");

    dec(32'hb002_d0f3);  // csrrwi x1, 5, mcycle(0xB00)
    check_bit(is_csr,  1'b1, "csrrwi is_csr");
    check32(csr_addr,  12'hB00, "csrrwi csr_addr");
    check_enum(csr_op, CSR_RW, "csrrwi csr_op");
    check_bit(csr_imm, 1'b1, "csrrwi imm");
    check5 (rs1_addr,  5'd0, "csrrwi rs1=0");

    dec(32'hb002_e0f3);  // csrrsi
    check_enum(csr_op, CSR_RS, "csrrsi csr_op");
    check_bit(csr_imm, 1'b1, "csrrsi imm");
    dec(32'hb002_f0f3);  // csrrci
    check_enum(csr_op, CSR_RC, "csrrci csr_op");
    check_bit(csr_imm, 1'b1, "csrrci imm");

    if (fail_count == 0) begin
      $display("PASS tb_decoder");
    end else begin
      $display("FAIL tb_decoder (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
