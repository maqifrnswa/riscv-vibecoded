// up5k-rv -- M1 P3 / M2 P2: RVFI wrapper + memory model for riscv-formal.
//
// This module is the `rvfi_wrapper` that the riscv-formal testbench
// (formal/riscv-formal/checks/rvfi_testbench.sv) instantiates for the rv32imc
// prove. It adapts the real RV32IMC core (rtl/core/rv32i_core.sv) to the
// riscv-formal harness:
//
//   - Port names/roles match rvfi_testbench: `clock`, `reset`, the base RVFI
//     output channel (21 signals), and the `mcycle` CSR channel (64-bit) from
//     [csrs] in checks.cfg. No optional riscv-formal features are defined
//     (no extamo/rollback/mem_fault/bus), so RVFI_CONN expands to exactly
//     these signals and the ports are declared explicitly -- this is what lets
//     read_slang consume this file (no rvfi_macros.vh dependency).
//   - The testbench's `reset` maps to the core's active-low async `rst_ni`.
//   - Memory model: the core's single SBus master port is served by a
//     combinationally-ready slave; read data is a FREE PRIMARY INPUT
//     (`mem_rdata_i`, deliberately left unconnected at rvfi_testbench). This
//     is the picorv32 reference-binding pattern: instruction words, load data,
//     and the fetch stream are solver-chosen, and the riscv-formal checkers
//     constrain the retired instruction via `assume(spec_valid)` on the
//     channel.
//
// M2 (see formal/up5k_rv/checks.cfg): the M1 alignment [assume] block is gone
// -- the core traps on the model-pinned unaligned cases (spec_trap=1 checks).
// The CSR channel reports the mcycle counter family (64-bit mcycle channel
// covering mcycle/mcycleh via CSRWH).

module rvfi_wrapper (
  input         clock,
  input         reset,
  input  [31:0] mem_rdata_i,  // free memory read data (unconnected -> free input)

  // RVFI base output channel (NRET = 1).
  output [    0 : 0] rvfi_valid,
  output [   63 : 0] rvfi_order,
  output [   31 : 0] rvfi_insn,
  output [    0 : 0] rvfi_trap,
  output [    0 : 0] rvfi_halt,
  output [    0 : 0] rvfi_intr,
  output [    1 : 0] rvfi_mode,
  output [    1 : 0] rvfi_ixl,
  output [    4 : 0] rvfi_rs1_addr,
  output [    4 : 0] rvfi_rs2_addr,
  output [   31 : 0] rvfi_rs1_rdata,
  output [   31 : 0] rvfi_rs2_rdata,
  output [    4 : 0] rvfi_rd_addr,
  output [   31 : 0] rvfi_rd_wdata,
  output [   31 : 0] rvfi_pc_rdata,
  output [   31 : 0] rvfi_pc_wdata,
  output [   31 : 0] rvfi_mem_addr,
  output [    3 : 0] rvfi_mem_rmask,
  output [    3 : 0] rvfi_mem_wmask,
  output [   31 : 0] rvfi_mem_rdata,
  output [   31 : 0] rvfi_mem_wdata,

  // RVFI CSR channel (M2: [csrs] mcycle; 64-bit per the riscv-formal
  // counter convention, covering mcycle/mcycleh via CSRWH).
  output [   63 : 0] rvfi_csr_mcycle_rmask,
  output [   63 : 0] rvfi_csr_mcycle_wmask,
  output [   63 : 0] rvfi_csr_mcycle_rdata,
  output [   63 : 0] rvfi_csr_mcycle_wdata
);

  // ---- core SBus master ------------------------------------------------------
  logic        req_valid;
  logic        req_we;
  logic [31:0] req_addr;
  logic [ 3:0] req_be;
  logic [31:0] req_wdata;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  // M1 memory slave: combinationally ready (rsp_valid_i = f(req_valid_o)),
  // read data from the free input. The core holds a request until ack, so a
  // combinational ack completes every access in one cycle.
  assign rsp_valid = req_valid;
  assign rsp_rdata = mem_rdata_i;

  rv32i_core u_core (
    .clk_i         (clock),
    .rst_ni        (!reset),

    .req_valid_o   (req_valid),
    .req_we_o      (req_we),
    .req_addr_o    (req_addr),
    .req_be_o      (req_be),
    .req_wdata_o   (req_wdata),
    .rsp_valid_i   (rsp_valid),
    .rsp_rdata_i   (rsp_rdata),

    .rvfi_valid    (rvfi_valid),
    .rvfi_order    (rvfi_order),
    .rvfi_insn     (rvfi_insn),
    .rvfi_trap     (rvfi_trap),
    .rvfi_halt     (rvfi_halt),
    .rvfi_intr     (rvfi_intr),
    .rvfi_mode     (rvfi_mode),
    .rvfi_ixl      (rvfi_ixl),
    .rvfi_rs1_addr (rvfi_rs1_addr),
    .rvfi_rs2_addr (rvfi_rs2_addr),
    .rvfi_rs1_rdata(rvfi_rs1_rdata),
    .rvfi_rs2_rdata(rvfi_rs2_rdata),
    .rvfi_rd_addr  (rvfi_rd_addr),
    .rvfi_rd_wdata (rvfi_rd_wdata),
    .rvfi_pc_rdata (rvfi_pc_rdata),
    .rvfi_pc_wdata (rvfi_pc_wdata),
    .rvfi_mem_addr (rvfi_mem_addr),
    .rvfi_mem_rmask(rvfi_mem_rmask),
    .rvfi_mem_wmask(rvfi_mem_wmask),
    .rvfi_mem_rdata(rvfi_mem_rdata),
    .rvfi_mem_wdata(rvfi_mem_wdata),
    .rvfi_csr_mcycle_rmask (rvfi_csr_mcycle_rmask),
    .rvfi_csr_mcycle_wmask (rvfi_csr_mcycle_wmask),
    .rvfi_csr_mcycle_rdata (rvfi_csr_mcycle_rdata),
    .rvfi_csr_mcycle_wdata (rvfi_csr_mcycle_wdata)
  );

endmodule
