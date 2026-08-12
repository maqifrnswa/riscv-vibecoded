// up5k-rv -- M1 P2-4: instruction decoder.
//
// Pure combinational decode of one RV32I instruction word into the control
// bundle the pipeline needs. No state.
//
// Supported: all RV32I base instructions except ecall/ebreak/csr — those
// retire as NOPs (traps are M2 scope). fence/fence.i are NOPs (spec-legal).
// Any unsupported/illegal encoding also decodes to NOP (`is_nop_o`): no
// register write, no memory access, pc += 4. Behavior is deterministic.
//
// Contract notes:
//  - `imm_o` is the sign-extended immediate of the instruction's own type
//    (I/S/B/J), the zero-extended shamt for shifts, or {insn[31:12],12'b0}
//    for U-type. Unused opcodes get imm = 0.
//  - lui  => alu_a = X0, alu_b = UIMM, op ADD (result = upper immediate).
//  - auipc=> alu_a = PC, alu_b = UIMM, op ADD.
//  - Branches and stores have no real rd field (it is part of the
//    immediate), so `rd_addr_o` is forced to 0 there; `rd_we_o` is 0.
//  - `branch_funct3_o` is valid only when `is_branch_o` is set.
//  - `lsu_funct3_o` is the raw insn[14:12], used only when is_load/is_store.
//
// Stage scope (deepwork m1-core-rvfi.md P2-4): this file + its test only.

import up5k_rv_pkg::*;

