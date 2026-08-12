// up5k-rv -- M1 P2-7: RV32I core top.
//
// Hazard-free multi-cycle RV32I core: phase FSM (ID -> EX -> (MEM) -> WB),
// overlapped next-fetch, RVFI retirement channel, and a single SBus master
// memory port (fetch + LSU, never overlapping -- design.md D2).
//
// Scheduling contract (see deepwork m1-core-rvfi.md P2-7):
//   - The fetched word is captured by fetch_unit; `word_pending_q` records
//     "word available" one cycle later. The pipeline accepts into ID from
//     IDLE/WB on word_pending_q.
//   - Fetch of instruction i+1 starts at the ID->EX edge for non-memory
//     instructions (F_REQ during EX) and at the MEM->WB edge for loads/stores
//     (F_REQ during WB). WB always retires into one IDLE cycle before ID, so
//     ID(i+1) reads the register file a FULL cycle after WB(i) committed it:
//     NO forwarding and NO load-use stall are needed for correctness (D5
//     deferred to M4 tuning).
//   - Branch/jal/jalr fetch the sequential successor speculatively; a taken
//     branch redirects the fetch unit at the EX->WB edge (target =
//     (rs1+imm)&~1 for jalr, else pc+imm), squashing any pending word.
//   - Memory slave must answer combinationally (rsp_valid_i = f(req_valid_o))
//     for redirects to be safe; registered-latency slaves (SoC, M5) need
//     stale-response suppression in fetch_unit.
//   - Retire: rvfi_valid asserted during WB, one instruction per retire,
//     order gap-free from 0. ecall/ebreak/csr/fence retire as NOPs (traps
//     are M2; fence is spec-legal NOP). rvfi_trap is therefore always 0.
//
// M1 scope: RV32I only (32-bit instructions, PC += 4; the 16-bit C-ext
// fetch granularity is M2). Unsupported encodings retire deterministically
// as NOPs via the decoder's is_nop.
//
// Stage scope (deepwork m1-core-rvfi.md P2-7): this file + its test only.

import up5k_rv_pkg::*;

