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
  output logic [31:0] rvfi_mem_wdata,

  // ---- RVFI CSR channel (M2 P1-4c, D7 set; mcycle is 64-bit) ----------------
  output logic [31:0] rvfi_csr_mstatus_rmask,
  output logic [31:0] rvfi_csr_mstatus_wmask,
  output logic [31:0] rvfi_csr_mstatus_rdata,
  output logic [31:0] rvfi_csr_mstatus_wdata,
  output logic [31:0] rvfi_csr_mtvec_rmask,
  output logic [31:0] rvfi_csr_mtvec_wmask,
  output logic [31:0] rvfi_csr_mtvec_rdata,
  output logic [31:0] rvfi_csr_mtvec_wdata,
  output logic [31:0] rvfi_csr_mepc_rmask,
  output logic [31:0] rvfi_csr_mepc_wmask,
  output logic [31:0] rvfi_csr_mepc_rdata,
  output logic [31:0] rvfi_csr_mepc_wdata,
  output logic [31:0] rvfi_csr_mcause_rmask,
  output logic [31:0] rvfi_csr_mcause_wmask,
  output logic [31:0] rvfi_csr_mcause_rdata,
  output logic [31:0] rvfi_csr_mcause_wdata,
  output logic [31:0] rvfi_csr_mtval_rmask,
  output logic [31:0] rvfi_csr_mtval_wmask,
  output logic [31:0] rvfi_csr_mtval_rdata,
  output logic [31:0] rvfi_csr_mtval_wdata,
  output logic [63:0] rvfi_csr_mcycle_rmask,
  output logic [63:0] rvfi_csr_mcycle_wmask,
  output logic [63:0] rvfi_csr_mcycle_rdata,
  output logic [63:0] rvfi_csr_mcycle_wdata
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
  // M2 additions.
  logic        dec_is_c;        // 16-bit (compressed) instruction
  logic        dec_is_csr;
  logic [11:0] dec_csr_addr;
  csr_op_e     dec_csr_op;
  logic        dec_csr_imm;
  logic        dec_is_ecall;
  logic        dec_is_ebreak;
  logic        dec_is_mret;
  logic        dec_is_illegal;

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
    .is_nop_o       (dec_is_nop),
    .is_c_o         (dec_is_c),
    .is_csr_o       (dec_is_csr),
    .csr_addr_o     (dec_csr_addr),
    .csr_op_o       (dec_csr_op),
    .csr_imm_o      (dec_csr_imm),
    .is_ecall_o     (dec_is_ecall),
    .is_ebreak_o    (dec_is_ebreak),
    .is_mret_o      (dec_is_mret),
    .is_illegal_o   (dec_is_illegal)
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

  // Read addresses come from the DECODER (M2): C-extension register fields
  // (SPN regs, SP) differ from the raw fetch_word bit positions, so the
  // decode of insn_exe_q drives the read during ID; the data is latched into
  // rs1_q/rs2_q at the ID->EX edge. The writeback of instruction i still
  // commits a full cycle before the ID read of i+1 (hazard-free, no bypass).
  regfile u_regfile (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .waddr_i   (dec_rd_addr),
    .wdata_i   (rd_wdata_comb),
    .we_i      (reg_we),
    .raddr_a_i (dec_rs1_addr),
    .raddr_b_i (dec_rs2_addr),
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
  logic [31:0] fetch_word_sel;  // selected halfword, zero-extended (C granularity)

  // M2: the fetched word is selected by PC[1] (16-bit granularity, D3);
  // seq_pc advances +2 for C instructions, +4 for 32-bit.
  assign fetch_word_sel = fetch_word_pc[1] ? {16'b0, fetch_word[31:16]}
                                           : {16'b0, fetch_word[15:0]};
  assign seq_pc        = pc_exe_q + (dec_is_c ? 32'd2 : 32'd4);
  assign branch_taken  = dec_is_branch && alu_branch_taken;
  assign branch_target = dec_is_jalr ? ((rs1_q + dec_imm) & ~32'h1)
                                     : (pc_exe_q + dec_imm);
  assign accept = (phase_q == PH_IDLE) && word_pending_q;

  // ---- trap machinery (M2 P1-4b; model-matched per design.md §3.3) --------------
  // Trap sources, combinational during EX (the misalign address is the ALU
  // result). mcause per design: 0 instr-addr-misaligned, 2 illegal, 3 ebreak,
  // 4 load / 6 store misaligned, 11 ecall-from-M. mtval = faulting address for
  // misaligned load/store, else 0.
  logic        trap_inst_misalign;
  logic        trap_illegal;
  logic        trap_ebreak;
  logic        trap_mem_mis;
  logic        trap_ecall;
  logic        trap_illegal_csr;
  logic        trap_pending;
  logic        mret_pending;
  logic [31:0] trap_mcause;
  logic [31:0] trap_mtval;
  logic        trap_exe_q;       // latched at EX->WB
  logic        mret_exe_q;
  logic [31:0] trap_mcause_q;
  logic [31:0] trap_mtval_q;
  logic [31:0] mtvec_val;
  logic [31:0] mepc_val;
  // Trap/mret CSR-update enables (computed here rather than inline in the
  // csr_file port connections -- the inline phase_q == PH_WB comparison in a
  // port connection breaks iverilog's enum typing for the phase FSM below).
  logic        csr_trap_enter;
  logic        csr_mret_enter;
  assign csr_trap_enter = (phase_q == PH_WB) && trap_exe_q;
  assign csr_mret_enter = (phase_q == PH_WB) && mret_exe_q;

  // Branch/jal trap on an odd target (32-bit only: c.j/c.jal never trap);
  // jalr never traps (target bit0 masked).
  assign trap_inst_misalign = (dec_is_branch || (dec_is_jal && !dec_is_c)) &&
                              branch_target[0];
  assign trap_illegal = dec_is_illegal;
  assign trap_ebreak  = dec_is_ebreak;
  assign trap_ecall   = dec_is_ecall;
  assign mret_pending = dec_is_mret;

  // Misaligned load/store per RISCV_FORMAL_ALIGNED_MEM (lb/lbu/sb never trap).
  // Loads and stores share funct3 values (lh==sh, lw==sw), so the load/store
  // flag disambiguates. Written as if/else (iverilog enum quirk: a
  // concatenation case selector breaks enum typing in later always blocks).
  always_comb begin
    trap_mem_mis = 1'b0;
    if (dec_is_load) begin
      if ((dec_lsu_funct3 == FUNCT3_LH) || (dec_lsu_funct3 == FUNCT3_LHU)) begin
        trap_mem_mis = alu_result_comb[0];
      end else if (dec_lsu_funct3 == FUNCT3_LW) begin
        trap_mem_mis = |alu_result_comb[1:0];
      end
    end else if (dec_is_store) begin
      if (dec_lsu_funct3 == FUNCT3_SH) begin
        trap_mem_mis = alu_result_comb[0];
      end else if (dec_lsu_funct3 == FUNCT3_SW) begin
        trap_mem_mis = |alu_result_comb[1:0];
      end
    end
  end

  assign trap_pending = trap_inst_misalign || trap_illegal || trap_ebreak ||
                        trap_mem_mis || trap_ecall || trap_illegal_csr;

  // Illegal CSR address: the D7 set only. Any other CSR instruction traps as
  // an illegal instruction (mcause=2).
  assign trap_illegal_csr = dec_is_csr &&
    (dec_csr_addr != 12'h300) && (dec_csr_addr != 12'h305) &&
    (dec_csr_addr != 12'h341) && (dec_csr_addr != 12'h342) &&
    (dec_csr_addr != 12'h343) && (dec_csr_addr != 12'hB00) &&
    (dec_csr_addr != 12'hB80);

  always_comb begin
    trap_mcause = 32'd0;
    trap_mtval  = 32'd0;
    if (trap_illegal || trap_illegal_csr) trap_mcause = 32'd2;
    if (trap_ebreak)  trap_mcause = 32'd3;
    if (trap_mem_mis) begin
      trap_mcause = dec_is_load ? 32'd4 : 32'd6;
      trap_mtval  = alu_result_comb;
    end
    if (trap_ecall) trap_mcause = 32'd11;
  end

  // ---- CSR instruction pipeline (M2 P1-4c) ------------------------------------
  // The csr_file read port is driven with the decoded CSR address; the read
  // value (pre-write) feeds rd_wdata at WB, and the write value commits at the
  // WB edge. CSR read-modify-write per the riscv-formal csrw model:
  //   rw: write operand always; rs/rc: write iff operand != 0.
  logic [31:0] csr_operand;   // rs1 (register form) or zimm (immediate form)
  logic [31:0] csr_new_val;
  logic        csr_write_en;
  logic [31:0] csr_rdata;
  logic [11:0] csr_addr;
  logic        csr_we;
  logic [31:0] csr_wdata;
  logic [63:0] mcycle_val;

  assign csr_addr     = dec_csr_addr;
  assign csr_operand  = dec_csr_imm ? {27'b0, insn_exe_q[19:15]} : rs1_q;
  assign csr_write_en = dec_is_csr && ((dec_csr_op == CSR_RW) ||
                                       (csr_operand != 32'd0));
  assign csr_new_val  = (dec_csr_op == CSR_RW) ? csr_operand :
                        (dec_csr_op == CSR_RS) ? (csr_rdata | csr_operand) :
                                                 (csr_rdata & ~csr_operand);
  assign csr_we       = (phase_q == PH_WB) && csr_write_en && !trap_exe_q;
  assign csr_wdata    = csr_new_val;

  // CSR file (D7): CSR-instruction access + trap entry/exit updates;
  // mtvec/mepc feed the redirects.
  csr_file u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .csr_addr_i    (csr_addr),
    .csr_rdata_o   (csr_rdata),
    .csr_we_i      (csr_we),
    .csr_wdata_i   (csr_wdata),
    .trap_enter_i  (csr_trap_enter),
    .trap_mepc_i   (pc_exe_q),
    .trap_mcause_i (trap_mcause_q),
    .trap_mtval_i  (trap_mtval_q),
    .mret_i        (csr_mret_enter),
    .mcycle_o      (mcycle_val),
    .mtvec_o       (mtvec_val),
    .mepc_o        (mepc_val)
  );

  // Next-instruction fetch scheduling (hazard-free schedule; see header).
  assign fetch_start = ((phase_q == PH_IDLE) && !word_pending_q) ||
                       ((phase_q == PH_ID)    && !dec_is_load && !dec_is_store) ||
                       ((phase_q == PH_MEM)   && rsp_valid_i);
  assign fetch_pc   = (phase_q == PH_IDLE) ? 32'h0  // reset vector (only IDLE-no-pending)
                                           : seq_pc;
  assign fetch_redirect  = (phase_q == PH_EX) &&
                           (branch_taken || dec_is_jal || dec_is_jalr ||
                            trap_pending || mret_pending);
  assign redirect_target = trap_pending  ? (mtvec_val & ~32'h3) :
                           mret_pending  ? mepc_val :
                           branch_target;

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
        // A trapping load/store skips MEM: no LSU request is issued, so a
        // misaligned store can never physically write memory (4.3).
        if ((dec_is_load || dec_is_store) && !trap_pending) begin
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

  // Writeback data (WB phase). CSR instructions write the pre-write CSR value
  // (read combinationally from the csr_file during WB).
  always_comb begin
    if (dec_is_csr) begin
      rd_wdata_comb = csr_rdata;
    end else if (dec_is_load) begin
      rd_wdata_comb = lsu_rd_data;
    end else if (dec_is_jal || dec_is_jalr) begin
      rd_wdata_comb = seq_pc;
    end else begin
      rd_wdata_comb = alu_result_q;
    end
  end

  // A trapping retirement commits no architectural state: no register write
  // (4.2), no memory access.
  assign reg_we = (phase_q == PH_WB) && dec_rd_we && (dec_rd_addr != 5'd0) &&
                  !trap_exe_q;

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
      trap_exe_q     <= 1'b0;
      mret_exe_q     <= 1'b0;
      trap_mcause_q  <= 32'd0;
      trap_mtval_q   <= 32'd0;
    end else begin
      phase_q <= phase_d;

      // Accept a fetched word into ID (one cycle after its capture, so
      // fetch_word/fetch_word_pc are stable here).
      if (accept) begin
        // C-ext granularity: the selected halfword is the instruction. A
        // 32-bit instruction is the full word only when the PC is 4-aligned;
        // a 32-bit-looking halfword at a 2-aligned PC executes zero-extended
        // (model-required execute-without-trap, Gate-1 finding 1.1).
        if (!fetch_word_pc[1] && (fetch_word_sel[1:0] == 2'b11)) begin
          insn_exe_q <= fetch_word;
        end else begin
          insn_exe_q <= fetch_word_sel;
        end
        pc_exe_q   <= fetch_word_pc;
      end

      // ID -> EX: latch the register-file operands. The read uses the
      // decoder's rs addresses during ID (C register fields need the C
      // decode); the previous instruction's WB commit is a full cycle before
      // this read, so no forwarding is required (hazard-free schedule).
      if (phase_q == PH_ID) begin
        rs1_q <= reg_rdata_a;
        rs2_q <= reg_rdata_b;
      end

      // EX -> WB: register ALU result, the effective address (loads/stores),
      // and the trap information (pending + mcause/mtval) for the WB retire.
      if (phase_q == PH_EX) begin
        alu_result_q   <= alu_result_comb;
        mem_addr_q     <= alu_result_comb;
        trap_exe_q     <= trap_pending;
        mret_exe_q     <= mret_pending;
        trap_mcause_q  <= trap_mcause;
        trap_mtval_q   <= trap_mtval;
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
  assign rvfi_trap      = trap_exe_q;  // M2: trap retirements report 1
  assign rvfi_halt      = 1'b0;
  assign rvfi_intr      = 1'b0;
  assign rvfi_mode      = 2'd3;  // M-mode (Gate-1 finding 4.1: [csrs] checks
                                 // require mode>=3 for M-CSR access)
  assign rvfi_ixl       = 2'd1;  // XLEN=32

  assign rvfi_rs1_addr  = dec_rs1_addr;
  assign rvfi_rs2_addr  = dec_rs2_addr;
  assign rvfi_rs1_rdata = rs1_q;
  assign rvfi_rs2_rdata = rs2_q;
  // rd_addr is 0 for any retirement that does not write the register file,
  // INCLUDING trap retirements (4.2): a trapping jal/branch must not look
  // like a write, or the riscv-formal reg check shadow is poisoned.
  assign rvfi_rd_addr   = (dec_rd_we && !trap_exe_q) ? dec_rd_addr : 5'd0;
  assign rvfi_rd_wdata  = (dec_rd_we && !trap_exe_q)
                          ? ((dec_rd_addr == 5'd0) ? 32'd0 : rd_wdata_comb)
                          : 32'd0;
  assign rvfi_pc_rdata  = pc_exe_q;
  assign rvfi_pc_wdata  = trap_exe_q ? (mtvec_val & ~32'h3) :
                          mret_exe_q ? mepc_val :
                          (branch_taken || dec_is_jal || dec_is_jalr)
                          ? branch_target : seq_pc;

  assign rvfi_mem_addr  = ((phase_q == PH_WB) && (dec_is_load || dec_is_store))
                          ? lsu_addr : 32'd0;
  // No access is reported for a trapping load/store (the LSU request was
  // suppressed at EX; the mem channel reports rmask/wmask = 0).
  assign rvfi_mem_rmask = ((phase_q == PH_WB) && dec_is_load  && !trap_exe_q)
                          ? lsu_be : 4'd0;
  assign rvfi_mem_wmask = ((phase_q == PH_WB) && dec_is_store && !trap_exe_q)
                          ? lsu_be : 4'd0;
  assign rvfi_mem_rdata = ((phase_q == PH_WB) && dec_is_load  && !trap_exe_q)
                          ? mem_rdata_q : 32'd0;
  assign rvfi_mem_wdata = ((phase_q == PH_WB) && dec_is_store && !trap_exe_q)
                          ? lsu_wdata : 32'd0;

  // ---- RVFI CSR channel drives (M2 P1-4c) ----------------------------------------
  // Per riscv-formal convention: rmask full on read (rd != 0), wmask = the
  // written bits (all-ones for csrrw, the operand for csrrs/csrrc), rdata =
  // the pre-write value, wdata = the value written. mcycle is 64-bit with the
  // accessed half in the mask/data (CSRWH half-consistency rule).
  logic csr_acc_mstatus, csr_acc_mtvec, csr_acc_mepc;
  logic csr_acc_mcause, csr_acc_mtval, csr_acc_mcycle;
  assign csr_acc_mstatus = (phase_q == PH_WB) && dec_is_csr && (dec_csr_addr == 12'h300);
  assign csr_acc_mtvec   = (phase_q == PH_WB) && dec_is_csr && (dec_csr_addr == 12'h305);
  assign csr_acc_mepc    = (phase_q == PH_WB) && dec_is_csr && (dec_csr_addr == 12'h341);
  assign csr_acc_mcause  = (phase_q == PH_WB) && dec_is_csr && (dec_csr_addr == 12'h342);
  assign csr_acc_mtval   = (phase_q == PH_WB) && dec_is_csr && (dec_csr_addr == 12'h343);
  assign csr_acc_mcycle  = (phase_q == PH_WB) && dec_is_csr &&
                           ((dec_csr_addr == 12'hB00) || (dec_csr_addr == 12'hB80));

  // 32-bit CSR channels.
  assign rvfi_csr_mstatus_rmask = csr_acc_mstatus && (dec_rd_addr != 5'd0)
                                  ? 32'hffff_ffff : 32'd0;
  assign rvfi_csr_mstatus_wmask = csr_acc_mstatus && csr_we
                                  ? ((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand)
                                  : 32'd0;
  assign rvfi_csr_mstatus_rdata = csr_acc_mstatus ? csr_rdata : 32'd0;
  assign rvfi_csr_mstatus_wdata = csr_acc_mstatus && csr_we ? csr_wdata : 32'd0;

  assign rvfi_csr_mtvec_rmask = csr_acc_mtvec && (dec_rd_addr != 5'd0)
                                ? 32'hffff_ffff : 32'd0;
  assign rvfi_csr_mtvec_wmask = csr_acc_mtvec && csr_we
                                ? ((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand)
                                : 32'd0;
  assign rvfi_csr_mtvec_rdata = csr_acc_mtvec ? csr_rdata : 32'd0;
  assign rvfi_csr_mtvec_wdata = csr_acc_mtvec && csr_we ? csr_wdata : 32'd0;

  assign rvfi_csr_mepc_rmask = csr_acc_mepc && (dec_rd_addr != 5'd0)
                               ? 32'hffff_ffff : 32'd0;
  assign rvfi_csr_mepc_wmask = csr_acc_mepc && csr_we
                               ? ((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand)
                               : 32'd0;
  assign rvfi_csr_mepc_rdata = csr_acc_mepc ? csr_rdata : 32'd0;
  assign rvfi_csr_mepc_wdata = csr_acc_mepc && csr_we ? csr_wdata : 32'd0;

  assign rvfi_csr_mcause_rmask = csr_acc_mcause && (dec_rd_addr != 5'd0)
                                 ? 32'hffff_ffff : 32'd0;
  assign rvfi_csr_mcause_wmask = csr_acc_mcause && csr_we
                                 ? ((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand)
                                 : 32'd0;
  assign rvfi_csr_mcause_rdata = csr_acc_mcause ? csr_rdata : 32'd0;
  assign rvfi_csr_mcause_wdata = csr_acc_mcause && csr_we ? csr_wdata : 32'd0;

  assign rvfi_csr_mtval_rmask = csr_acc_mtval && (dec_rd_addr != 5'd0)
                                ? 32'hffff_ffff : 32'd0;
  assign rvfi_csr_mtval_wmask = csr_acc_mtval && csr_we
                                ? ((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand)
                                : 32'd0;
  assign rvfi_csr_mtval_rdata = csr_acc_mtval ? csr_rdata : 32'd0;
  assign rvfi_csr_mtval_wdata = csr_acc_mtval && csr_we ? csr_wdata : 32'd0;

  // 64-bit mcycle channel (mcycleh access selects the high half).
  assign rvfi_csr_mcycle_rmask = csr_acc_mcycle && (dec_rd_addr != 5'd0)
    ? ((dec_csr_addr == 12'hB80) ? 64'hffff_ffff_0000_0000 : 64'h0000_0000_ffff_ffff)
    : 64'd0;
  assign rvfi_csr_mcycle_wmask = csr_acc_mcycle && csr_we
    ? ((dec_csr_addr == 12'hB80)
       ? {((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand), 32'd0}
       : {32'd0, ((dec_csr_op == CSR_RW) ? 32'hffff_ffff : csr_operand)})
    : 64'd0;
  assign rvfi_csr_mcycle_rdata = csr_acc_mcycle ? mcycle_val : 64'd0;
  assign rvfi_csr_mcycle_wdata = csr_acc_mcycle && csr_we
    ? ((dec_csr_addr == 12'hB80) ? {csr_wdata, mcycle_val[31:0]}
                                 : {mcycle_val[63:32], csr_wdata})
    : 64'd0;

endmodule
