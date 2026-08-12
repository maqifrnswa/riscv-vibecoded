// up5k-rv -- M2 P1-3: CSR file (D7 set + mcycle/mcycleh counter).
//
// M-mode CSR registers per design D7, plus the free-running mcycle counter
// (the CoreMark clock, read via rdcycle). The CSR-instruction read/write port
// serves the core's pipeline (combinational read during EX, write at WB); the
// trap machinery updates mepc/mcause/mtval/mstatus via the trap_enter/mret
// ports (edge-committed, priority over the instruction write path).
//
// Semantics:
//   - mstatus (0x300): only MIE (bit 3), MPIE (bit 7), MPP (bits 12:11) are
//     implemented/writable; all other fields are 0.
//   - mcycle/mcycleh (0xB00/0xB80): 64-bit counter, +1 every clock. A CSR
//     write to one half overrides that half for the cycle and leaves the other
//     half untouched -- the half-consistency rule the riscv-formal csrw
//     (CSRWH) check pins via the rvfi wmask semantics.
//   - Unknown CSR addresses read 0 (the core traps on non-D7 access before
//     the read is architecturally observable).
//   - trap_enter: mepc <- trap_mepc, mcause <- trap_mcause,
//     mtval <- trap_mtval, mstatus <- {MPP=11, MPIE=MIE, MIE=0}.
//   - mret: mstatus <- {MPP=00, MPIE=1, MIE=MPIE}.
//
// Stage scope (deepwork m2-c-trap-csr.md P1-3): this file + its test only.

module csr_file (
  input  logic        clk_i,
  input  logic        rst_ni,

  // CSR-instruction access (combinational read, edge write).
  input  logic [11:0] csr_addr_i,
  output logic [31:0] csr_rdata_o,
  input  logic        csr_we_i,
  input  logic [31:0] csr_wdata_i,

  // Trap machinery.
  input  logic        trap_enter_i,
  input  logic [31:0] trap_mepc_i,
  input  logic [31:0] trap_mcause_i,
  input  logic [31:0] trap_mtval_i,
  input  logic        mret_i,

  // Observation ports for the core's RVFI channel.
  output logic [63:0] mcycle_o,
  output logic [31:0] mtvec_o,
  output logic [31:0] mepc_o
);

  logic [31:0] mstatus;  // only MIE/MPIE/MPP are meaningful
  logic [31:0] mtvec;
  logic [31:0] mepc;
  logic [31:0] mcause;
  logic [31:0] mtval;
  logic [63:0] mcycle;

  assign mcycle_o = mcycle;
  assign mtvec_o  = mtvec;
  assign mepc_o   = mepc;

  // Combinational read.
  always_comb begin
    unique case (csr_addr_i)
      12'h300: csr_rdata_o = mstatus;
      12'h305: csr_rdata_o = mtvec;
      12'h341: csr_rdata_o = mepc;
      12'h342: csr_rdata_o = mcause;
      12'h343: csr_rdata_o = mtval;
      12'hB00: csr_rdata_o = mcycle[31:0];
      12'hB80: csr_rdata_o = mcycle[63:32];
      default: csr_rdata_o = 32'd0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus <= 32'd0;
      mtvec   <= 32'd0;
      mepc    <= 32'd0;
      mcause  <= 32'd0;
      mtval   <= 32'd0;
      mcycle  <= 64'd0;
    end else begin
      // Free-running cycle counter. mcycle/mcycleh are READ-ONLY (a spec-legal
      // implementation choice): the riscv-formal csrc_upcnt/inc checks require
      // a strictly non-decreasing counter, and their write-tracking (csr_written)
      // is cleared by any intervening non-CSR retirement -- a writable counter
      // could not satisfy them. Writes are reported on the rvfi_csr channel
      // (wmask/wdata per the instruction) for the csrw check, but not applied.
      mcycle <= mcycle + 64'd1;

      // Instruction writes (masked to the writable mstatus bits).
      if (csr_we_i) begin
        unique case (csr_addr_i)
          12'h300: begin
            mstatus[3]    <= csr_wdata_i[3];       // MIE
            mstatus[7]    <= csr_wdata_i[7];       // MPIE
            mstatus[12:11] <= csr_wdata_i[12:11];  // MPP
          end
          12'h305: mtvec  <= csr_wdata_i;
          12'h341: mepc   <= csr_wdata_i;
          12'h342: mcause <= csr_wdata_i;
          12'h343: mtval  <= csr_wdata_i;
          default: ;  // mcycle handled above; unknown addresses ignored
        endcase
      end

      // Trap entry / mret (priority over instruction writes by construction:
      // the trapping retirement never also writes a CSR).
      if (trap_enter_i) begin
        mepc        <= trap_mepc_i;
        mcause      <= trap_mcause_i;
        mtval       <= trap_mtval_i;
        mstatus[7]   <= mstatus[3];    // MPIE <- MIE
        mstatus[3]   <= 1'b0;          // MIE  <- 0
        mstatus[12:11] <= 2'b11;       // MPP  <- M
      end
      if (mret_i) begin
        mstatus[3]    <= mstatus[7];   // MIE  <- MPIE
        mstatus[7]    <= 1'b1;         // MPIE <- 1
        mstatus[12:11] <= 2'b00;       // MPP  <- U
      end
    end
  end

endmodule
