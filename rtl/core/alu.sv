// up5k-rv -- M1 P2-3: ALU.
//
// Combinational RV32I ALU: add/sub/sll/slt/sltu/xor/srl/sra/or/and, plus the
// branch comparison unit. Both are combinational functions of the operands;
// the branch result is resolved from `branch_funct3_i` (B-type funct3).
//
// Shift amounts use operand_b[4:0] (RV32I: shifts are 5-bit amounts).
// slt/sra/branch lt/bge are SIGNED comparisons; sltu/bltu/bgeu are UNSIGNED.
//
// Stage scope (deepwork m1-core-rvfi.md P2-3): this file + its test only.

import up5k_rv_pkg::*;

module alu (
  input  logic [31:0] operand_a_i,
  input  logic [31:0] operand_b_i,
  input  alu_op_e     alu_op_i,
  input  logic [ 2:0] branch_funct3_i,
  output logic [31:0] result_o,
  output logic        branch_taken_o
);

  logic cmp_eq;   // a == b
  logic cmp_lt;   // signed   a < b
  logic cmp_ltu;  // unsigned a < b

  always_comb begin
    cmp_eq  = (operand_a_i == operand_b_i);
    cmp_lt  = ($signed(operand_a_i) < $signed(operand_b_i));
    cmp_ltu = (operand_a_i < operand_b_i);

    unique case (alu_op_i)
      ALU_ADD:  result_o = operand_a_i + operand_b_i;
      ALU_SUB:  result_o = operand_a_i - operand_b_i;
      ALU_SLL:  result_o = operand_a_i << operand_b_i[4:0];
      ALU_SLT:  result_o = {31'd0, cmp_lt};
      ALU_SLTU: result_o = {31'd0, cmp_ltu};
      ALU_XOR:  result_o = operand_a_i ^ operand_b_i;
      ALU_SRL:  result_o = operand_a_i >> operand_b_i[4:0];
      ALU_SRA:  result_o = $signed(operand_a_i) >>> operand_b_i[4:0];
      ALU_OR:   result_o = operand_a_i | operand_b_i;
      ALU_AND:  result_o = operand_a_i & operand_b_i;
      // M-extension ALTOPS fake ops (D18): (a +- b) ^ mask, byte-exact vs the
      // riscv-formal rv32imc models. The models XOR the 32-bit add/sub with
      // the FULL 64-bit mask and truncate to XLEN=32 -- so the effective mask
      // is the LOW 32 bits of the 64-bit constant (a P2 counterexample caught
      // the high-half mistake here).
      ALU_MUL_ALT:    result_o = (operand_a_i + operand_b_i) ^ 32'h5876063e;
      ALU_MULH_ALT:   result_o = (operand_a_i + operand_b_i) ^ 32'hf6583fb7;
      ALU_MULHSU_ALT: result_o = (operand_a_i - operand_b_i) ^ 32'hecfbe137;
      ALU_MULHU_ALT:  result_o = (operand_a_i + operand_b_i) ^ 32'h949ce5e8;
      ALU_DIV_ALT:    result_o = (operand_a_i - operand_b_i) ^ 32'h7f8529ec;
      ALU_DIVU_ALT:   result_o = (operand_a_i - operand_b_i) ^ 32'h10e8fd70;
      ALU_REM_ALT:    result_o = (operand_a_i - operand_b_i) ^ 32'h8da68fa5;
      ALU_REMU_ALT:   result_o = (operand_a_i - operand_b_i) ^ 32'h3138d0e1;
      default:  result_o = 32'h0;  // unreachable (enum covered above)
    endcase

    unique case (branch_funct3_i)
      FUNCT3_BEQ:  branch_taken_o = cmp_eq;
      FUNCT3_BNE:  branch_taken_o = !cmp_eq;
      FUNCT3_BLT:  branch_taken_o = cmp_lt;
      FUNCT3_BGE:  branch_taken_o = !cmp_lt;
      FUNCT3_BLTU: branch_taken_o = cmp_ltu;
      FUNCT3_BGEU: branch_taken_o = !cmp_ltu;
      default:     branch_taken_o = 1'b0;  // non-branch funct3: never taken
    endcase
  end

endmodule
