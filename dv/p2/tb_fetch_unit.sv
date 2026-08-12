// up5k-rv -- M1 P2-6 testbench for fetch_unit.sv.
//
// Directed, self-checking: initial fetch, back-to-back fetches, redirect
// while idle, redirect mid-fetch (aborted request not captured), and a
// 1-cycle-latency slave on the non-redirect path. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_fetch_unit rtl/core/up5k_rv_pkg.sv \
//     rtl/core/fetch_unit.sv dv/p2/tb_fetch_unit.sv && vvp build/tb_fetch_unit
// Expected: "PASS tb_fetch_unit", exit 0.

module tb_fetch_unit;

  import up5k_rv_pkg::*;

  logic        clk;
  logic        rst_ni;
  logic        start;
  logic [31:0] fetch_pc;
  logic        redirect;
  logic [31:0] redirect_target;
  logic [31:0] word;
  logic [31:0] word_pc;
  logic        word_valid;
  logic        req_valid;
  logic [31:0] req_addr;
  logic [ 3:0] req_be;
  logic        rsp_valid;
  logic [31:0] rsp_rdata;

  int fail_count = 0;

  fetch_unit u_dut (
    .clk_i            (clk),
    .rst_ni           (rst_ni),
    .start_i          (start),
    .fetch_pc_i       (fetch_pc),
    .redirect_i       (redirect),
    .redirect_target_i(redirect_target),
    .word_o           (word),
    .word_pc_o        (word_pc),
    .word_valid_o     (word_valid),
    .req_valid_o      (req_valid),
    .req_addr_o       (req_addr),
    .req_be_o         (req_be),
    .rsp_valid_i      (rsp_valid),
    .rsp_rdata_i      (rsp_rdata)
  );

  // ---- fake memory: combinational or 1-cycle-registered response -------------
  logic [31:0] mem [0:65535];
  logic        use_latency;
  logic        rsp_valid_reg;
  logic [31:0] rsp_rdata_reg;

  assign rsp_valid = use_latency ? rsp_valid_reg : req_valid;
  assign rsp_rdata = use_latency ? rsp_rdata_reg : mem[req_addr[31:2]];

  always_ff @(posedge clk) begin
    rsp_valid_reg <= req_valid;
    rsp_rdata_reg <= mem[req_addr[31:2]];
  end

  initial begin
    mem[32'h1000 >> 2] = 32'hdead_beef;
    mem[32'h1004 >> 2] = 32'hcafe_babe;
    mem[32'h2000 >> 2] = 32'h1234_5678;
    mem[32'h3000 >> 2] = 32'h0bad_f00d;
    mem[32'h3004 >> 2] = 32'h600d_beef;
    mem[32'h4000 >> 2] = 32'hfeed_face;
  end

  // ---- helpers ------------------------------------------------------------------

  task automatic check32(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
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

  initial begin
    // Reset.
    rst_ni = 0;
    start  = 0;
    fetch_pc = '0;
    redirect = 0;
    redirect_target = '0;
    use_latency = 0;
    @(posedge clk);
    rst_ni = 1;
    #1;

    check_bit(req_valid, 1'b0, "reset req_valid low");
    check_bit(word_valid, 1'b0, "reset word_valid low");

    // ---- 1. initial fetch (combinational response) ------------------------------
    start = 1;
    fetch_pc = 32'h0000_1000;
    @(posedge clk);  // -> F_REQ
    #1;
    check_bit(req_valid,  1'b1, "init req_valid");
    check32 (req_addr,    32'h0000_1000, "init req_addr");
    check_bit(word_valid, 1'b1, "init word_valid (comb rsp)");
    @(posedge clk);  // capture
    #1;
    check32 (word,     32'hdead_beef, "init word");
    check32 (word_pc,  32'h0000_1000, "init word_pc");
    check_bit(req_valid, 1'b0, "init req_valid drops");
    check_bit(word_valid, 1'b0, "init word_valid drops");

    // ---- 2. back-to-back fetch -----------------------------------------------------
    start = 1;
    fetch_pc = 32'h0000_1004;
    @(posedge clk);
    #1;
    check32 (req_addr,    32'h0000_1004, "b2b req_addr");
    check_bit(word_valid, 1'b1, "b2b word_valid");
    @(posedge clk);
    #1;
    check32 (word,     32'hcafe_babe, "b2b word");
    check32 (word_pc,  32'h0000_1004, "b2b word_pc");

    // ---- 3. redirect while idle ------------------------------------------------------
    start = 0;
    redirect = 1;
    redirect_target = 32'h0000_2000;
    @(posedge clk);  // -> F_REQ(0x2000)
    #1;
    check32 (req_addr,    32'h0000_2000, "redirect-idle req_addr");
    check_bit(word_valid, 1'b1, "redirect-idle word_valid");
    redirect = 0;
    @(posedge clk);
    #1;
    check32 (word,     32'h1234_5678, "redirect-idle word");
    check32 (word_pc,  32'h0000_2000, "redirect-idle word_pc");

    // ---- 4. redirect mid-fetch (abort in flight) -------------------------------------
    // Start a fetch of 0x3000; while its response cycle is active, redirect to
    // 0x3004. The 0x3000 response must NOT be captured.
    start = 1;
    fetch_pc = 32'h0000_3000;
    @(posedge clk);  // -> F_REQ(0x3000)
    #1;
    check32 (req_addr,    32'h0000_3000, "mid redirect initial req_addr");
    check_bit(word_valid, 1'b1, "mid redirect initial word_valid");
    // Redirect during the F_REQ(0x3000) cycle.
    start = 0;
    redirect = 1;
    redirect_target = 32'h0000_3004;
    @(posedge clk);  // -> F_REQ(0x3004), 0x3000 response dropped
    #1;
    check32 (req_addr,    32'h0000_3004, "mid redirect new req_addr");
    check_bit(word_valid, 1'b1, "mid redirect new word_valid");
    redirect = 0;
    @(posedge clk);  // capture target word
    #1;
    check32 (word,     32'h600d_beef, "mid redirect word is target's");
    check32 (word_pc,  32'h0000_3004, "mid redirect word_pc is target's");

    // ---- 5. 1-cycle-latency slave (non-redirect path) --------------------------------
    use_latency = 1;
    start = 1;
    fetch_pc = 32'h0000_4000;
    @(posedge clk);  // -> F_REQ
    #1;
    check_bit(req_valid,  1'b1, "latency1 req_valid");
    check32 (req_addr,    32'h0000_4000, "latency1 req_addr");
    check_bit(word_valid, 1'b0, "latency1 no word_valid yet (registered rsp)");
    @(posedge clk);  // rsp_valid_reg now high
    #1;
    check_bit(word_valid, 1'b1, "latency1 word_valid");
    @(posedge clk);  // capture
    #1;
    check32 (word,     32'hfeed_face, "latency1 word");
    check32 (word_pc,  32'h0000_4000, "latency1 word_pc");

    // ---- 6. unaligned (2-aligned) fetch PC -> word-aligned request (M2) -------------
    // The core may fetch at a 2-aligned PC (C extension); the request must be
    // word-aligned while word_pc preserves the full PC for the core's
    // halfword select at the accept edge.
    use_latency = 0;
    start = 1;
    fetch_pc = 32'h0000_1002;
    @(posedge clk);  // -> F_REQ
    #1;
    check_bit(req_valid,  1'b1, "unaligned req_valid");
    check32 (req_addr,    32'h0000_1000, "unaligned req_addr word-aligned");
    check_bit(word_valid, 1'b1, "unaligned word_valid");
    @(posedge clk);  // capture
    #1;
    check32 (word,     32'hdead_beef, "unaligned word");
    check32 (word_pc,  32'h0000_1002, "unaligned word_pc preserves full PC");

    if (fail_count == 0) begin
      $display("PASS tb_fetch_unit");
    end else begin
      $display("FAIL tb_fetch_unit (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
