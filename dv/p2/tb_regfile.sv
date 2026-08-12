// up5k-rv -- M1 P2-2 testbench for regfile.sv.
//
// Directed, self-checking: writes, x0 semantics, back-to-back writes, write
// enable, independent read ports. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_regfile rtl/core/up5k_rv_pkg.sv \
//     rtl/core/regfile.sv dv/p2/tb_regfile.sv && vvp build/tb_regfile
// Expected: "PASS tb_regfile", exit 0.

module tb_regfile;

  logic        clk;
  logic        rst_ni;
  logic [ 4:0] waddr;
  logic [31:0] wdata;
  logic        we;
  logic [ 4:0] raddr_a;
  logic [ 4:0] raddr_b;
  logic [31:0] rdata_a;
  logic [31:0] rdata_b;

  int fail_count = 0;

  regfile u_dut (
    .clk_i     (clk),
    .rst_ni    (rst_ni),
    .waddr_i   (waddr),
    .wdata_i   (wdata),
    .we_i      (we),
    .raddr_a_i (raddr_a),
    .raddr_b_i (raddr_b),
    .rdata_a_o (rdata_a),
    .rdata_b_o (rdata_b)
  );

  // Clock.
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  task automatic check(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
      fail_count++;
    end
  endtask

  // Commit one write at the next edge.
  task automatic write(logic [4:0] addr, logic [31:0] data);
    waddr = addr;
    wdata = data;
    we    = 1;
    @(posedge clk);
    #1;
  endtask

  // Present an address pair and wait for the combinational read.
  task automatic read_pair(logic [4:0] a, logic [4:0] b);
    raddr_a = a;
    raddr_b = b;
    #1;
  endtask

  initial begin
    // Reset.
    rst_ni  = 0;
    waddr   = '0;
    wdata   = '0;
    we      = 0;
    raddr_a = '0;
    raddr_b = '0;
    @(posedge clk);
    rst_ni = 1;
    #1;

    // After reset every register reads 0.
    read_pair(5'd3, 5'd17);
    check(rdata_a, 32'd0, "reset read a");
    check(rdata_b, 32'd0, "reset read b");

    // Basic writes.
    write(5'd1, 32'h1111_1111);
    write(5'd2, 32'h2222_2222);
    write(5'd31, 32'hffff_ffff);
    read_pair(5'd1, 5'd2);
    check(rdata_a, 32'h1111_1111, "x1 write");
    check(rdata_b, 32'h2222_2222, "x2 write");
    read_pair(5'd31, 5'd1);
    check(rdata_a, 32'hffff_ffff, "x31 write");
    check(rdata_b, 32'h1111_1111, "x1 still");

    // x0: write ignored, read 0.
    write(5'd0, 32'hdead_beef);
    read_pair(5'd0, 5'd0);
    check(rdata_a, 32'd0, "x0 write ignored");
    check(rdata_b, 32'd0, "x0 read");

    // Back-to-back writes to the same register: last wins.
    write(5'd7, 32'h0a0a_0a0a);
    write(5'd7, 32'hb0b0_b0b0);
    read_pair(5'd7, 5'd7);
    check(rdata_a, 32'hb0b0_b0b0, "back-to-back last wins");
    check(rdata_b, 32'hb0b0_b0b0, "back-to-back read b");

    // Read ports are independent.
    write(5'd9, 32'h9000_0009);
    read_pair(5'd9, 5'd7);
    check(rdata_a, 32'h9000_0009, "port a independent");
    check(rdata_b, 32'hb0b0_b0b0, "port b independent");

    // Write enable deasserted: no change.
    waddr = 5'd11;
    wdata = 32'hcafe_cafe;
    we    = 0;
    @(posedge clk);
    #1;
    read_pair(5'd11, 5'd9);
    check(rdata_a, 32'd0, "no write when we=0");
    check(rdata_b, 32'h9000_0009, "x9 unchanged");

    if (fail_count == 0) begin
      $display("PASS tb_regfile");
    end else begin
      $display("FAIL tb_regfile (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
