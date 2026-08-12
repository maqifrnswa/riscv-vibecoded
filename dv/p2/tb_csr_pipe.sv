// up5k-rv -- M2 P1-4c testbench for the CSR pipeline + trap round-trip.
//
// Pass 1: set mtvec via csrrw, exercise csrrwi/csrrs/csrrci (mstatus RMW),
// read mcycle (rdcycle), then ecall -> trap to the handler at 0x100, which
// reads mepc/mcause/mtval via csrrs and returns with mret. Verifies the
// register results, the RVFI CSR channel fields, and the trap redirect.
// Pass 2: a CSR access to a non-D7 address traps as illegal (mcause=2).
// Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_csr_pipe rtl/core/up5k_rv_pkg.sv \
//     rtl/core/decoder.sv rtl/core/regfile.sv rtl/core/alu.sv \
//     rtl/core/lsu.sv rtl/core/fetch_unit.sv rtl/core/csr_file.sv \
//     rtl/core/rv32i_core.sv dv/p2/tb_csr_pipe.sv && vvp build/tb_csr_pipe
// Expected: "PASS tb_csr_pipe", exit 0.

module tb_csr_pipe;

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
    .rvfi_mem_wdata (rvfi_mem_wdata),
    .rvfi_csr_mstatus_rmask (rvfi_csr_mstatus_rmask),
    .rvfi_csr_mstatus_wmask (rvfi_csr_mstatus_wmask),
    .rvfi_csr_mstatus_rdata (rvfi_csr_mstatus_rdata),
    .rvfi_csr_mstatus_wdata (rvfi_csr_mstatus_wdata),
    .rvfi_csr_mtvec_rmask   (rvfi_csr_mtvec_rmask),
    .rvfi_csr_mtvec_wmask   (rvfi_csr_mtvec_wmask),
    .rvfi_csr_mtvec_rdata   (rvfi_csr_mtvec_rdata),
    .rvfi_csr_mtvec_wdata   (rvfi_csr_mtvec_wdata),
    .rvfi_csr_mepc_rmask    (rvfi_csr_mepc_rmask),
    .rvfi_csr_mepc_wmask    (rvfi_csr_mepc_wmask),
    .rvfi_csr_mepc_rdata    (rvfi_csr_mepc_rdata),
    .rvfi_csr_mepc_wdata    (rvfi_csr_mepc_wdata),
    .rvfi_csr_mcause_rmask  (rvfi_csr_mcause_rmask),
    .rvfi_csr_mcause_wmask  (rvfi_csr_mcause_wmask),
    .rvfi_csr_mcause_rdata  (rvfi_csr_mcause_rdata),
    .rvfi_csr_mcause_wdata  (rvfi_csr_mcause_wdata),
    .rvfi_csr_mtval_rmask   (rvfi_csr_mtval_rmask),
    .rvfi_csr_mtval_wmask   (rvfi_csr_mtval_wmask),
    .rvfi_csr_mtval_rdata   (rvfi_csr_mtval_rdata),
    .rvfi_csr_mtval_wdata   (rvfi_csr_mtval_wdata),
    .rvfi_csr_mcycle_rmask  (rvfi_csr_mcycle_rmask),
    .rvfi_csr_mcycle_wmask  (rvfi_csr_mcycle_wmask),
    .rvfi_csr_mcycle_rdata  (rvfi_csr_mcycle_rdata),
    .rvfi_csr_mcycle_wdata  (rvfi_csr_mcycle_wdata)
  );

  // ---- fake memory -------------------------------------------------------------
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
  logic [31:0] c_pc_rdata [0:10];
  logic [31:0] c_pc_wdata [0:10];
  logic        c_trap     [0:10];
  logic [ 4:0] c_rd_addr  [0:10];
  logic [31:0] c_rd_wdata [0:10];
  logic [31:0] c_mtvec_w  [0:10];
  logic [31:0] c_mtvec_r  [0:10];
  logic [31:0] c_mstat_w  [0:10];
  logic [31:0] c_mstat_r  [0:10];
  logic [31:0] c_mepc_r   [0:10];
  logic [31:0] c_mcause_r [0:10];
  logic [31:0] c_mtval_r  [0:10];
  logic [63:0] c_mcyc_rmask [0:10];
  logic [63:0] c_mcyc_rdata [0:10];

  int fail_count = 0;

  // Main program (module-level: iverilog does not support unpacked-array
  // subroutine ports). load_prog() copies it to mem[0..] and zeroes the rest.
  logic [31:0] prog [0:10];

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

  task automatic check64(logic [63:0] got, logic [63:0] exp, string name);
    if (got !== exp) begin
      $display("FAIL %s: got %016x exp %016x", name, got, exp);
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
        c_pc_rdata[seen]  = rvfi_pc_rdata;
        c_pc_wdata[seen]  = rvfi_pc_wdata;
        c_trap[seen]      = rvfi_trap;
        c_rd_addr[seen]   = rvfi_rd_addr;
        c_rd_wdata[seen]  = rvfi_rd_wdata;
        c_mtvec_w[seen]   = rvfi_csr_mtvec_wdata;
        c_mtvec_r[seen]   = rvfi_csr_mtvec_rdata;
        c_mstat_w[seen]   = rvfi_csr_mstatus_wdata;
        c_mstat_r[seen]   = rvfi_csr_mstatus_rdata;
        c_mepc_r[seen]    = rvfi_csr_mepc_rdata;
        c_mcause_r[seen]  = rvfi_csr_mcause_rdata;
        c_mtval_r[seen]   = rvfi_csr_mtval_rdata;
        c_mcyc_rmask[seen] = rvfi_csr_mcycle_rmask;
        c_mcyc_rdata[seen] = rvfi_csr_mcycle_rdata;
        if (rvfi_mode !== 2'd3 || rvfi_ixl !== 2'd1) begin
          $display("FAIL retire %0d: mode/ixl (%b/%b)", seen, rvfi_mode, rvfi_ixl);
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

  task automatic load_prog();
    for (int i = 0; i < 65536; i++) mem[i] = 32'd0;
    for (int i = 0; i < 11; i++) mem[i] = prog[i];
  endtask

  initial begin
    #1;

    // ---- pass 1: CSR write/RMW/read + ecall trap round-trip + mret -------------
    prog[0] = 32'h10000093;  // addi x1,x0,0x100
    prog[1] = 32'h30509073;  // csrrw x0, mtvec, x1   (mtvec = 0x100)
    prog[2] = 32'h30045073;  // csrrwi x0, 8, mstatus (MIE = 1)
    prog[3] = 32'h30002173;  // csrrs x2, mstatus, x0 (x2 = 8, no write)
    prog[4] = 32'h300471f3;  // csrrci x3, mstatus, 8 (x3 = 8, MIE cleared)
    prog[5] = 32'hb0002273;  // csrrs x4, mcycle, x0  (rdcycle)
    prog[6] = 32'h00000073;  // ecall                 (trap -> 0x100)
    prog[7] = 32'h341022f3;  // handler: csrrs x5, mepc, x0
    prog[8] = 32'h34202373;  // csrrs x6, mcause, x0
    prog[9] = 32'h343023f3;  // csrrs x7, mtval, x0
    prog[10] = 32'h30200073; // mret
    load_prog();
    mem[32'h0000_0100 >> 2] = 32'h341022f3;  // handler @0x100
    mem[32'h0000_0104 >> 2] = 32'h34202373;
    mem[32'h0000_0108 >> 2] = 32'h343023f3;
    mem[32'h0000_010c >> 2] = 32'h30200073;
    reset_core();
    run_until(11);

    check32(c_pc_wdata[0],  32'h0000_0004, "p1 r0 pc_w");
    check5 (c_rd_addr[0],   5'd1,          "p1 r0 rd");
    check32(c_rd_wdata[0],  32'h0000_0100, "p1 r0 rd_wdata");

    check32(c_pc_wdata[1],  32'h0000_0008, "p1 r1 pc_w");
    check32(c_mtvec_w[1],   32'h0000_0100, "p1 r1 mtvec wdata");
    check32(c_mtvec_r[1],   32'd0,         "p1 r1 mtvec rdata (rd=x0)");

    check32(c_pc_wdata[2],  32'h0000_000c, "p1 r2 pc_w");
    check32(c_mstat_w[2],   32'd8,         "p1 r2 mstatus wdata (MIE)");

    check32(c_rd_wdata[3],  32'd8,         "p1 r3 x2 = mstatus(MIE=1)");
    check32(c_mstat_r[3],   32'd8,         "p1 r3 mstatus rdata");

    check32(c_rd_wdata[4],  32'd8,         "p1 r4 x3 = mstatus(old)");
    check32(c_mstat_w[4],   32'd0,         "p1 r4 mstatus wdata (MIE cleared)");

    check64(c_mcyc_rmask[5], 64'h0000_0000_ffff_ffff, "p1 r5 mcycle rmask low");
    if (c_mcyc_rdata[5] == 64'd0) begin
      $display("FAIL p1 r5: mcycle rdata 0");
      fail_count++;
    end

    check_bit(c_trap[6],    1'b1,          "p1 r6 ecall trap");
    check32(c_pc_rdata[6],  32'h0000_0018, "p1 r6 pc_rdata");
    check32(c_pc_wdata[6],  32'h0000_0100, "p1 r6 pc_wdata = mtvec");
    check5 (c_rd_addr[6],   5'd0,          "p1 r6 rd_addr=0");

    check32(c_rd_wdata[7],  32'h0000_0018, "p1 r7 x5 = mepc");
    check32(c_mepc_r[7],    32'h0000_0018, "p1 r7 mepc rdata");
    check32(c_rd_wdata[8],  32'd11,        "p1 r8 x6 = mcause");
    check32(c_mcause_r[8],  32'd11,        "p1 r8 mcause rdata");
    check32(c_rd_wdata[9],  32'd0,         "p1 r9 x7 = mtval");
    check32(c_mtval_r[9],   32'd0,         "p1 r9 mtval rdata");

    check_bit(c_trap[10],   1'b0,          "p1 r10 mret not trap");
    check32(c_pc_wdata[10], 32'h0000_0018, "p1 r10 mret pc_wdata = mepc");

    // ---- pass 2: non-D7 CSR address traps as illegal ----------------------------
    prog[0] = 32'h10000093;  // addi x1,x0,0x100
    prog[1] = 32'h30509073;  // csrrw x0, mtvec, x1
    prog[2] = 32'h7c001073;  // csrrw x0, 0x7c0, x0  (illegal CSR -> trap)
    prog[3] = 32'h341022f3;  // handler: csrrs x2, mepc, x0
    prog[4] = 32'h34202373;  // csrrs x3, mcause, x0
    load_prog();
    mem[32'h0000_0100 >> 2] = 32'h341022f3;
    mem[32'h0000_0104 >> 2] = 32'h34202373;
    reset_core();
    run_until(5);

    check_bit(c_trap[2],    1'b1,          "p2 r2 illegal csr trap");
    check32(c_pc_rdata[2],  32'h0000_0008, "p2 r2 pc_rdata");
    check32(c_pc_wdata[2],  32'h0000_0100, "p2 r2 pc_wdata = mtvec");
    check5 (c_rd_addr[2],   5'd0,          "p2 r2 rd_addr=0");
    check32(c_rd_wdata[3],  32'h0000_0008, "p2 r3 x2 = mepc");
    check32(c_rd_wdata[4],  32'd2,         "p2 r4 x3 = mcause(illegal)");

    if (fail_count == 0) begin
      $display("PASS tb_csr_pipe");
    end else begin
      $display("FAIL tb_csr_pipe (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
