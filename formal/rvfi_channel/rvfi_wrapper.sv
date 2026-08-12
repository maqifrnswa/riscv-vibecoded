// up5k-rv -- M1 Phase 1b RVFI adapter (wrapper) for the formal smoke.
//
// This module is the `rvfi_wrapper` that the riscv-formal testbench
// (formal/riscv-formal/checks/rvfi_testbench.sv) instantiates. It adapts the
// smoke core's RVFI channel to the riscv-formal harness expectations:
//
//   - Port names/roles match what rvfi_testbench connects: `clock`, `reset`,
//     and the base RVFI output channel (21 signals). Because we define no
//     optional riscv-formal features (no extamo / rollback / mem_fault / CSR /
//     bus), RVFI_CONN in the harness expands to exactly these base signals.
//   - The testbench's `reset` is mapped to the core's active-low async
//     `rst_ni` (`!reset`).
//   - The instruction under test is presented to the core on `insn_i`. This
//     port is intentionally NOT connected in rvfi_testbench, so in the sby
//     run it becomes a FREE primary input of the flattened design; the
//     riscv-formal checker constrains it to a valid ADDI encoding via its
//     `assume(spec_valid)` on rvfi_insn_addi.
//
// read_slang note: this wrapper (and smoke_core.sv) are read with `read_slang`
// while the riscv-formal harness/checker files are read with `read_verilog -sv`
// in the same sby [script] -- the D14/R11 mixing path under test. The wrapper
// therefore declares its ports explicitly (no dependence on rvfi_macros.vh).

module rvfi_wrapper (
  input         clock,
  input         reset,
  input  [31:0] insn_i,  // free instruction under test (unconnected -> free input)

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
  output [   31 : 0] rvfi_mem_wdata
);

  smoke_core u_smoke_core (
    .clk_i         (clock),
    .rst_ni        (!reset),
    .insn_i        (insn_i),
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
    .rvfi_mem_wdata(rvfi_mem_wdata)
  );

endmodule
