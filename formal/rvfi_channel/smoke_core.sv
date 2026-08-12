// up5k-rv -- M1 Phase 1b formal-toolchain smoke core.
//
// A deliberately TRIVIAL RV32I core that retires exactly ONE class of
// instruction -- ADDI -- on the RVFI channel, in SystemVerilog, intended to be
// read by Yosys `read_slang`. Its only purpose is to prove the D14/R11 mixing
// path end-to-end: our SystemVerilog RTL (read_slang) verified against the
// riscv-formal Verilog checker harness (read_verilog -sv) in one sby run, and
// to validate the RVFI channel conventions the real M1 core will reuse.
//
// This is NOT a synthesizable / architectural core. It is a formal smoke
// fixture. The instruction word is presented on `insn_i` (a free variable
// constrained to a valid ADDI encoding by the riscv-formal checker, which
// assumes spec_valid on the model rvfi_insn_addi). The core decodes that word
// and produces the architecturally-correct ADDI retirement on the RVFI output
// channel.
//
// RVFI conventions pinned here (mirroring the picorv32 reference binding):
//   - rvfi_valid is asserted every cycle the core retires an instruction
//     (here: every cycle out of reset, one instruction per cycle).
//   - rvfi_order is the zero-based, gap-free retired-instruction index.
//   - rvfi_insn carries the full 32-bit retired instruction word.
//   - rvfi_rs1_addr/rs2_addr/rd_addr are the decoded register fields; rdata
//     are the PRE-state values (x0 reads as 0); rd_wdata is the POST-state
//     result (0 when rd == x0).
//   - rvfi_pc_rdata is the address of the retired instruction; rvfi_pc_wdata
//     is pc + 4 for ADDI (non-branch).
//   - rvfi_mem_* are all tied to 0 (ADDI performs no memory access).
//   - rvfi_trap/halt/intr = 0; rvfi_mode = 0 (U-Mode, RISCV_FORMAL_UMODE);
//     rvfi_ixl = 1 (XLEN=32).
//
// Style per docs/standards.md: clk_i/rst_ni, active-low async reset, plain
// scalar ports (no interfaces / struct literals), one module per file.

module smoke_core (
  // Clock / reset (active-low async).
  input  logic        clk_i,
  input  logic        rst_ni,

  // Free instruction under test. Constrained by the riscv-formal checker to a
  // valid ADDI encoding; the core decodes it and retires it on RVFI.
  input  logic [31:0] insn_i,

  // ---- RVFI output channel (single retirement, NRET=1) ---------------------
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

  // ---- Architectural state -------------------------------------------------
  // 32 x 32 register file (x0 hardwired to 0) and the program counter.
  logic [31:0] regfile [32];
  logic [31:0] pc_q;
  logic [63:0] order_q; // zero-based, gap-free retired-instruction index

  // ---- ADDI decode ---------------------------------------------------------
  // I-type format. imm is the sign-extended 12-bit immediate.
  logic [ 4:0] rs1_addr;
  logic [ 4:0] rd_addr;
  logic [31:0] imm;
  logic [31:0] rs1_rdata;
  logic [31:0] rd_wdata;
  logic [31:0] pc_wdata;

  always_comb begin
    rs1_addr = insn_i[19:15];
    rd_addr  = insn_i[11: 7];
    imm      = {{20{insn_i[31]}}, insn_i[31:20]};
    rs1_rdata = regfile[rs1_addr];
    // ADDI semantics: rd = rs1 + sext(imm); x0 never written.
    rd_wdata  = (rd_addr == 5'd0) ? 32'd0 : (rs1_rdata + imm);
    pc_wdata  = pc_q + 32'd4;
  end

  // ---- Register file / PC update -------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < 32; i++) begin
        regfile[i] <= 32'd0;
      end
      pc_q <= 32'd0;
      order_q <= 64'd0;
    end else begin
      regfile[rd_addr] <= rd_wdata;
      pc_q             <= pc_wdata;
      order_q          <= order_q + 64'd1;
    end
  end

  // ---- RVFI channel drive ---------------------------------------------------
  // Retire one instruction every cycle (out of reset). x0 read returns 0.
  assign rvfi_valid     = rst_ni ? 1'b1 : 1'b0;
  assign rvfi_order     = order_q;

  assign rvfi_insn      = insn_i;
  assign rvfi_trap      = 1'b0;
  assign rvfi_halt      = 1'b0;
  assign rvfi_intr      = 1'b0;
  assign rvfi_mode      = 2'd0;  // U-Mode (RISCV_FORMAL_UMODE)
  assign rvfi_ixl       = 2'd1;  // 32-bit (XLEN=32)

  assign rvfi_rs1_addr  = rs1_addr;
  assign rvfi_rs2_addr  = 5'd0;  // ADDI has no rs2
  assign rvfi_rs1_rdata = (rs1_addr == 5'd0) ? 32'd0 : rs1_rdata;
  assign rvfi_rs2_rdata = 32'd0;
  assign rvfi_rd_addr   = rd_addr;
  assign rvfi_rd_wdata  = rd_wdata;
  assign rvfi_pc_rdata  = pc_q;
  assign rvfi_pc_wdata  = pc_wdata;

  // No memory access for ADDI.
  assign rvfi_mem_addr  = 32'd0;
  assign rvfi_mem_rmask = 4'd0;
  assign rvfi_mem_wmask = 4'd0;
  assign rvfi_mem_rdata = 32'd0;
  assign rvfi_mem_wdata = 32'd0;

endmodule
