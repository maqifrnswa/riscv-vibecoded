// up5k-rv -- M1 P2-3 testbench for alu.sv.
//
// Directed, self-checking: every ALU op on boundary operands, and every
// branch condition on both taken and not-taken operand pairs. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_alu rtl/core/up5k_rv_pkg.sv \
//     rtl/core/alu.sv dv/p2/tb_alu.sv && vvp build/tb_alu
// Expected: "PASS tb_alu", exit 0.

module tb_alu;

  import up5k_rv_pkg::*;

  logic [31:0] operand_a;
  logic [31:0] operand_b;
  alu_op_e     alu_op;
  logic [ 2:0] branch_funct3;
  logic [31:0] result;
  logic        branch_taken;

  int fail_count = 0;

  alu u_dut (
    .operand_a_i    (operand_a),
    .operand_b_i    (operand_b),
    .alu_op_i       (alu_op),
    .branch_funct3_i(branch_funct3),
    .result_o       (result),
    .branch_taken_o (branch_taken)
  );

  task automatic check(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_bit(logic got, logic exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %b exp %b", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_alu(alu_op_e op, logic [31:0] a, logic [31:0] b,
                           logic [31:0] exp, string name);
    alu_op = op;
    operand_a = a;
    operand_b = b;
    #1;
    check(result, exp, name);
  endtask

  task automatic check_branch(logic [31:0] a, logic [31:0] b,
                              logic [2:0] funct3, logic exp_taken, string name);
    operand_a = a;
    operand_b = b;
    branch_funct3 = funct3;
    #1;
    check_bit(branch_taken, exp_taken, name);
  endtask

  initial begin
    operand_a = '0;
    operand_b = '0;
    alu_op    = ALU_ADD;
    branch_funct3 = 3'd0;
    #1;

    // ---- ALU operations ------------------------------------------------------
    check_alu(ALU_ADD, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, "add 0+0");
    check_alu(ALU_ADD, 32'h0000_0001, 32'h0000_0002, 32'h0000_0003, "add 1+2");
    check_alu(ALU_ADD, 32'hffff_ffff, 32'h0000_0001, 32'h0000_0000, "add wrap");
    check_alu(ALU_ADD, 32'h8000_0000, 32'h8000_0000, 32'h0000_0000, "add min+min");
    check_alu(ALU_ADD, 32'h7fff_ffff, 32'h0000_0001, 32'h8000_0000, "add max+1");

    check_alu(ALU_SUB, 32'h0000_0005, 32'h0000_0003, 32'h0000_0002, "sub 5-3");
    check_alu(ALU_SUB, 32'h0000_0003, 32'h0000_0005, 32'hffff_fffe, "sub 3-5");
    check_alu(ALU_SUB, 32'h0000_0000, 32'h0000_0001, 32'hffff_ffff, "sub 0-1");
    check_alu(ALU_SUB, 32'h8000_0000, 32'h0000_0001, 32'h7fff_ffff, "sub min-1");

    check_alu(ALU_SLL, 32'h0000_0001, 32'h0000_0000, 32'h0000_0001, "sll 1<<0");
    check_alu(ALU_SLL, 32'h0000_0001, 32'h0000_001f, 32'h8000_0000, "sll 1<<31");
    check_alu(ALU_SLL, 32'h1234_5678, 32'h0000_0004, 32'h2345_6780, "sll 0x12345678<<4");
    check_alu(ALU_SLL, 32'hffff_ffff, 32'h0000_0001, 32'hffff_fffe, "sll -1<<1");

    check_alu(ALU_SLT, 32'h0000_0001, 32'h0000_0002, 32'h0000_0001, "slt 1<2");
    check_alu(ALU_SLT, 32'h0000_0002, 32'h0000_0001, 32'h0000_0000, "slt 2<1");
    check_alu(ALU_SLT, 32'h8000_0000, 32'h0000_0000, 32'h0000_0001, "slt min<0 signed");
    check_alu(ALU_SLT, 32'h7fff_ffff, 32'h8000_0000, 32'h0000_0000, "slt max<min");
    check_alu(ALU_SLT, 32'hffff_ffff, 32'h0000_0000, 32'h0000_0001, "slt -1<0");
    check_alu(ALU_SLT, 32'h0000_0005, 32'h0000_0005, 32'h0000_0000, "slt equal");

    check_alu(ALU_SLTU, 32'h0000_0001, 32'h0000_0002, 32'h0000_0001, "sltu 1<2");
    check_alu(ALU_SLTU, 32'h8000_0000, 32'h0000_0000, 32'h0000_0000, "sltu min<0 unsigned");
    check_alu(ALU_SLTU, 32'hffff_ffff, 32'h0000_0001, 32'h0000_0000, "sltu -1<1 unsigned");

    check_alu(ALU_XOR, 32'h0000_00ff, 32'h0000_000f, 32'h0000_00f0, "xor");
    check_alu(ALU_XOR, 32'hffff_ffff, 32'hffff_ffff, 32'h0000_0000, "xor self");

    check_alu(ALU_SRL, 32'h8000_0000, 32'h0000_001f, 32'h0000_0001, "srl 0x80000000>>31");
    check_alu(ALU_SRL, 32'hffff_ffff, 32'h0000_0004, 32'h0fff_ffff, "srl logical");

    check_alu(ALU_SRA, 32'h8000_0000, 32'h0000_001f, 32'hffff_ffff, "sra min>>31");
    check_alu(ALU_SRA, 32'h8000_0000, 32'h0000_0001, 32'hc000_0000, "sra min>>1");
    check_alu(ALU_SRA, 32'h7fff_ffff, 32'h0000_0001, 32'h3fff_ffff, "sra max>>1");
    check_alu(ALU_SRA, 32'h0000_0008, 32'h0000_0001, 32'h0000_0004, "sra positive");

    check_alu(ALU_OR, 32'h0000_000f, 32'h0000_00f0, 32'h0000_00ff, "or");
    check_alu(ALU_OR, 32'h0000_0000, 32'hffff_ffff, 32'hffff_ffff, "or with 0");

    check_alu(ALU_AND, 32'h0000_000f, 32'h0000_00f0, 32'h0000_0000, "and disjoint");
    check_alu(ALU_AND, 32'hffff_ffff, 32'h0f0f_0f0f, 32'h0f0f_0f0f, "and mask");

    // ---- Branch conditions ---------------------------------------------------
    check_branch(32'h0000_0005, 32'h0000_0005, FUNCT3_BEQ,  1'b1, "beq equal");
    check_branch(32'h0000_0005, 32'h0000_0006, FUNCT3_BEQ,  1'b0, "beq not");
    check_branch(32'h0000_0005, 32'h0000_0006, FUNCT3_BNE,  1'b1, "bne diff");
    check_branch(32'h0000_0005, 32'h0000_0005, FUNCT3_BNE,  1'b0, "bne equal");
    check_branch(32'hffff_fffe, 32'h0000_0003, FUNCT3_BLT,  1'b1, "blt -2<3");
    check_branch(32'h0000_0003, 32'hffff_fffe, FUNCT3_BLT,  1'b0, "blt 3<-2");
    check_branch(32'h8000_0000, 32'h7fff_ffff, FUNCT3_BLT,  1'b1, "blt min<max");
    check_branch(32'h0000_0003, 32'hffff_fffe, FUNCT3_BGE,  1'b1, "bge 3>=-2");
    check_branch(32'hffff_fffe, 32'h0000_0003, FUNCT3_BGE,  1'b0, "bge -2>=3");
    check_branch(32'h0000_0005, 32'h0000_0005, FUNCT3_BGE,  1'b1, "bge equal");
    check_branch(32'h0000_0001, 32'h8000_0000, FUNCT3_BLTU, 1'b1, "bltu 1<min unsigned");
    check_branch(32'h8000_0000, 32'h0000_0001, FUNCT3_BLTU, 1'b0, "bltu min<1 unsigned");
    check_branch(32'h8000_0000, 32'h0000_0001, FUNCT3_BGEU, 1'b1, "bgeu min>=1 unsigned");
    check_branch(32'h0000_0001, 32'h8000_0000, FUNCT3_BGEU, 1'b0, "bgeu 1>=min");
    check_branch(32'h0000_0005, 32'h0000_0005, FUNCT3_BGEU, 1'b1, "bgeu equal");

    if (fail_count == 0) begin
      $display("PASS tb_alu");
    end else begin
      $display("FAIL tb_alu (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
