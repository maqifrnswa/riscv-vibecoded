// up5k-rv -- M1 P2-5 testbench for lsu.sv.
//
// Directed, self-checking: every load/store type at every byte lane (aligned
// addresses only -- misaligned handling is M2). Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_lsu rtl/core/up5k_rv_pkg.sv \
//     rtl/core/lsu.sv dv/p2/tb_lsu.sv && vvp build/tb_lsu
// Expected: "PASS tb_lsu", exit 0.

module tb_lsu;

  import up5k_rv_pkg::*;

  logic [31:0] addr;
  logic [ 2:0] funct3;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic [31:0] addr_o;
  logic [ 3:0] be_o;
  logic        store;
  logic [31:0] wdata_o;
  logic [31:0] rd_data_o;

  int fail_count = 0;

  lsu u_dut (
    .addr_i    (addr),
    .funct3_i  (funct3),
    .store_i   (store),
    .wdata_i   (wdata),
    .rdata_i   (rdata),
    .addr_o    (addr_o),
    .be_o      (be_o),
    .wdata_o   (wdata_o),
    .rd_data_o (rd_data_o)
  );

  task automatic check32(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check4(logic [3:0] got, logic [3:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %b exp %b", name, got, exp);
      fail_count++;
    end
  endtask

  initial begin
    addr   = '0;
    funct3 = '0;
    wdata  = '0;
    store  = 0;
    rdata  = 32'hDDCC_BBAA;
    #1;

    // ---- loads: all lanes, sign/zero extension ------------------------------
    addr = 32'h0000_1000;  // lane 0
    funct3 = FUNCT3_LB;
    #1;
    check32(rd_data_o, 32'hffff_ffaa, "lb lane0");
    check4 (be_o, 4'b0001, "lb be lane0");

    addr = 32'h0000_1001;  // lane 1
    #1;
    check32(rd_data_o, 32'hffff_ffbb, "lb lane1");
    check4 (be_o, 4'b0010, "lb be lane1");

    addr = 32'h0000_1003;  // lane 3
    #1;
    check32(rd_data_o, 32'hffff_ffdd, "lb lane3");
    check4 (be_o, 4'b1000, "lb be lane3");

    funct3 = FUNCT3_LBU;
    addr = 32'h0000_1000;
    #1;
    check32(rd_data_o, 32'h0000_00aa, "lbu lane0");
    addr = 32'h0000_1002;
    #1;
    check32(rd_data_o, 32'h0000_00cc, "lbu lane2");
    check4 (be_o, 4'b0100, "lbu be lane2");

    funct3 = FUNCT3_LH;
    addr = 32'h0000_1000;  // half 0
    #1;
    check32(rd_data_o, 32'hffff_bbaa, "lh half0");
    check4 (be_o, 4'b0011, "lh be half0");
    addr = 32'h0000_1002;  // half 1
    #1;
    check32(rd_data_o, 32'hffff_ddcc, "lh half1");
    check4 (be_o, 4'b1100, "lh be half1");

    funct3 = FUNCT3_LHU;
    addr = 32'h0000_1000;
    #1;
    check32(rd_data_o, 32'h0000_bbaa, "lhu half0");
    addr = 32'h0000_1002;
    #1;
    check32(rd_data_o, 32'h0000_ddcc, "lhu half1");

    funct3 = FUNCT3_LW;
    addr = 32'h0000_1000;
    #1;
    check32(rd_data_o, 32'hddcc_bbaa, "lw");
    check4 (be_o, 4'b1111, "lw be");

    // ---- stores: lane placement + be -----------------------------------------
    wdata = 32'h1122_3344;
    store = 1;

    funct3 = FUNCT3_SB;
    addr = 32'h0000_2000;
    #1;
    check32(wdata_o, 32'h0000_0044, "sb lane0 data");
    check4 (be_o, 4'b0001, "sb be lane0");
    addr = 32'h0000_2001;
    #1;
    check32(wdata_o, 32'h0000_4400, "sb lane1 data");
    check4 (be_o, 4'b0010, "sb be lane1");
    addr = 32'h0000_2003;
    #1;
    check32(wdata_o, 32'h4400_0000, "sb lane3 data");
    check4 (be_o, 4'b1000, "sb be lane3");

    funct3 = FUNCT3_SH;
    addr = 32'h0000_2000;
    #1;
    check32(wdata_o, 32'h0000_3344, "sh half0 data");
    check4 (be_o, 4'b0011, "sh be half0");
    addr = 32'h0000_2002;
    #1;
    check32(wdata_o, 32'h3344_0000, "sh half1 data");
    check4 (be_o, 4'b1100, "sh be half1");

    funct3 = FUNCT3_SW;
    addr = 32'h0000_2000;
    #1;
    check32(wdata_o, 32'h1122_3344, "sw data");
    check4 (be_o, 4'b1111, "sw be");

    // ---- address alignment ----------------------------------------------------
    addr = 32'h0000_1007;
    funct3 = FUNCT3_LW;
    #1;
    check32(addr_o, 32'h0000_1004, "addr_o alignment 7->4");
    addr = 32'h2000_0003;
    #1;
    check32(addr_o, 32'h2000_0000, "addr_o alignment 3->0");
    addr = 32'hffff_fffe;
    #1;
    check32(addr_o, 32'hffff_fffc, "addr_o alignment -2");

    if (fail_count == 0) begin
      $display("PASS tb_lsu");
    end else begin
      $display("FAIL tb_lsu (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