module rv32i_core (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- SBus master (memory) -------------------------------------------------
  output logic        req_valid_o,
  output logic        req_we_o,
  output logic [31:0] req_addr_o,
  output logic [ 3:0] req_be_o,
  output logic [31:0] req_wdata_o,
  input  logic        rsp_valid_i,
  input  logic [31:0] rsp_rdata_i,

  // ---- RVFI output channel (NRET = 1) ---------------------------------------
  output logic        rvfi_valid,
  output logic [63:0] rvfi_order,
  output logic [31:0] rvfi_insn,
  output logic        rvfi_trap,
  output logic        rvfi_halt,
  output logic        rvfi_intr,
  output logic [ 1:0] rvfi_mode,
  output logic [ 1:0] rvfi_ixl,
  output logic [ 4:0] rvfi_rs1_addr,
  output logic [ 4:0] rvfi_rs2_addr,
  output logic [31:0] rvfi_rs1_rdata,
  output logic [31:0] rvfi_rs2_rdata,
  output logic [ 4:0] rvfi_rd_addr,
  output logic [31:0] rvfi_rd_wdata,
  output logic [31:0] rvfi_pc_rdata,
  output logic [31:0] rvfi_pc_wdata,
  output logic [31:0] rvfi_mem_addr,
  output logic [ 3:0] rvfi_mem_rmask,
  output logic [ 3:0] rvfi_mem_wmask,
  output logic [31:0] rvfi_mem_rdata,
  output logic [31:0] rvfi_mem_wdata
);

  // ---- pipeline state --------------------------------------------------------
  phase_e      phase_q;       // execute-pipeline phase
  logic [31:0] pc_exe_q;      // PC of the instruction in the pipeline
  logic [31:0] insn_exe_q;    // instruction word in the pipeline
  logic [31:0] rs1_q;         // regfile operand a (latched at ID)
  logic [31:0] rs2_q;         // regfile operand b (latched at ID)
  logic [31:0] alu_result_q;  // EX result (latched at EX->WB)
  logic [31:0] mem_addr_q;    // load/store effective address (latched EX->WB)
  logic [31:0] mem_rdata_q;   // load/store response data (latched at MEM)
  logic        word_pending_q;  // fetched word available, not yet accepted
  logic [63:0] order_q;       // retired-instruction counter (RVFI order)
  logic [31:0] rd_wdata_comb; // writeback data (WB phase)

  // ---- decode bundle (combinational from the in-pipeline instruction) --------
  logic [ 4:0] dec_rs1_addr;
  logic [ 4:0] dec_rs2_addr;
  logic [ 4:0] dec_rd_addr;
  logic        dec_rd_we;
  logic [31:0] dec_imm;
  alu_a_sel_e  dec_alu_a_sel;
  alu_b_sel_e  dec_alu_b_sel;
  alu_op_e     dec_alu_op;
  logic [ 2:0] dec_branch_funct3;
  logic        dec_is_branch;
  logic        dec_is_jal;
  logic        dec_is_jalr;
  logic        dec_is_load;
  logic        dec_is_store;
  logic [ 2:0] dec_lsu_funct3;
  logic        dec_is_nop;

  decoder u_decoder (
    .insn_i         (insn_exe_q),
    .rs1_addr_o     (dec_rs1_addr),
    .rs2_addr_o     (dec_rs2_addr),
    .rd_addr_o      (dec_rd_addr),
    .rd_we_o        (dec_rd_we),
    .imm_o          (dec_imm),
    .alu_a_sel_o    (dec_alu_a_sel),
    .alu_b_sel_o    (dec_alu_b_sel),
    .alu_op_o       (dec_alu_op),
    .branch_funct3_o(dec_branch_funct3),
    .is_branch_o    (dec_is_branch),
    .is_jal_o       (dec_is_jal),
    .is_jalr_o      (dec_is_jalr),
    .is_load_o      (dec_is_load),
    .is_store_o     (dec_is_store),
    .lsu_funct3_o   (dec_lsu_funct3),
    .is_nop_o       (dec_is_nop)
  );

  // ---- fetch unit -------------------------------------------------------------
  logic        fetch_start;
  logic [31:0] fetch_pc;
  logic        fetch_redirect;
  logic [31:0] redirect_target;
  logic [31:0] fetch_word;
  logic [31:0] fetch_word_pc;
  logic        fetch_word_valid;
  logic        fetch_req_valid;
  logic [31:0] fetch_req_addr;
  logic [ 3:0] fetch_req_be;

  fetch_unit u_fetch (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .start_i          (fetch_start),
    .fetch_pc_i       (fetch_pc),
    .redirect_i       (fetch_redirect),
    .redirect_target_i(redirect_target),
    .word_o           (fetch_word),
    .word_pc_o        (fetch_word_pc),
    .word_valid_o     (fetch_word_valid),
    .req_valid_o      (fetch_req_valid),
    .req_addr_o       (fetch_req_addr),
    .req_be_o         (fetch_req_be),
    .rsp_valid_i      (rsp_valid_i),
    .rsp_rdata_i      (rsp_rdata_i)
  );

  // ---- register file -----------------------------------------------------------
  logic [31:0] reg_rdata_a;
  logic [31:0] reg_rdata_b;
  logic        reg_we;

  // Read addresses come from the INCOMING word (fields of the instruction
  // entering ID); the data is latched into rs1_q/rs2_q at the accept edge.
  regfile u_regfile (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .waddr_i   (dec_rd_addr),
    .wdata_i   (rd_wdata_comb),
    .we_i      (reg_we),
    .raddr_a_i (fetch_word[19:15]),
    .raddr_b_i (fetch_word[24:20]),
    .rdata_a_o (reg_rdata_a),
    .rdata_b_o (reg_rdata_b)
  );

  // ---- ALU ----------------------------------------------------------------------
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  logic [31:0] alu_result_comb;
  logic        alu_branch_taken;

  alu u_alu (
    .operand_a_i    (alu_a),
    .operand_b_i    (alu_b),
    .alu_op_i       (dec_alu_op),
    .branch_funct3_i(dec_branch_funct3),
    .result_o       (alu_result_comb),
    .branch_taken_o (alu_branch_taken)
  );

  // ---- load/store unit -----------------------------------------------------------
  logic [31:0] lsu_addr;
  logic [ 3:0] lsu_be;
  logic [31:0] lsu_wdata;
  logic [31:0] lsu_rd_data;

  lsu u_lsu (
    .addr_i    (mem_addr_q),
    .funct3_i  (dec_lsu_funct3),
    .store_i   (dec_is_store),
    .wdata_i   (rs2_q),
    .rdata_i   (mem_rdata_q),
    .addr_o    (lsu_addr),
    .be_o      (lsu_be),
    .wdata_o   (lsu_wdata),
    .rd_data_o (lsu_rd_data)
  );

  // ---- combinational control -----------------------------------------------------
  logic [31:0] seq_pc;
  logic        accept;
  logic        branch_taken;
  logic [31:0] branch_target;
  phase_e      phase_d;

  assign seq_pc        = pc_exe_q + 32'd4;
  assign branch_taken  = dec_is_branch && alu_branch_taken;
  assign branch_target = dec_is_jalr ? ((rs1_q + dec_imm) & ~32'h1)
                                     : (pc_exe_q + dec_imm);
  assign accept = (phase_q == PH_IDLE) && word_pending_q;

  // Next-instruction fetch scheduling (hazard-free schedule; see header).
  assign fetch_start = ((phase_q == PH_IDLE) && !word_pending_q) ||
                       ((phase_q == PH_ID)    && !dec_is_load && !dec_is_store) ||
                       ((phase_q == PH_MEM)   && rsp_valid_i);
  assign fetch_pc   = (phase_q == PH_IDLE) ? 32'h0  // reset vector (only IDLE-no-pending)
                                           : seq_pc;
  assign fetch_redirect  = (phase_q == PH_EX) &&
                           (branch_taken || dec_is_jal || dec_is_jalr);
  assign redirect_target = branch_target;

  // ALU operand selection.
  always_comb begin
    unique case (dec_alu_a_sel)
      OPA_X0:  alu_a = 32'd0;
      OPA_RS1: alu_a = rs1_q;
      OPA_PC:  alu_a = pc_exe_q;
      default: alu_a = 32'd0;
    endcase
    unique case (dec_alu_b_sel)
      OPB_RS2:  alu_b = rs2_q;
      OPB_IMM:  alu_b = dec_imm;
      OPB_UIMM: alu_b = dec_imm;
      default:  alu_b = 32'd0;
    endcase
  end

  // Phase next-state.
  always_comb begin
    unique case (phase_q)
      PH_IDLE: begin
        if (accept) begin
          phase_d = PH_ID;
        end else begin
          phase_d = PH_IDLE;
        end
      end
      PH_ID:   phase_d = PH_EX;
      PH_EX: begin
        if (dec_is_load || dec_is_store) begin
          phase_d = PH_MEM;
        end else begin
          phase_d = PH_WB;
        end
      end
      PH_MEM: begin
        if (rsp_valid_i) begin
          phase_d = PH_WB;
        end else begin
          phase_d = PH_MEM;
        end
      end
      PH_WB:   phase_d = PH_IDLE;  // always: ID must read regfile a full cycle
                                   // after the WB commit edge (hazard-free)
      default: phase_d = PH_IDLE;
    endcase
  end

  // Writeback data (WB phase).
  always_comb begin
    if (dec_is_load) begin
      rd_wdata_comb = lsu_rd_data;
    end else if (dec_is_jal || dec_is_jalr) begin
      rd_wdata_comb = seq_pc;
    end else begin
      rd_wdata_comb = alu_result_q;
    end
  end

  assign reg_we = (phase_q == PH_WB) && dec_rd_we && (dec_rd_addr != 5'd0);

  // ---- registered pipeline update ------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q        <= PH_IDLE;
      pc_exe_q       <= 32'd0;
      insn_exe_q     <= 32'd0;
      rs1_q          <= 32'd0;
      rs2_q          <= 32'd0;
      alu_result_q   <= 32'd0;
      mem_addr_q     <= 32'd0;
      mem_rdata_q    <= 32'd0;
      word_pending_q <= 1'b0;
      order_q        <= 64'd0;
    end else begin
      phase_q <= phase_d;

      // Accept a fetched word into ID (one cycle after its capture, so
      // fetch_word/fetch_word_pc are stable here).
      if (accept) begin
        insn_exe_q <= fetch_word;
        pc_exe_q   <= fetch_word_pc;
        rs1_q      <= reg_rdata_a;
        rs2_q      <= reg_rdata_b;
      end

      // EX -> WB: register ALU result and the effective address (loads/stores).
      if (phase_q == PH_EX) begin
        alu_result_q <= alu_result_comb;
        mem_addr_q   <= alu_result_comb;
      end

      // MEM: latch the memory response data.
      if ((phase_q == PH_MEM) && rsp_valid_i) begin
        mem_rdata_q <= rsp_rdata_i;
      end

      // Retire counter (WB edge).
      if (phase_q == PH_WB) begin
        order_q <= order_q + 64'd1;
      end

      // Word-available flag. Redirect (taken branch) squashes any pending
      // speculative word; accept consumes it.
      if (fetch_redirect) begin
        word_pending_q <= 1'b0;
      end else if (accept) begin
        word_pending_q <= 1'b0;
      end else if (fetch_word_valid) begin
        word_pending_q <= 1'b1;
      end
    end
  end

  // ---- SBus request mux (fetch during non-MEM phases, LSU during MEM) --------
  // Disjoint by construction: the fetch unit is idle during PH_MEM.
  assign req_valid_o = (phase_q == PH_MEM) ? 1'b1          : fetch_req_valid;
  assign req_we_o    = (phase_q == PH_MEM) && dec_is_store;
  assign req_addr_o  = (phase_q == PH_MEM) ? lsu_addr      : fetch_req_addr;
  assign req_be_o    = (phase_q == PH_MEM) ? lsu_be        : fetch_req_be;
  assign req_wdata_o = (phase_q == PH_MEM) ? lsu_wdata     : 32'h0;

  // ---- RVFI channel drive --------------------------------------------------------
  assign rvfi_valid     = (phase_q == PH_WB);
  assign rvfi_order     = order_q;
  assign rvfi_insn      = insn_exe_q;
  assign rvfi_trap      = 1'b0;  // M1: no traps (ecall/ebreak/csr retire as NOP)
  assign rvfi_halt      = 1'b0;
  assign rvfi_intr      = 1'b0;
  assign rvfi_mode      = 2'd0;  // U-Mode (RISCV_FORMAL_UMODE)
  assign rvfi_ixl       = 2'd1;  // XLEN=32

  assign rvfi_rs1_addr  = dec_rs1_addr;
  assign rvfi_rs2_addr  = dec_rs2_addr;
  assign rvfi_rs1_rdata = rs1_q;
  assign rvfi_rs2_rdata = rs2_q;
  // rd_addr is 0 for any retirement that does not write the register file.
  // The riscv-formal reg check builds its shadow register file from
  // rvfi_rd_addr/rvfi_rd_wdata of every retirement; a non-writing retirement
  // (NOP/ecall/ebreak/csr/garbage) must not look like a write to a random
  // register, or the shadow is poisoned and later reads spuriously fail.
  assign rvfi_rd_addr   = dec_rd_we ? dec_rd_addr : 5'd0;
  assign rvfi_rd_wdata  = dec_rd_we ? ((dec_rd_addr == 5'd0) ? 32'd0
                                                             : rd_wdata_comb)
                                    : 32'd0;
  assign rvfi_pc_rdata  = pc_exe_q;
  assign rvfi_pc_wdata  = (branch_taken || dec_is_jal || dec_is_jalr)
                          ? branch_target : seq_pc;

  assign rvfi_mem_addr  = ((phase_q == PH_WB) && (dec_is_load || dec_is_store))
                          ? lsu_addr : 32'd0;
  assign rvfi_mem_rmask = ((phase_q == PH_WB) && dec_is_load)  ? lsu_be  : 4'd0;
  assign rvfi_mem_wmask = ((phase_q == PH_WB) && dec_is_store) ? lsu_be  : 4'd0;
  assign rvfi_mem_rdata = ((phase_q == PH_WB) && dec_is_load)  ? mem_rdata_q : 32'd0;
  assign rvfi_mem_wdata = ((phase_q == PH_WB) && dec_is_store) ? lsu_wdata : 32'd0;

endmodule