module decoder (
  input  logic [31:0] insn_i,

  output logic [ 4:0] rs1_addr_o,
  output logic [ 4:0] rs2_addr_o,
  output logic [ 4:0] rd_addr_o,
  output logic        rd_we_o,
  output logic [31:0] imm_o,
  output alu_a_sel_e  alu_a_sel_o,
  output alu_b_sel_e  alu_b_sel_o,
  output alu_op_e     alu_op_o,
  output logic [ 2:0] branch_funct3_o,
  output logic        is_branch_o,
  output logic        is_jal_o,
  output logic        is_jalr_o,
  output logic        is_load_o,
  output logic        is_store_o,
  output logic [ 2:0] lsu_funct3_o,
  output logic        is_nop_o
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  logic [31:0] imm_i;     // I-type (sign-extended)
  logic [31:0] imm_s;     // S-type
  logic [31:0] imm_b;     // B-type
  logic [31:0] imm_j;     // J-type
  logic [31:0] imm_u;     // U-type
  logic [31:0] imm_shift; // {27'b0, shamt}

  assign opcode     = insn_i[6:0];
  assign funct3     = insn_i[14:12];
  assign funct7     = insn_i[31:25];

  assign imm_i     = {{20{insn_i[31]}}, insn_i[31:20]};
  assign imm_s     = {{20{insn_i[31]}}, insn_i[31:25], insn_i[11:7]};
  assign imm_b     = {{19{insn_i[31]}}, insn_i[31], insn_i[7], insn_i[30:25],
                       insn_i[11:8], 1'b0};
  assign imm_j     = {{11{insn_i[31]}}, insn_i[31], insn_i[19:12], insn_i[20],
                       insn_i[30:21], 1'b0};
  assign imm_u     = {insn_i[31:12], 12'b0};
  assign imm_shift = {27'b0, insn_i[24:20]};

  always_comb begin
    // Defaults first: every output assigned on every path (no latches).
    rs1_addr_o      = insn_i[19:15];
    rs2_addr_o      = insn_i[24:20];
    rd_addr_o       = insn_i[11:7];
    rd_we_o         = 1'b0;
    imm_o           = 32'd0;
    alu_a_sel_o     = OPA_RS1;
    alu_b_sel_o     = OPB_IMM;
    alu_op_o        = ALU_ADD;
    branch_funct3_o = funct3;
    is_branch_o     = 1'b0;
    is_jal_o        = 1'b0;
    is_jalr_o       = 1'b0;
    is_load_o       = 1'b0;
    is_store_o      = 1'b0;
    lsu_funct3_o    = funct3;
    is_nop_o        = 1'b0;

    unique case (opcode)
      // ---- register-register ALU -------------------------------------------
      OPCODE_OP: begin
        rd_we_o     = 1'b1;
        alu_a_sel_o = OPA_RS1;
        alu_b_sel_o = OPB_RS2;
        if ((funct7 != 7'b0000000) && (funct7 != 7'b0100000)) begin
          // funct7 other than ADD/SUB-family or SRL/SRA-family: not RV32I.
          rd_we_o  = 1'b0;
          is_nop_o = 1'b1;
        end else begin
          unique case (funct3)
            3'b000: begin
              if (insn_i[30]) begin
                alu_op_o = ALU_SUB;
              end else begin
                alu_op_o = ALU_ADD;
              end
            end
            3'b001: alu_op_o = ALU_SLL;
            3'b010: alu_op_o = ALU_SLT;
            3'b011: alu_op_o = ALU_SLTU;
            3'b100: alu_op_o = ALU_XOR;
            3'b101: begin
              if (insn_i[30]) begin
                alu_op_o = ALU_SRA;
              end else begin
                alu_op_o = ALU_SRL;
              end
            end
            3'b110: alu_op_o = ALU_OR;
            3'b111: alu_op_o = ALU_AND;
            default: begin
              rd_we_o  = 1'b0;
              is_nop_o = 1'b1;
            end
          endcase
        end
      end

      // ---- immediate ALU -----------------------------------------------------
      OPCODE_OP_IMM: begin
        rd_we_o     = 1'b1;
        alu_a_sel_o = OPA_RS1;
        alu_b_sel_o = OPB_IMM;
        unique case (funct3)
          3'b000: begin alu_op_o = ALU_ADD;  imm_o = imm_i; end
          3'b010: begin alu_op_o = ALU_SLT;  imm_o = imm_i; end
          3'b011: begin alu_op_o = ALU_SLTU; imm_o = imm_i; end
          3'b100: begin alu_op_o = ALU_XOR;  imm_o = imm_i; end
          3'b110: begin alu_op_o = ALU_OR;   imm_o = imm_i; end
          3'b111: begin alu_op_o = ALU_AND;  imm_o = imm_i; end
          3'b001: begin  // slli
            if (funct7 != 7'b0000000) begin
              rd_we_o  = 1'b0;
              is_nop_o = 1'b1;
            end else begin
              alu_op_o = ALU_SLL;
              imm_o    = imm_shift;
            end
          end
          3'b101: begin  // srli / srai
            if ((funct7 != 7'b0000000) && (funct7 != 7'b0100000)) begin
              rd_we_o  = 1'b0;
              is_nop_o = 1'b1;
            end else begin
              if (insn_i[30]) begin
                alu_op_o = ALU_SRA;
              end else begin
                alu_op_o = ALU_SRL;
              end
              imm_o    = imm_shift;
            end
          end
          default: begin
            rd_we_o  = 1'b0;
            is_nop_o = 1'b1;
          end
        endcase
      end

      // ---- upper immediates --------------------------------------------------
      OPCODE_LUI: begin
        rd_we_o     = 1'b1;
        alu_a_sel_o = OPA_X0;
        alu_b_sel_o = OPB_UIMM;
        alu_op_o    = ALU_ADD;
        imm_o       = imm_u;
      end

      OPCODE_AUIPC: begin
        rd_we_o     = 1'b1;
        alu_a_sel_o = OPA_PC;
        alu_b_sel_o = OPB_UIMM;
        alu_op_o    = ALU_ADD;
        imm_o       = imm_u;
      end

      // ---- jumps -------------------------------------------------------------
      OPCODE_JAL: begin
        rd_we_o  = 1'b1;
        is_jal_o = 1'b1;
        imm_o    = imm_j;
      end

      OPCODE_JALR: begin
        if (funct3 != 3'b000) begin
          is_nop_o = 1'b1;
        end else begin
          rd_we_o   = 1'b1;
          is_jalr_o = 1'b1;
          imm_o     = imm_i;
        end
      end

      // ---- branches -----------------------------------------------------------
      OPCODE_BRANCH: begin
        imm_o = imm_b;
        if ((funct3 == FUNCT3_BEQ)  || (funct3 == FUNCT3_BNE) ||
            (funct3 == FUNCT3_BLT)  || (funct3 == FUNCT3_BGE) ||
            (funct3 == FUNCT3_BLTU) || (funct3 == FUNCT3_BGEU)) begin
          is_branch_o     = 1'b1;
          branch_funct3_o = funct3;
          rd_addr_o       = 5'd0;  // rd field is part of the B-imm
        end else begin
          is_nop_o = 1'b1;
          rd_addr_o = 5'd0;
        end
      end

      // ---- loads ---------------------------------------------------------------
      OPCODE_LOAD: begin
        is_load_o    = 1'b1;
        lsu_funct3_o = funct3;
        imm_o        = imm_i;
        if ((funct3 == FUNCT3_LB) || (funct3 == FUNCT3_LH) ||
            (funct3 == FUNCT3_LW) || (funct3 == FUNCT3_LBU) ||
            (funct3 == FUNCT3_LHU)) begin
          rd_we_o = 1'b1;
        end else begin
          is_nop_o = 1'b1;
        end
      end

      // ---- stores ---------------------------------------------------------------
      OPCODE_STORE: begin
        is_store_o   = 1'b1;
        lsu_funct3_o = funct3;
        rd_addr_o    = 5'd0;  // rd field is part of the S-imm
        imm_o        = imm_s;
        if ((funct3 != FUNCT3_SB) && (funct3 != FUNCT3_SH) &&
            (funct3 != FUNCT3_SW)) begin
          is_nop_o = 1'b1;
        end
      end

      // ---- fence / system --------------------------------------------------------
      OPCODE_MISC_MEM, OPCODE_SYSTEM:
        is_nop_o = 1'b1;  // fence/fence.i: NOP (spec-legal); ecall/ebreak/csr: M2 traps

      default:
        is_nop_o = 1'b1;  // unknown opcode: deterministic NOP
    endcase
  end

endmodule
