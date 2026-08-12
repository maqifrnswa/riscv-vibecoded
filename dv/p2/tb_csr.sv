// up5k-rv -- M2 P1-3 testbench for csr_file.sv.
//
// Directed, self-checking: D7 CSR read/write behavior, mcycle counter
// semantics (free-running + half-writes), trap-entry and mret updates. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_csr rtl/core/up5k_rv_pkg.sv \
//     rtl/core/csr_file.sv dv/p2/tb_csr.sv && vvp build/tb_csr
// Expected: "PASS tb_csr", exit 0.

module tb_csr;

  import up5k_rv_pkg::*;

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;

  logic [11:0] csr_addr;
  logic [31:0] csr_rdata;
  logic        csr_we;
  logic [31:0] csr_wdata;

  logic        trap_enter;
  logic [31:0] trap_mepc;
  logic [31:0] trap_mcause;
  logic [31:0] trap_mtval;
  logic        mret;

  logic [63:0] mcycle;
  logic [31:0] mtvec;
  logic [31:0] mepc;

  int fail_count = 0;

  csr_file u_dut (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .csr_addr_i    (csr_addr),
    .csr_rdata_o   (csr_rdata),
    .csr_we_i      (csr_we),
    .csr_wdata_i   (csr_wdata),
    .trap_enter_i  (trap_enter),
    .trap_mepc_i   (trap_mepc),
    .trap_mcause_i (trap_mcause),
    .trap_mtval_i  (trap_mtval),
    .mret_i        (mret),
    .mcycle_o      (mcycle),
    .mtvec_o       (mtvec),
    .mepc_o        (mepc)
  );

  always #5 clk = ~clk;

  task automatic check32(logic [31:0] got, logic [31:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %08x exp %08x", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check64(logic [63:0] got, logic [63:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %016x exp %016x", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_bit(logic got, logic exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %b exp %b", name, got, exp);
      fail_count++;
    end
  endtask

  task automatic check_range(logic [31:0] got, logic [31:0] lo,
                             logic [31:0] hi, string name);
    if ((got < lo) || (got > hi)) begin
      $display("FAIL %s: got %08x exp in [%08x, %08x]", name, got, lo, hi);
      fail_count++;
    end
  endtask

  // One clock edge: exactly one counter increment / commit.
  task automatic tick();
    @(posedge clk);
  endtask

  task automatic read_csr(logic [11:0] addr, output logic [31:0] val, string name);
    // Pure combinational sample. Callers are always in the stable low phase
    // (write_csr / trap / mret end at a negedge), so no edge is crossed here.
    csr_addr = addr;
    csr_we   = 1'b0;
    #1;
    val = csr_rdata;
  endtask

  task automatic write_csr(logic [11:0] addr, logic [31:0] val);
    @(negedge clk);       // drive in the low phase...
    csr_addr  = addr;
    csr_we    = 1'b1;
    csr_wdata = val;
    @(posedge clk);       // ...captured here
    @(negedge clk);       // deassert in the next low phase (no capture race)
    csr_we = 1'b0;
  endtask

  initial begin
    logic [31:0] v;
    logic [31:0] m0;

    trap_enter = 1'b0;
    mret       = 1'b0;
    csr_we     = 1'b0;
    csr_addr   = 12'h300;

    // Reset deassert.
    #10;
    rst_n = 1'b1;
    #5;

    // ---- reset state ----------------------------------------------------------
    read_csr(12'h300, v, "reset mstatus");  check32(v, 32'd0, "mstatus reset 0");
    read_csr(12'h341, v, "reset mepc");     check32(v, 32'd0, "mepc reset 0");

    // ---- mcycle free-runs (relative checks: +1 per cycle) ---------------------
    read_csr(12'hB00, m0, "mcycle sample0");
    tick();
    read_csr(12'hB00, v, "mcycle sample1");  check32(v, m0 + 32'd1, "mcycle +1 per cycle");
    m0 = v;
    tick();
    read_csr(12'hB00, v, "mcycle sample2");  check32(v, m0 + 32'd1, "mcycle +1 per cycle again");
    m0 = v;
    read_csr(12'hB80, v, "mcycle high");     check32(v, 32'd0, "mcycleh still 0");

    // ---- CSR writes / reads -----------------------------------------------------
    write_csr(12'h305, 32'h0000_1000);   // mtvec
    read_csr(12'h305, v, "mtvec read");  check32(v, 32'h0000_1000, "mtvec value");
    check32(mtvec, 32'h0000_1000, "mtvec_o");

    write_csr(12'h341, 32'h0000_2044);   // mepc
    read_csr(12'h341, v, "mepc read");   check32(v, 32'h0000_2044, "mepc value");
    check32(mepc, 32'h0000_2044, "mepc_o");

    write_csr(12'h342, 32'h0000_0002);   // mcause (illegal)
    read_csr(12'h342, v, "mcause read"); check32(v, 32'h0000_0002, "mcause value");

    write_csr(12'h343, 32'h0000_5000);   // mtval
    read_csr(12'h343, v, "mtval read");  check32(v, 32'h0000_5000, "mtval value");

    // mstatus: only MIE/MPIE/MPP writable; other bits read 0.
    write_csr(12'h300, 32'hffff_ffff);
    read_csr(12'h300, v, "mstatus masked");
    check32(v, 32'h0000_1888, "mstatus masked value");  // bits 3,7,12:11 only

    // mcycle half-writes: writing one half must not alter the other.
    write_csr(12'hB00, 32'h1234_5678);
    read_csr(12'hB00, v, "mcycle low write"); check32(v, 32'h1234_5678, "mcycle low value");
    read_csr(12'hB80, v, "mcycle high after low"); check32(v, 32'd0, "mcycleh untouched");

    write_csr(12'hB80, 32'hdead_beef);
    read_csr(12'hB80, v, "mcycle high write"); check32(v, 32'hdead_beef, "mcycleh value");
    read_csr(12'hB00, v, "mcycle low after high");
    // The low half kept counting (1-2 increments; tb edge-phase tolerant).
    check_range(v, 32'h1234_5679, 32'h1234_567a, "mcycle low incremented");

    // ---- trap entry -------------------------------------------------------------
    trap_mepc   = 32'h0000_0080;
    trap_mcause = 32'h0000_000b;  // ecall from M
    trap_mtval  = 32'd0;
    @(negedge clk);
    trap_enter  = 1'b1;
    @(posedge clk);       // captured
    @(negedge clk);
    trap_enter  = 1'b0;
    read_csr(12'h341, v, "trap mepc");   check32(v, 32'h0000_0080, "trap mepc value");
    read_csr(12'h342, v, "trap mcause"); check32(v, 32'h0000_000b, "trap mcause value");
    read_csr(12'h343, v, "trap mtval");  check32(v, 32'd0, "trap mtval value");
    read_csr(12'h300, v, "trap mstatus");
    // MIE=0, MPIE=1 (was 1), MPP=11, plus bits set earlier (7, 12:11, 3) survive:
    // prior mstatus was 0x1888 (MIE=1, MPIE=1, MPP=11); after trap: MIE=0, MPIE=1, MPP=11.
    check32(v, 32'h0000_1880, "trap mstatus MIE=0 MPIE=1 MPP=11");

    // ---- mret --------------------------------------------------------------------
    @(negedge clk);
    mret = 1'b1;
    @(posedge clk);       // captured
    @(negedge clk);
    mret = 1'b0;
    read_csr(12'h300, v, "mret mstatus");
    // MIE <- MPIE(1), MPIE <- 1, MPP <- 00, other writable bits unchanged.
    check32(v, 32'h0000_0088, "mret mstatus MIE=1 MPIE=1 MPP=0");
    read_csr(12'h341, v, "mret mepc unchanged"); check32(v, 32'h0000_0080, "mepc kept");

    // ---- unknown address reads 0 ---------------------------------------------------
    read_csr(12'h7c0, v, "unknown csr"); check32(v, 32'd0, "unknown csr 0");

    if (fail_count == 0) begin
      $display("PASS tb_csr");
    end else begin
      $display("FAIL tb_csr (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
