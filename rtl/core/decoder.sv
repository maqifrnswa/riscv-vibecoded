// up5k-rv -- M2 P1-1: instruction decoder (RV32I + RV32C + M + Zicsr subset).
//
// Pure combinational decode of one instruction word into the control bundle
// the pipeline needs. No state.
//
// M2 scope additions (deepwork m2-c-trap-csr.md P1-1):
//   - C-extension (RV32C): 16-bit instructions are presented zero-extended
//     into [15:0] (the core selects the halfword by PC[1]); classification is
//     insn[1:0] != 2'b11 (32-bit). Register mapping ({1'b1, insn[4:2]} and
//     {1'b1, insn[9:7]} -> x8..x15, SP=x2) and immediate reassembly match the
//     riscv-formal insn_c_* models byte-exact.
//   - M-extension: OP funct7=0000001 -> the 8 ALTOPS fake ops (D18). The ALU
//     computes (rs1 +- rs2) ^ mask so rd_wdata matches the models exactly.
//   - Zicsr subset: csrrw/csrrs/csrrc/csrrwi/csrrsi/csrrci (funct3 != 000);
//     ecall/ebreak/mret classified for the trap machinery; wfi stays NOP.
//   - Trap classification: unsupported/reserved encodings are `is_illegal`
//     (illegal-instruction trap, mcause=2) instead of M1's silent NOP. Hints
//     stay NOPs: fence/fence.i, wfi, c.addi4spn/c.addi16sp/c.lui imm==0.
//     Model-valid "hint" encodings (c.addi rd=0, c.slli/srli/srai shamt=0,
//     c.mv rd=0, c.add rd=0, c.lwsp rd=0) execute normally -- writing x0 is
//     architecturally a NOP and matches the models' rd_addr=0 expectations.
//
// Stage scope (deepwork m2-c-trap-csr.md P1-1): this file + its test only.

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
  output logic        is_nop_o,
  // M2 additions.
  output logic        is_c_o,        // 16-bit (compressed) instruction
  output logic        is_csr_o,      // CSR instruction (SYSTEM, funct3 != 000)
  output logic [11:0] csr_addr_o,
  output csr_op_e     csr_op_o,
  output logic        csr_imm_o,     // csrrwi/csrrsi/csrrci (zimm in [19:15])
  output logic        is_ecall_o,
  output logic        is_ebreak_o,
  output logic        is_mret_o,
  output logic        is_illegal_o   // illegal-instruction trap (mcause=2)
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [1:0] c_quad;        // C-extension quadrant = insn[1:0]
  logic [2:0] c_funct3;      // C-extension funct3 = insn[15:13] (NOT insn[14:12])

  // ---- RV32I immediates -------------------------------------------------------
  logic [31:0] imm_i;     // I-type (sign-extended)
  logic [31:0] imm_s;     // S-type
  logic [31:0] imm_b;     // B-type
  logic [31:0] imm_j;     // J-type
  logic [31:0] imm_u;     // U-type
  logic [31:0] imm_shift; // {27'b0, shamt}

  assign opcode = insn_i[6:0];
  assign funct3 = insn_i[14:12];
  assign funct7 = insn_i[31:25];
  assign c_quad = insn_i[1:0];
  assign c_funct3 = insn_i[15:13];

  assign imm_i     = {{20{insn_i[31]}}, insn_i[31:20]};
  assign imm_s     = {{20{insn_i[31]}}, insn_i[31:25], insn_i[11:7]};
  assign imm_b     = {{19{insn_i[31]}}, insn_i[31], insn_i[7], insn_i[30:25],
                       insn_i[11:8], 1'b0};
  assign imm_j     = {{11{insn_i[31]}}, insn_i[31], insn_i[19:12], insn_i[20],
                       insn_i[30:21], 1'b0};
  assign imm_u     = {insn_i[31:12], 12'b0};
  assign imm_shift = {27'b0, insn_i[24:20]};

  // ---- C-extension immediates (bit reassembly per the insn_c_* models) --------
  logic [31:0] c_imm_sext6;   // {insn[12], insn[6:2]} sign-extended
  logic [31:0] c_imm_lui;     // {sext6, 12'b0}
  logic [31:0] c_imm_16sp;    // c.addi16sp (sext10, 4'b0 tail)
  logic [31:0] c_imm_4spn;    // c.addi4spn (zero-ext, 2'b00 tail)
  logic [31:0] c_imm_cl;      // c.lw/c.sw (zero-ext, 2'b00 tail)
  logic [31:0] c_imm_lwsp;    // c.lwsp (zero-ext, 2'b00 tail)
  logic [31:0] c_imm_swsp;    // c.swsp (zero-ext, 2'b00 tail)
  logic [31:0] c_imm_cb;      // c.beqz/c.bnez (sext9, 1'b0 tail)
  logic [31:0] c_imm_cj;      // c.j/c.jal (sext12, 1'b0 tail)
  logic [31:0] c_shamt;       // {insn[12], insn[6:2]} zero-extended

  assign c_imm_sext6 = {{26{insn_i[12]}}, insn_i[12], insn_i[6:2]};
  assign c_imm_lui   = {{14{insn_i[12]}}, insn_i[12], insn_i[6:2], 12'b0};
  assign c_imm_16sp  = {{22{insn_i[12]}}, insn_i[12], insn_i[4:3], insn_i[5],
                         insn_i[2], insn_i[6], 4'b0};
  assign c_imm_4spn  = {22'b0, insn_i[10:7], insn_i[12:11], insn_i[5],
                        insn_i[6], 2'b00};
  assign c_imm_cl    = {25'b0, insn_i[5], insn_i[12:10], insn_i[6], 2'b00};
  assign c_imm_lwsp  = {24'b0, insn_i[3:2], insn_i[12], insn_i[6:4], 2'b00};
  assign c_imm_swsp  = {24'b0, insn_i[8:7], insn_i[12:9], 2'b00};
  assign c_imm_cb    = {{23{insn_i[12]}}, insn_i[12], insn_i[6:5], insn_i[2],
                         insn_i[11:10], insn_i[4:3], 1'b0};
  assign c_imm_cj    = {{20{insn_i[12]}}, insn_i[12], insn_i[8], insn_i[10],
                         insn_i[9], insn_i[6], insn_i[7], insn_i[2], insn_i[11],
                         insn_i[5], insn_i[4], insn_i[3], 1'b0};
  assign c_shamt     = {26'b0, insn_i[12], insn_i[6:2]};

  // ---- default bundle (assigned on every path; no latches) --------------------
  always_comb begin
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
    is_c_o          = 1'b0;
    is_csr_o        = 1'b0;
    csr_addr_o      = 12'd0;
    csr_op_o        = CSR_RW;
    csr_imm_o       = 1'b0;
    is_ecall_o      = 1'b0;
    is_ebreak_o     = 1'b0;
    is_mret_o       = 1'b0;
    is_illegal_o    = 1'b0;

    if (c_quad != 2'b11) begin
      // ---- C-extension (16-bit) ---------------------------------------------
      is_c_o = 1'b1;
      // Defaults for C register fields (overridden per instruction).
      rs1_addr_o = 5'd0;
      rs2_addr_o = 5'd0;
      rd_addr_o  = 5'd0;

      unique case (c_quad)
        C_QUAD0: begin  // c.addi4spn, c.lw, c.sw
          unique case (c_funct3)
            3'b000: begin  // c.addi4spn
              rd_addr_o = {2'b01, insn_i[4:2]};
              rs1_addr_o = 5'd2;      // SP
              imm_o = c_imm_4spn;
              if (imm_o == 32'd0) begin
                is_nop_o = 1'b1;      // hint: imm == 0
              end else begin
                rd_we_o = 1'b1;
              end
            end
            3'b010: begin  // c.lw
              rs1_addr_o = {2'b01, insn_i[9:7]};
              rd_addr_o  = {2'b01, insn_i[4:2]};
              imm_o = c_imm_cl;
              lsu_funct3_o = FUNCT3_LW;
              is_load_o = 1'b1;
              rd_we_o  = 1'b1;
            end
            3'b110: begin  // c.sw
              rs1_addr_o = {2'b01, insn_i[9:7]};
              rs2_addr_o = {2'b01, insn_i[4:2]};
              imm_o = c_imm_cl;
              lsu_funct3_o = FUNCT3_SW;
              is_store_o = 1'b1;
            end
            default: is_illegal_o = 1'b1;
          endcase
        end

        C_QUAD1: begin
          unique case (c_funct3)
            3'b000: begin  // c.addi (rd=0 is c.nop; still model-valid)
              rs1_addr_o = insn_i[11:7];
              rd_addr_o  = insn_i[11:7];
              imm_o = c_imm_sext6;
              alu_a_sel_o = OPA_RS1;
              alu_b_sel_o = OPB_IMM;
              alu_op_o = ALU_ADD;
              rd_we_o = 1'b1;
            end
            3'b001: begin  // c.jal (links x1)
              rd_addr_o  = 5'd1;
              imm_o = c_imm_cj;
              alu_a_sel_o = OPA_PC;
              alu_b_sel_o = OPB_IMM;
              alu_op_o = ALU_ADD;
              is_jal_o = 1'b1;
              rd_we_o  = 1'b1;
            end
            3'b010: begin  // c.li
              rd_addr_o  = insn_i[11:7];
              imm_o = c_imm_sext6;
              alu_a_sel_o = OPA_X0;
              alu_b_sel_o = OPB_IMM;
              alu_op_o = ALU_ADD;
              rd_we_o = 1'b1;
            end
            3'b011: begin  // c.addi16sp (rd==2) / c.lui (rd != 2)
              if (insn_i[11:7] == 5'd2) begin  // c.addi16sp
                rs1_addr_o = 5'd2;
                rd_addr_o  = 5'd2;
                imm_o = c_imm_16sp;
              end else begin  // c.lui
                rd_addr_o = insn_i[11:7];
                imm_o = c_imm_lui;
                alu_a_sel_o = OPA_X0;
              end
              alu_b_sel_o = OPB_IMM;
              alu_op_o = ALU_ADD;
              if (imm_o == 32'd0) begin
                is_nop_o = 1'b1;      // hint: imm == 0
              end else begin
                rd_we_o = 1'b1;
              end
            end
            3'b100: begin  // c.srli/c.srai (funct2=00/01), c.andi (10), c.alu (11)
              unique case (insn_i[11:10])
                2'b00: begin  // c.srli
                  if (insn_i[12]) begin
                    is_illegal_o = 1'b1;  // shamt[5] reserved on RV32
                  end else begin
                    rs1_addr_o = {2'b01, insn_i[9:7]};
                    rd_addr_o  = {2'b01, insn_i[9:7]};
                    imm_o = c_shamt;
                    alu_a_sel_o = OPA_RS1;
                    alu_b_sel_o = OPB_IMM;
                    alu_op_o = ALU_SRL;
                    rd_we_o = 1'b1;
                  end
                end
                2'b01: begin  // c.srai
                  if (insn_i[12]) begin
                    is_illegal_o = 1'b1;
                  end else begin
                    rs1_addr_o = {2'b01, insn_i[9:7]};
                    rd_addr_o  = {2'b01, insn_i[9:7]};
                    imm_o = c_shamt;
                    alu_a_sel_o = OPA_RS1;
                    alu_b_sel_o = OPB_IMM;
                    alu_op_o = ALU_SRA;
                    rd_we_o = 1'b1;
                  end
                end
                2'b10: begin  // c.andi
                  rs1_addr_o = {2'b01, insn_i[9:7]};
                  rd_addr_o  = {2'b01, insn_i[9:7]};
                  imm_o = c_imm_sext6;
                  alu_a_sel_o = OPA_RS1;
                  alu_b_sel_o = OPB_IMM;
                  alu_op_o = ALU_AND;
                  rd_we_o = 1'b1;
                end
                2'b11: begin  // c.sub/c.xor/c.or/c.and (funct6 must be 100011)
                  if (!insn_i[12]) begin
                    rs1_addr_o = {2'b01, insn_i[9:7]};
                    rs2_addr_o = {2'b01, insn_i[4:2]};
                    rd_addr_o  = {2'b01, insn_i[9:7]};
                    alu_a_sel_o = OPA_RS1;
                    alu_b_sel_o = OPB_RS2;
                    unique case (insn_i[6:5])
                      2'b00:   alu_op_o = ALU_SUB;   // c.sub
                      2'b01:   alu_op_o = ALU_XOR;   // c.xor
                      2'b10:   alu_op_o = ALU_OR;    // c.or
                      default: alu_op_o = ALU_AND;   // c.and
                    endcase
                    rd_we_o = 1'b1;
                  end else begin
                    is_illegal_o = 1'b1;  // funct6 != 100011
                  end
                end
                default: is_illegal_o = 1'b1;
              endcase
            end
            3'b101: begin  // c.j
              imm_o = c_imm_cj;
              alu_a_sel_o = OPA_PC;
              alu_b_sel_o = OPB_IMM;
              alu_op_o = ALU_ADD;
              is_jal_o = 1'b1;
            end
            3'b110: begin  // c.beqz
              rs1_addr_o = {2'b01, insn_i[9:7]};
              imm_o = c_imm_cb;
              branch_funct3_o = FUNCT3_BEQ;
              alu_a_sel_o = OPA_RS1;
              alu_b_sel_o = OPB_RS2;   // rs2_addr = 0 -> compares against x0
              is_branch_o = 1'b1;
            end
            3'b111: begin  // c.bnez
              rs1_addr_o = {2'b01, insn_i[9:7]};
              imm_o = c_imm_cb;
              branch_funct3_o = FUNCT3_BNE;
              alu_a_sel_o = OPA_RS1;
              alu_b_sel_o = OPB_RS2;
              is_branch_o = 1'b1;
            end
            default: is_illegal_o = 1'b1;
          endcase
        end

        C_QUAD2: begin
          unique case (c_funct3)
            3'b000: begin  // c.slli (funct4=0000/0001)
              unique case (insn_i[15:12])
                4'b0000: begin
                  rs1_addr_o = insn_i[11:7];
                  rd_addr_o  = insn_i[11:7];
                  imm_o = c_shamt;
                  alu_a_sel_o = OPA_RS1;
                  alu_b_sel_o = OPB_IMM;
                  alu_op_o = ALU_SLL;
                  rd_we_o = 1'b1;
                end
                default: is_illegal_o = 1'b1;  // shamt[5] reserved on RV32
              endcase
            end
            3'b100: begin  // c.mv/c.jr (funct4=1000), c.add/c.jalr/c.ebreak (1001)
              unique case (insn_i[15:12])
                4'b1000: begin  // c.mv / c.jr / reserved
                  if (insn_i[6:2] != 5'd0) begin
                    rd_addr_o  = insn_i[11:7]; // c.mv
                    rs2_addr_o = insn_i[6:2];
                    alu_a_sel_o = OPA_X0;
                    alu_b_sel_o = OPB_RS2;
                    alu_op_o = ALU_ADD;
                    rd_we_o = 1'b1;
                  end else if (insn_i[11:7] != 5'd0) begin
                    rs1_addr_o = insn_i[11:7]; // c.jr
                    alu_a_sel_o = OPA_RS1;
                    alu_b_sel_o = OPB_IMM;    // imm 0
                    alu_op_o = ALU_ADD;
                    is_jalr_o = 1'b1;
                  end else begin
                    is_illegal_o = 1'b1;       // reserved (c.jr rs1=0)
                  end
                end
                4'b1001: begin  // c.add / c.jalr / c.ebreak
                  if (insn_i[6:2] != 5'd0) begin
                    rs1_addr_o = insn_i[11:7]; // c.add
                    rs2_addr_o = insn_i[6:2];
                    rd_addr_o  = insn_i[11:7];
                    alu_a_sel_o = OPA_RS1;
                    alu_b_sel_o = OPB_RS2;
                    alu_op_o = ALU_ADD;
                    rd_we_o = 1'b1;
                  end else if (insn_i[11:7] != 5'd0) begin
                    rs1_addr_o = insn_i[11:7]; // c.jalr (links x1)
                    rd_addr_o  = 5'd1;
                    alu_a_sel_o = OPA_RS1;
                    alu_b_sel_o = OPB_IMM;    // imm 0
                    alu_op_o = ALU_ADD;
                    is_jalr_o = 1'b1;
                    rd_we_o  = 1'b1;
                  end else begin
                    is_ebreak_o = 1'b1;        // c.ebreak (0x9002)
                  end
                end
                default: is_illegal_o = 1'b1;
              endcase
            end
            3'b010: begin  // c.lwsp
              rd_addr_o  = insn_i[11:7];
              rs1_addr_o = 5'd2;      // SP
              imm_o = c_imm_lwsp;
              lsu_funct3_o = FUNCT3_LW;
              if (rd_addr_o == 5'd0) begin
                is_nop_o = 1'b1;      // hint: rd == 0
              end else begin
                is_load_o = 1'b1;
                rd_we_o  = 1'b1;
              end
            end
            3'b110: begin  // c.swsp
              rs1_addr_o = 5'd2;      // SP
              rs2_addr_o = insn_i[6:2];
              imm_o = c_imm_swsp;
              lsu_funct3_o = FUNCT3_SW;
              is_store_o = 1'b1;
            end
            default: is_illegal_o = 1'b1;
          endcase
        end

        default: is_illegal_o = 1'b1;
      endcase

    end else begin
      // ---- 32-bit RV32I (+ M + Zicsr) ----------------------------------------
      unique case (opcode)
        // ---- register-register ALU (+ M extension) --------------------------
        OPCODE_OP: begin
          rd_we_o     = 1'b1;
          alu_a_sel_o = OPA_RS1;
          alu_b_sel_o = OPB_RS2;
          if (funct7 == FUNCT7_M) begin
            // M-extension ALTOPS fake ops (D18); ALU computes (a +- b) ^ mask.
            unique case (funct3)
              3'b000: alu_op_o = ALU_MUL_ALT;
              3'b001: alu_op_o = ALU_MULH_ALT;
              3'b010: alu_op_o = ALU_MULHSU_ALT;
              3'b011: alu_op_o = ALU_MULHU_ALT;
              3'b100: alu_op_o = ALU_DIV_ALT;
              3'b101: alu_op_o = ALU_DIVU_ALT;
              3'b110: alu_op_o = ALU_REM_ALT;
              default: alu_op_o = ALU_REMU_ALT;
            endcase
          end else if ((funct7 != 7'b0000000) && (funct7 != 7'b0100000)) begin
            // funct7 other than ADD/SUB-family or SRL/SRA-family: not RV32I/M.
            rd_we_o     = 1'b0;
            is_illegal_o = 1'b1;
          end else begin
            unique case (funct3)
              3'b000: begin
                if (insn_i[30]) begin
                  alu_op_o = ALU_SUB;
                end else begin
                  alu_op_o = ALU_ADD;
                end
              end
              3'b001: begin  // SLL: funct7 must be 0000000 (0100000 is reserved)
                if (funct7 != 7'b0000000) begin
                  rd_we_o     = 1'b0;
                  is_illegal_o = 1'b1;
                end else begin
                  alu_op_o = ALU_SLL;
                end
              end
              3'b010: begin  // SLT
                if (funct7 != 7'b0000000) begin
                  rd_we_o     = 1'b0;
                  is_illegal_o = 1'b1;
                end else begin
                  alu_op_o = ALU_SLT;
                end
              end
              3'b011: begin  // SLTU
                if (funct7 != 7'b0000000) begin
                  rd_we_o     = 1'b0;
                  is_illegal_o = 1'b1;
                end else begin
                  alu_op_o = ALU_SLTU;
                end
              end
              3'b100: begin  // XOR
                if (funct7 != 7'b0000000) begin
                  rd_we_o     = 1'b0;
                  is_illegal_o = 1'b1;
                end else begin
                  alu_op_o = ALU_XOR;
                end
              end
              3'b101: begin
                if (insn_i[30]) begin
                  alu_op_o = ALU_SRA;
                end else begin
                  alu_op_o = ALU_SRL;
                end
              end
              3'b110: begin  // OR
                if (funct7 != 7'b0000000) begin
                  rd_we_o     = 1'b0;
                  is_illegal_o = 1'b1;
                end else begin
                  alu_op_o = ALU_OR;
                end
              end
              3'b111: begin  // AND
                if (funct7 != 7'b0000000) begin
                  rd_we_o     = 1'b0;
                  is_illegal_o = 1'b1;
                end else begin
                  alu_op_o = ALU_AND;
                end
              end
              default: begin
                rd_we_o     = 1'b0;
                is_illegal_o = 1'b1;
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
                rd_we_o     = 1'b0;
                is_illegal_o = 1'b1;
              end else begin
                alu_op_o = ALU_SLL;
                imm_o    = imm_shift;
              end
            end
            3'b101: begin  // srli / srai
              if ((funct7 != 7'b0000000) && (funct7 != 7'b0100000)) begin
                rd_we_o     = 1'b0;
                is_illegal_o = 1'b1;
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
              rd_we_o     = 1'b0;
              is_illegal_o = 1'b1;
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
            is_illegal_o = 1'b1;
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
            alu_b_sel_o     = OPB_RS2;  // compare rs1 vs rs2; imm_b is only the target
          end else begin
            is_illegal_o = 1'b1;
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
            is_illegal_o = 1'b1;
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
            is_illegal_o = 1'b1;
          end
        end

        // ---- fence / system --------------------------------------------------------
        OPCODE_MISC_MEM: begin
          is_nop_o = 1'b1;  // fence / fence.i: spec-legal NOP
        end

        OPCODE_SYSTEM: begin
          if (funct3 == 3'b000) begin
            // ecall / ebreak / mret / wfi; anything else is reserved.
            unique case (insn_i[31:20])
              12'h000: is_ecall_o  = 1'b1;
              12'h001: is_ebreak_o = 1'b1;
              12'h302: is_mret_o   = 1'b1;
              12'h105: is_nop_o    = 1'b1;  // wfi: NOP (design D7)
              default: is_illegal_o = 1'b1;
            endcase
          end else begin
            // CSR instructions (Zicsr subset): funct3 001/010/011/101/110/111.
            is_csr_o   = 1'b1;
            csr_addr_o = insn_i[31:20];
            csr_imm_o  = funct3[2];           // csrrwi/csrrsi/csrrci
            unique case (funct3[1:0])
              2'b10:   csr_op_o = CSR_RS;
              2'b11:   csr_op_o = CSR_RC;
              default: csr_op_o = CSR_RW;
            endcase
            rd_addr_o = insn_i[11:7];
            rd_we_o   = (insn_i[11:7] != 5'd0);
            if (csr_imm_o) begin
              rs1_addr_o = 5'd0;  // no register read for the immediate forms
            end
          end
        end

        default:
          is_illegal_o = 1'b1;  // unknown opcode: illegal-instruction trap
      endcase
    end
  end

endmodule
