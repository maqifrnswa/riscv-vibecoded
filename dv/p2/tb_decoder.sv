// up5k-rv -- M1 P2-4 testbench for decoder.sv.
//
// Directed, self-checking: one (or few) representative encoding per supported
// RV32I instruction plus the edge cases that define the NOP boundary. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_decoder rtl/core/up5k_rv_pkg.sv \
//     rtl/core/decoder.sv dv/p2/tb_decoder.sv && vvp build/tb_decoder
// Expected: "PASS tb_decoder", exit 0.

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
    .is_nop_o       (is_nop)
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

  // ---- tests -----------------------------------------------------------------

  initial begin
    insn = 32'd0;
    #1;

    // ---- I-type ALU ----------------------------------------------------------
    // addi x1, x2, -1  (imm 0xfff sign-extended)
    dec(32'hfff1_0093);
    check5 (rs1_addr, 5'd2,  "addi rs1");
    check5 (rd_addr,  5'd1,  "addi rd");
    check32(imm,      32'hffff_ffff, "addi imm");
    check_bit(rd_we,  1'b1,  "addi rd_we");
    check_enum(alu_op, ALU_ADD, "addi alu_op");
    check_bit(is_nop, 1'b0,  "addi not nop");

    // slti x5, x1, -8
    dec(32'hff80_a293);
    check_enum(alu_op, ALU_SLT, "slti alu_op");
    check32(imm, 32'hffff_fff8, "slti imm");

    // sltiu x5, x1, 100
    dec(32'h0640_b293);
    check_enum(alu_op, ALU_SLTU, "sltiu alu_op");
    check32(imm, 32'd100, "sltiu imm");

    // xori x4, x3, 0xabc
    dec(32'h0551_c213);
    check_enum(alu_op, ALU_XOR, "xori alu_op");
    check32(imm, 32'h0000_0055, "xori imm");

    // ori x4, x3, -1
    dec(32'hfff1_e213);
    check_enum(alu_op, ALU_OR, "ori alu_op");
    check32(imm, 32'hffff_ffff, "ori imm");

    // andi x4, x3, 0x1ff
    dec(32'h1ff1_f213);
    check_enum(alu_op, ALU_AND, "andi alu_op");
    check32(imm, 32'h0000_01ff, "andi imm");

    // ---- shifts ----------------------------------------------------------------
    // slli x4, x1, 5  (shamt zero-extended)
    dec(32'h0050_9093);
    check_enum(alu_op, ALU_SLL, "slli alu_op");
    check32(imm, 32'd5, "slli imm");
    check_bit(rd_we, 1'b1, "slli rd_we");

    // srli x4, x1, 5
    dec(32'h0050_d093);
    check_enum(alu_op, ALU_SRL, "srli alu_op");
    check32(imm, 32'd5, "srli imm");

    // srai x4, x1, 5  (funct7[5] = 1)
    dec(32'h4050_d093);
    check_enum(alu_op, ALU_SRA, "srai alu_op");
    check32(imm, 32'd5, "srai imm");

    // slli with invalid funct7 -> NOP
    dec(32'h4050_9093);
    check_bit(is_nop, 1'b1, "slli bad funct7 nop");
    check_bit(rd_we,  1'b0, "slli bad funct7 rd_we");

    // srli with invalid funct7 -> NOP
    dec(32'h2050_d093);
    check_bit(is_nop, 1'b1, "srli bad funct7 nop");

    // ---- register-register ALU ------------------------------------------------
    // add x3, x1, x2
    dec(32'h0020_81b3);
    check5 (rs1_addr, 5'd1,  "add rs1");
    check5 (rs2_addr, 5'd2,  "add rs2");
    check5 (rd_addr,  5'd3,  "add rd");
    check_enum(alu_op, ALU_ADD, "add alu_op");
    check_enum(alu_b_sel, OPB_RS2, "add alu_b RS2");
    check_bit(rd_we, 1'b1, "add rd_we");
    check_bit(is_nop, 1'b0, "add not nop");

    // sub x3, x1, x2  (funct7[5] = 1)
    dec(32'h4020_81b3);
    check_enum(alu_op, ALU_SUB, "sub alu_op");

    // sll x3, x1, x2
    dec(32'h0020_91b3);
    check_enum(alu_op, ALU_SLL, "sll alu_op");

    // slt x3, x1, x2
    dec(32'h0020_a1b3);
    check_enum(alu_op, ALU_SLT, "slt alu_op");

    // sltu x3, x1, x2
    dec(32'h0020_b1b3);
    check_enum(alu_op, ALU_SLTU, "sltu alu_op");

    // xor x3, x1, x2
    dec(32'h0020_c1b3);
    check_enum(alu_op, ALU_XOR, "xor alu_op");

    // srl x3, x1, x2
    dec(32'h0020_d1b3);
    check_enum(alu_op, ALU_SRL, "srl alu_op");

    // sra x3, x1, x2
    dec(32'h4020_d1b3);
    check_enum(alu_op, ALU_SRA, "sra alu_op");

    // or x3, x1, x2
    dec(32'h0020_e1b3);
    check_enum(alu_op, ALU_OR, "or alu_op");

    // and x3, x1, x2
    dec(32'h0020_f1b3);
    check_enum(alu_op, ALU_AND, "and alu_op");

    // invalid funct7 in OP -> NOP (e.g. 0010000)
    dec(32'h1020_81b3);
    check_bit(is_nop, 1'b1, "op bad funct7 nop");
    check_bit(rd_we,  1'b0, "op bad funct7 rd_we");

    // reserved 0100000 in OP with a non-sub/sra funct3 -> NOP (e.g. SLL)
    dec(32'h4020_91b3);  // funct7=0100000, funct3=001 (SLL), rs1=x1 rs2=x2 rd=x3
    check_bit(is_nop, 1'b1, "op 0100000 sll nop");
    check_bit(rd_we,  1'b0, "op 0100000 sll rd_we");
    // 0100000 with funct3=000 (SUB) and 101 (SRA) stay legal
    dec(32'h4020_8033);  // sub x0,x1,x0 (funct7=0100000, funct3=000)
    check_bit(is_nop, 1'b0, "sub not nop");
    check_bit(rd_we,  1'b1, "sub rd_we");
    check_enum(alu_op, ALU_SUB, "sub alu_op");
    dec(32'h4020_d033);  // sra x0,x1,x0 (funct7=0100000, funct3=101)
    check_bit(is_nop, 1'b0, "sra not nop");
    check_bit(rd_we,  1'b1, "sra rd_we");
    check_enum(alu_op, ALU_SRA, "sra alu_op");

    // ---- upper immediates --------------------------------------------------------
    // lui x6, 0x12345
    dec(32'h1234_5337);
    check_enum(alu_a_sel, OPA_X0,  "lui alu_a X0");
    check_enum(alu_b_sel, OPB_UIMM, "lui alu_b UIMM");
    check_enum(alu_op, ALU_ADD, "lui alu_op");
    check32(imm, 32'h1234_5000, "lui imm");
    check_bit(rd_we, 1'b1, "lui rd_we");

    // auipc x7, 0x1
    dec(32'h0000_1397);
    check_enum(alu_a_sel, OPA_PC, "auipc alu_a PC");
    check_enum(alu_b_sel, OPB_UIMM, "auipc alu_b UIMM");
    check32(imm, 32'h0000_1000, "auipc imm");

    // ---- jumps ---------------------------------------------------------------------
    // jal x1, +4
    dec(32'h0040_00ef);
    check_bit(is_jal, 1'b1, "jal is_jal");
    check_bit(rd_we,  1'b1, "jal rd_we");
    check5 (rd_addr,  5'd1, "jal rd");
    check32(imm,      32'd4, "jal imm +4");

    // jal x1, -4
    dec(32'hffdf_f0ef);
    check_bit(is_jal, 1'b1, "jal2 is_jal");
    check32(imm, 32'hffff_fffc, "jal imm -4");

    // jalr x1, x2, 0
    dec(32'h0001_00e7);
    check_bit(is_jalr, 1'b1, "jalr is_jalr");
    check_bit(rd_we,   1'b1, "jalr rd_we");
    check5 (rs1_addr,  5'd2, "jalr rs1");
    check5 (rd_addr,   5'd1, "jalr rd");
    check32(imm,       32'd0, "jalr imm");

    // jalr x1, x2, 8
    dec(32'h0081_00e7);
    check32(imm, 32'd8, "jalr imm 8");

    // jalr with funct3 != 0 -> NOP
    dec(32'h0011_60e7);
    check_bit(is_nop,  1'b1, "jalr bad funct3 nop");
    check_bit(is_jalr, 1'b0, "jalr bad funct3 not jalr");

    // ---- branches -------------------------------------------------------------------
    // beq x1, x2, +4
    dec(32'h0020_8263);
    check_bit(is_branch, 1'b1, "beq is_branch");
    check3 (branch_funct3, FUNCT3_BEQ, "beq funct3");
    check5 (rs1_addr, 5'd1, "beq rs1");
    check5 (rs2_addr, 5'd2, "beq rs2");
    check5 (rd_addr,  5'd0, "beq rd_addr forced 0");
    check_bit(rd_we,  1'b0, "beq rd_we");
    check32(imm,      32'd4, "beq imm +4");

    // bne x1, x2, +4
    dec(32'h0020_9263);
    check3 (branch_funct3, FUNCT3_BNE, "bne funct3");

    // blt x1, x2, +4
    dec(32'h0020_c263);
    check3 (branch_funct3, FUNCT3_BLT, "blt funct3");

    // bge x1, x2, +4
    dec(32'h0020_d263);
    check3 (branch_funct3, FUNCT3_BGE, "bge funct3");

    // bltu x1, x2, +4
    dec(32'h0020_e263);
    check3 (branch_funct3, FUNCT3_BLTU, "bltu funct3");

    // bgeu x1, x2, +4
    dec(32'h0020_f263);
    check3 (branch_funct3, FUNCT3_BGEU, "bgeu funct3");

    // branch funct3 010 (invalid) -> NOP
    dec(32'h0020_a063);
    check_bit(is_nop,    1'b1, "branch bad funct3 nop");
    check_bit(is_branch, 1'b0, "branch bad funct3 not branch");

    // ---- loads -----------------------------------------------------------------------
    // lb x8, 0(x1)
    dec(32'h0000_8403);
    check_bit(is_load, 1'b1, "lb is_load");
    check3 (lsu_funct3, FUNCT3_LB, "lb lsu_funct3");
    check_bit(rd_we, 1'b1, "lb rd_we");
    check5 (rs1_addr, 5'd1, "lb rs1");
    check5 (rd_addr,  5'd8, "lb rd");
    check32(imm,      32'd0, "lb imm");

    // lh x9, 4(x1)
    dec(32'h0040_9483);
    check3 (lsu_funct3, FUNCT3_LH, "lh lsu_funct3");
    check32(imm, 32'd4, "lh imm");

    // lw x10, -8(x1)
    dec(32'hff80_a503);
    check3 (lsu_funct3, FUNCT3_LW, "lw lsu_funct3");
    check32(imm, 32'hffff_fff8, "lw imm");

    // lbu x11, 0(x1)
    dec(32'h0000_c583);
    check3 (lsu_funct3, FUNCT3_LBU, "lbu lsu_funct3");

    // lhu x12, 0(x1)
    dec(32'h0000_d603);
    check3 (lsu_funct3, FUNCT3_LHU, "lhu lsu_funct3");

    // load funct3 011 (invalid) -> NOP
    dec(32'h0000_b483);
    check_bit(is_nop, 1'b1, "load bad funct3 nop");
    check_bit(rd_we,  1'b0, "load bad funct3 rd_we");

    // ---- stores ------------------------------------------------------------------------
    // sb x2, 0(x1)
    dec(32'h0020_8023);
    check_bit(is_store, 1'b1, "sb is_store");
    check3 (lsu_funct3, FUNCT3_SB, "sb lsu_funct3");
    check5 (rs1_addr, 5'd1, "sb rs1");
    check5 (rs2_addr, 5'd2, "sb rs2");
    check5 (rd_addr,  5'd0, "sb rd_addr forced 0");
    check_bit(rd_we,  1'b0, "sb rd_we");
    check32(imm,      32'd0, "sb imm");

    // sh x2, 6(x1)
    dec(32'h0020_9323);
    check3 (lsu_funct3, FUNCT3_SH, "sh lsu_funct3");
    check32(imm, 32'd6, "sh imm");

    // sw x2, -4(x1)
    dec(32'hfe20_ae23);
    check3 (lsu_funct3, FUNCT3_SW, "sw lsu_funct3");
    check32(imm, 32'hffff_fffc, "sw imm");

    // store funct3 011 (invalid) -> NOP
    dec(32'h0020_b023);
    check_bit(is_nop, 1'b1, "store bad funct3 nop");

    // ---- fence / system / unknown -----------------------------------------------------
    // fence
    dec(32'h0000_000f);
    check_bit(is_nop, 1'b1, "fence nop");
    check_bit(rd_we,  1'b0, "fence rd_we");

    // fence.i
    dec(32'h0000_100f);
    check_bit(is_nop, 1'b1, "fence.i nop");

    // ecall
    dec(32'h0000_0073);
    check_bit(is_nop, 1'b1, "ecall nop");

    // ebreak
    dec(32'h0010_0073);
    check_bit(is_nop, 1'b1, "ebreak nop");

    // csrrw x1, x2, 0x300 (csr) -> NOP in M1
    dec(32'h3001_2073);
    check_bit(is_nop, 1'b1, "csr nop");
    check_bit(rd_we,  1'b0, "csr rd_we");

    // unknown opcode (all ones)
    dec(32'hffff_ffff);
    check_bit(is_nop, 1'b1, "unknown opcode nop");

    if (fail_count == 0) begin
      $display("PASS tb_decoder");
    end else begin
      $display("FAIL tb_decoder (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
