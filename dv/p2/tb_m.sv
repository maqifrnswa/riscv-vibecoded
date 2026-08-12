// up5k-rv -- M2 P1-5 testbench: M-extension (ALTOPS) ops through the core.
//
// Verifies the D18 ALTOPS fake ops retire through the full pipeline (decode ->
// EX -> WB) with the byte-exact rd_wdata the rv32imc models assert. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_m rtl/core/up5k_rv_pkg.sv \
//     rtl/core/decoder.sv rtl/core/regfile.sv rtl/core/alu.sv \
//     rtl/core/lsu.sv rtl/core/fetch_unit.sv rtl/core/csr_file.sv \
//     rtl/core/rv32i_core.sv dv/p2/tb_m.sv && vvp build/tb_m
// Expected: "PASS tb_m", exit 0.

module tb_m;

  import up5k_rv_pkg::*;

  logic        clk;
  logic        rst_ni;

  logic        req_valid;
  logic        req_we;
  logic [31:0] req_addr;
  logic [ 3:0] req_be;
  logic [31:0] req_wdata;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  logic        rvfi_valid;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn;
  logic        rvfi_trap;
  logic        rvfi_halt;
  logic        rvfi_intr;
  logic [ 1:0] rvfi_mode;
  logic [ 1:0] rvfi_ixl;
  logic [ 4:0] rvfi_rs1_addr;
  logic [ 4:0] rvfi_rs2_addr;
  logic [31:0] rvfi_rs1_rdata;
  logic [31:0] rvfi_rs2_rdata;
  logic [ 4:0] rvfi_rd_addr;
  logic [31:0] rvfi_rd_wdata;
  logic [31:0] rvfi_pc_rdata;
  logic [31:0] rvfi_pc_wdata;
  logic [31:0] rvfi_mem_addr;
  logic [ 3:0] rvfi_mem_rmask;
  logic [ 3:0] rvfi_mem_wmask;
  logic [31:0] rvfi_mem_rdata;
  logic [31:0] rvfi_mem_wdata;
  logic [31:0] rvfi_csr_mstatus_rmask, rvfi_csr_mstatus_wmask;
  logic [31:0] rvfi_csr_mstatus_rdata, rvfi_csr_mstatus_wdata;
  logic [31:0] rvfi_csr_mtvec_rmask, rvfi_csr_mtvec_wmask;
  logic [31:0] rvfi_csr_mtvec_rdata, rvfi_csr_mtvec_wdata;
  logic [31:0] rvfi_csr_mepc_rmask, rvfi_csr_mepc_wmask;
  logic [31:0] rvfi_csr_mepc_rdata, rvfi_csr_mepc_wdata;
  logic [31:0] rvfi_csr_mcause_rmask, rvfi_csr_mcause_wmask;
  logic [31:0] rvfi_csr_mcause_rdata, rvfi_csr_mcause_wdata;
  logic [31:0] rvfi_csr_mtval_rmask, rvfi_csr_mtval_wmask;
  logic [31:0] rvfi_csr_mtval_rdata, rvfi_csr_mtval_wdata;
  logic [63:0] rvfi_csr_mcycle_rmask, rvfi_csr_mcycle_wmask;
  logic [63:0] rvfi_csr_mcycle_rdata, rvfi_csr_mcycle_wdata;

  rv32i_core u_dut (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_o(req_valid), .req_we_o(req_we), .req_addr_o(req_addr),
    .req_be_o(req_be), .req_wdata_o(req_wdata), .rsp_valid_i(rsp_valid),
    .rsp_rdata_i(rsp_rdata),
    .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn),
    .rvfi_trap(rvfi_trap), .rvfi_halt(rvfi_halt), .rvfi_intr(rvfi_intr),
    .rvfi_mode(rvfi_mode), .rvfi_ixl(rvfi_ixl),
    .rvfi_rs1_addr(rvfi_rs1_addr), .rvfi_rs2_addr(rvfi_rs2_addr),
    .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata),
    .rvfi_rd_addr(rvfi_rd_addr), .rvfi_rd_wdata(rvfi_rd_wdata),
    .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
    .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask),
    .rvfi_mem_wmask(rvfi_mem_wmask), .rvfi_mem_rdata(rvfi_mem_rdata),
    .rvfi_mem_wdata(rvfi_mem_wdata),
    .rvfi_csr_mstatus_rmask(rvfi_csr_mstatus_rmask),
    .rvfi_csr_mstatus_wmask(rvfi_csr_mstatus_wmask),
    .rvfi_csr_mstatus_rdata(rvfi_csr_mstatus_rdata),
    .rvfi_csr_mstatus_wdata(rvfi_csr_mstatus_wdata),
    .rvfi_csr_mtvec_rmask(rvfi_csr_mtvec_rmask),
    .rvfi_csr_mtvec_wmask(rvfi_csr_mtvec_wmask),
    .rvfi_csr_mtvec_rdata(rvfi_csr_mtvec_rdata),
    .rvfi_csr_mtvec_wdata(rvfi_csr_mtvec_wdata),
    .rvfi_csr_mepc_rmask(rvfi_csr_mepc_rmask),
    .rvfi_csr_mepc_wmask(rvfi_csr_mepc_wmask),
    .rvfi_csr_mepc_rdata(rvfi_csr_mepc_rdata),
    .rvfi_csr_mepc_wdata(rvfi_csr_mepc_wdata),
    .rvfi_csr_mcause_rmask(rvfi_csr_mcause_rmask),
    .rvfi_csr_mcause_wmask(rvfi_csr_mcause_wmask),
    .rvfi_csr_mcause_rdata(rvfi_csr_mcause_rdata),
    .rvfi_csr_mcause_wdata(rvfi_csr_mcause_wdata),
    .rvfi_csr_mtval_rmask(rvfi_csr_mtval_rmask),
    .rvfi_csr_mtval_wmask(rvfi_csr_mtval_wmask),
    .rvfi_csr_mtval_rdata(rvfi_csr_mtval_rdata),
    .rvfi_csr_mtval_wdata(rvfi_csr_mtval_wdata),
    .rvfi_csr_mcycle_rmask(rvfi_csr_mcycle_rmask),
    .rvfi_csr_mcycle_wmask(rvfi_csr_mcycle_wmask),
    .rvfi_csr_mcycle_rdata(rvfi_csr_mcycle_rdata),
    .rvfi_csr_mcycle_wdata(rvfi_csr_mcycle_wdata)
  );

  logic [31:0] mem [0:65535];
  assign rsp_valid = req_valid;
  assign rsp_rdata = mem[req_addr[31:2]];
  always_ff @(posedge clk) begin
    if (req_valid && req_we) begin
      if (req_be[0]) mem[req_addr[31:2]][ 7: 0] <= req_wdata[ 7: 0];
      if (req_be[1]) mem[req_addr[31:2]][15: 8] <= req_wdata[15: 8];
      if (req_be[2]) mem[req_addr[31:2]][23:16] <= req_wdata[23:16];
      if (req_be[3]) mem[req_addr[31:2]][31:24] <= req_wdata[31:24];
    end
  end

  // captured retires
  logic [31:0] c_insn     [0:10];
  logic [31:0] c_pc_rdata [0:10];
  logic [31:0] c_pc_wdata [0:10];
  logic        c_trap     [0:10];
  logic [ 4:0] c_rd_addr  [0:10];
  logic [31:0] c_rd_wdata [0:10];
  logic [31:0] c_rs1_rdata[0:10];
  logic [31:0] c_rs2_rdata[0:10];

  int fail_count = 0;

  task automatic check32(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check5(logic [4:0] got, logic [4:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %05b exp %05b", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_bit(logic got, logic exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %b exp %b", name, got, exp);
      fail_count++;
    end
  endtask

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  task automatic reset_core();
    rst_ni = 0;
    @(posedge clk);
    @(posedge clk);
    rst_ni = 1;
    #1;
  endtask

  task automatic run_until(int n);
    int seen = 0;
    for (int cyc = 0; cyc < 2000 && seen < n; cyc++) begin
      @(posedge clk);
      #1;
      if (rvfi_valid) begin
        c_insn[seen]      = rvfi_insn;
        c_pc_rdata[seen]  = rvfi_pc_rdata;
        c_pc_wdata[seen]  = rvfi_pc_wdata;
        c_trap[seen]      = rvfi_trap;
        c_rd_addr[seen]   = rvfi_rd_addr;
        c_rd_wdata[seen]  = rvfi_rd_wdata;
        c_rs1_rdata[seen] = rvfi_rs1_rdata;
        c_rs2_rdata[seen] = rvfi_rs2_rdata;
        seen++;
      end
    end
    if (seen < n) begin
      $display("FAIL run_until: only %0d retires in 2000 cycles", seen);
      fail_count++;
    end
  endtask

  initial begin
    // addi x1,x0,5 / addi x2,x0,7 / mul x3,x1,x2 / div x4,x1,x2 /
    // remu x5,x1,x2 / mulh x6,x1,x2
    mem[32'h0000_0000 >> 2] = 32'h0050_0093;
    mem[32'h0000_0004 >> 2] = 32'h0070_0113;
    mem[32'h0000_0008 >> 2] = 32'h0220_81b3;  // mul  x3, x1, x2 (funct7=0000001)
    mem[32'h0000_000c >> 2] = 32'h0220_c233;  // div  x4, x1, x2
    mem[32'h0000_0010 >> 2] = 32'h0220_f2b3;  // remu x5, x1, x2
    mem[32'h0000_0014 >> 2] = 32'h0220_9333;  // mulh x6, x1, x2
    #1;
    reset_core();
    run_until(6);

    check_bit(c_trap[2], 1'b0, "mul not trap");
    check5 (c_rd_addr[2], 5'd3, "mul rd");
    // ALTOPS: (rs1 + rs2) ^ mask_low32 = (5+7) ^ 0x5876063e
    check32(c_rd_wdata[2], (32'd12 ^ 32'h5876063e), "mul rd_wdata (5+7)^mask");

    check5 (c_rd_addr[3], 5'd4, "div rd");
    // ALTOPS: (rs1 - rs2) ^ 0x7f8529ec = (5-7) ^ mask
    check32(c_rd_wdata[3], (32'hffff_fffe ^ 32'h7f8529ec), "div rd_wdata (5-7)^mask");

    check5 (c_rd_addr[4], 5'd5, "remu rd");
    // ALTOPS: (rs1 - rs2) ^ 0x3138d0e1 = (5-7) ^ mask
    check32(c_rd_wdata[4], (32'hffff_fffe ^ 32'h3138d0e1), "remu rd_wdata (5-7)^mask");

    check5 (c_rd_addr[5], 5'd6, "mulh rd");
    // ALTOPS: (rs1 + rs2) ^ 0xf6583fb7 = (5+7) ^ mask
    check32(c_rd_wdata[5], (32'd12 ^ 32'hf6583fb7), "mulh rd_wdata (5+7)^mask");

    // rs1/rs2 pre-state reported on the M retires.
    check32(c_rs1_rdata[2], 32'd5, "mul rs1_rdata");
    check32(c_rs2_rdata[2], 32'd7, "mul rs2_rdata");

    if (fail_count == 0) begin
      $display("PASS tb_m");
    end else begin
      $display("FAIL tb_m (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
