// up5k-rv -- M2 P1-4b testbench for the core's trap machinery.
//
// Runs small trap-focused programs on the core (mtvec resets to 0, so every
// trap redirects to address 0 -- the trap entry path is what is under test;
// the CSR setup / mret round-trip is covered by the P1-4c integration test):
//   1. misaligned store -> trap with the LSU request SUPPRESSED (no memory
//      write), rd_addr=0, pc_wdata=mtvec=0;
//   2. ecall -> trap (mcause=11, not directly observable; the retire fields
//      and the mtvec redirect are);
//   3. illegal instruction -> trap;
//   4. ebreak -> trap.
// Also checks rvfi_mode=3 (M-mode, Gate-1 finding 4.1) on every retire.
// Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_trap rtl/core/up5k_rv_pkg.sv \
//     rtl/core/decoder.sv rtl/core/regfile.sv rtl/core/alu.sv \
//     rtl/core/lsu.sv rtl/core/fetch_unit.sv rtl/core/csr_file.sv \
//     rtl/core/rv32i_core.sv dv/p2/tb_trap.sv && vvp build/tb_trap
// Expected: "PASS tb_trap", exit 0.

module tb_trap;

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

  rv32i_core u_dut (
    .clk_i          (clk),
    .rst_ni         (rst_ni),
    .req_valid_o    (req_valid),
    .req_we_o       (req_we),
    .req_addr_o     (req_addr),
    .req_be_o       (req_be),
    .req_wdata_o    (req_wdata),
    .rsp_valid_i    (rsp_valid),
    .rsp_rdata_i    (rsp_rdata),
    .rvfi_valid     (rvfi_valid),
    .rvfi_order     (rvfi_order),
    .rvfi_insn      (rvfi_insn),
    .rvfi_trap      (rvfi_trap),
    .rvfi_halt      (rvfi_halt),
    .rvfi_intr      (rvfi_intr),
    .rvfi_mode      (rvfi_mode),
    .rvfi_ixl       (rvfi_ixl),
    .rvfi_rs1_addr  (rvfi_rs1_addr),
    .rvfi_rs2_addr  (rvfi_rs2_addr),
    .rvfi_rs1_rdata (rvfi_rs1_rdata),
    .rvfi_rs2_rdata (rvfi_rs2_rdata),
    .rvfi_rd_addr   (rvfi_rd_addr),
    .rvfi_rd_wdata  (rvfi_rd_wdata),
    .rvfi_pc_rdata  (rvfi_pc_rdata),
    .rvfi_pc_wdata  (rvfi_pc_wdata),
    .rvfi_mem_addr  (rvfi_mem_addr),
    .rvfi_mem_rmask (rvfi_mem_rmask),
    .rvfi_mem_wmask (rvfi_mem_wmask),
    .rvfi_mem_rdata (rvfi_mem_rdata),
    .rvfi_mem_wdata (rvfi_mem_wdata)
  );

  // ---- fake memory: combinational response, byte-masked writes -----------------
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

  // ---- captured retires ----------------------------------------------------------
  logic [31:0] c_insn     [0:3];
  logic        c_trap     [0:3];
  logic [31:0] c_pc_rdata [0:3];
  logic [31:0] c_pc_wdata [0:3];
  logic [ 4:0] c_rd_addr  [0:3];
  logic [31:0] c_rd_wdata [0:3];
  logic [ 3:0] c_wmask    [0:3];

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

  // Run until n retires captured (returns 0 on success).
  task automatic run_until(int n);
    int seen = 0;
    for (int cyc = 0; cyc < 2000 && seen < n; cyc++) begin
      @(posedge clk);
      #1;
      if (rvfi_valid) begin
        c_insn[seen]     = rvfi_insn;
        c_trap[seen]     = rvfi_trap;
        c_pc_rdata[seen] = rvfi_pc_rdata;
        c_pc_wdata[seen] = rvfi_pc_wdata;
        c_rd_addr[seen]  = rvfi_rd_addr;
        c_rd_wdata[seen] = rvfi_rd_wdata;
        c_wmask[seen]    = rvfi_mem_wmask;
        // Channel invariants on every retire.
        if (rvfi_mode !== 2'd3 || rvfi_ixl !== 2'd1) begin
          $display("FAIL pass retire %0d: mode/ixl (%b/%b)", seen, rvfi_mode, rvfi_ixl);
          fail_count++;
        end
        seen++;
      end
    end
    if (seen < n) begin
      $display("FAIL run_until: only %0d retires in 2000 cycles", seen);
      fail_count++;
    end
  endtask

  task automatic load_prog(logic [31:0] p0, logic [31:0] p4);
    for (int i = 0; i < 65536; i++) mem[i] = 32'd0;
    mem[32'h0000_0000 >> 2] = p0;
    mem[32'h0000_0004 >> 2] = p4;
  endtask

  initial begin
    #1;

    // ---- pass 1: misaligned store -> trap + LSU suppression ----------------------
    // addi x1,x0,18 @0x0 / sw x1,0(x1) @0x4 (addr 18, sw needs [1:0]=0 -> trap)
    load_prog(32'h0120_0093, 32'h0010_a023);
    reset_core();
    run_until(2);
    check32(c_insn[0],     32'h0120_0093, "p1 retire0 insn");
    check_bit(c_trap[0],   1'b0,          "p1 retire0 not trap");
    check32(c_pc_wdata[0], 32'h0000_0004, "p1 retire0 pc_wdata");
    check5 (c_rd_addr[0],  5'd1,          "p1 retire0 rd");
    check32(c_rd_wdata[0], 32'd18,        "p1 retire0 rd_wdata");
    check32(c_insn[1],     32'h0010_a023, "p1 retire1 insn");
    check_bit(c_trap[1],   1'b1,          "p1 retire1 trap");
    check32(c_pc_rdata[1], 32'h0000_0004, "p1 retire1 pc_rdata");
    check32(c_pc_wdata[1], 32'h0000_0000, "p1 retire1 pc_wdata = mtvec(0)");
    check5 (c_rd_addr[1],  5'd0,          "p1 retire1 rd_addr=0");
    check32(c_rd_wdata[1], 32'd0,         "p1 retire1 rd_wdata=0");
    check32(c_wmask[1],    4'd0,          "p1 retire1 wmask=0 (suppressed)");
    // The trapping store must NOT have written memory.
    if (mem[32'h0000_0010 >> 2] !== 32'd0) begin
      $display("FAIL p1: mem[0x10] = %08x exp 0 (misaligned store suppressed)",
               mem[32'h0000_0010 >> 2]);
      fail_count++;
    end

    // ---- pass 2: ecall -> trap -----------------------------------------------------
    load_prog(32'h0000_0093, 32'h0000_0073);  // addi x1,x0,0 / ecall
    reset_core();
    run_until(2);
    check_bit(c_trap[0],   1'b0,          "p2 retire0 not trap");
    check_bit(c_trap[1],   1'b1,          "p2 retire1 trap (ecall)");
    check32(c_pc_rdata[1], 32'h0000_0004, "p2 retire1 pc_rdata");
    check32(c_pc_wdata[1], 32'h0000_0000, "p2 retire1 pc_wdata = mtvec(0)");
    check5 (c_rd_addr[1],  5'd0,          "p2 retire1 rd_addr=0");

    // ---- pass 3: illegal instruction -> trap ----------------------------------------
    load_prog(32'h0000_0093, 32'hffff_ffff);  // addi x1,x0,0 / unknown opcode
    reset_core();
    run_until(2);
    check_bit(c_trap[1],   1'b1,          "p3 retire1 trap (illegal)");
    check32(c_pc_rdata[1], 32'h0000_0004, "p3 retire1 pc_rdata");
    check32(c_pc_wdata[1], 32'h0000_0000, "p3 retire1 pc_wdata = mtvec(0)");

    // ---- pass 4: ebreak -> trap ------------------------------------------------------
    load_prog(32'h0000_0093, 32'h0010_0073);  // addi x1,x0,0 / ebreak
    reset_core();
    run_until(2);
    check_bit(c_trap[1],   1'b1,          "p4 retire1 trap (ebreak)");
    check32(c_pc_rdata[1], 32'h0000_0004, "p4 retire1 pc_rdata");
    check32(c_pc_wdata[1], 32'h0000_0000, "p4 retire1 pc_wdata = mtvec(0)");
    check5 (c_rd_addr[1],  5'd0,          "p4 retire1 rd_addr=0");

    if (fail_count == 0) begin
      $display("PASS tb_trap");
    end else begin
      $display("FAIL tb_trap (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
