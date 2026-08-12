// up5k-rv -- M1 P2-7 testbench for rv32i_core.sv.
//
// Runs a hand-written program (hazards, ALU ops, lui/auipc, taken and
// not-taken branches, jal/jalr, sw/lw/sb/lbu/lb, fence+ecall as NOP) on the
// core with a combinational-response memory, and checks every retired
// instruction against an expected RVFI table (order/insn/pc/reg/mem fields),
// plus the final memory contents. Run:
//   source scripts/env.sh
//   iverilog -g2012 -o build/tb_core rtl/core/up5k_rv_pkg.sv \
//     rtl/core/decoder.sv rtl/core/regfile.sv rtl/core/alu.sv \
//     rtl/core/lsu.sv rtl/core/fetch_unit.sv rtl/core/rv32i_core.sv \
//     dv/p2/tb_core.sv && vvp build/tb_core
// Expected: "PASS tb_core (19 retires)", exit 0.

module tb_core;

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

  // ---- expected retire stream (parallel arrays -- packed-struct arrays with
  // variable indices crash iverilog) --------------------------------------------
  logic [31:0] exp_insn      [0:18];
  logic [31:0] exp_pc_rdata  [0:18];
  logic [31:0] exp_pc_wdata  [0:18];
  logic [ 4:0] exp_rs1_addr  [0:18];
  logic [31:0] exp_rs1_rdata [0:18];
  logic [ 4:0] exp_rs2_addr  [0:18];
  logic [31:0] exp_rs2_rdata [0:18];
  logic [ 4:0] exp_rd_addr   [0:18];
  logic [31:0] exp_rd_wdata  [0:18];
  logic [31:0] exp_mem_addr  [0:18];
  logic [ 3:0] exp_rmask     [0:18];
  logic [ 3:0] exp_wmask     [0:18];
  logic [31:0] exp_mem_rdata [0:18];
  logic [31:0] exp_mem_wdata [0:18];

  task automatic set_exp(int i,
                         logic [31:0] insn, logic [31:0] pcr, logic [31:0] pcw,
                         logic [ 4:0] r1a, logic [31:0] r1d,
                         logic [ 4:0] r2a, logic [31:0] r2d,
                         logic [ 4:0] rda, logic [31:0] rdw,
                         logic [31:0] ma, logic [ 3:0] rm, logic [ 3:0] wm,
                         logic [31:0] mrd, logic [31:0] mwd);
    exp_insn[i]      = insn;
    exp_pc_rdata[i]  = pcr;
    exp_pc_wdata[i]  = pcw;
    exp_rs1_addr[i]  = r1a;
    exp_rs1_rdata[i] = r1d;
    exp_rs2_addr[i]  = r2a;
    exp_rs2_rdata[i] = r2d;
    exp_rd_addr[i]   = rda;
    exp_rd_wdata[i]  = rdw;
    exp_mem_addr[i]  = ma;
    exp_rmask[i]     = rm;
    exp_wmask[i]     = wm;
    exp_mem_rdata[i] = mrd;
    exp_mem_wdata[i] = mwd;
  endtask

  int          retired = 0;
  int          fail_count = 0;
  logic        done = 0;

  initial begin
    // addi x1,x0,5 @0x0000 / addi x2,x1,7 @0x0004 / add x3,x1,x2 @0x0008
    set_exp(0,  32'h0050_0093, 32'h0000_0000, 32'h0000_0004, 5'd0,  32'h0, 5'd5, 32'h0,
                 5'd1, 32'd5, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(1,  32'h0070_8113, 32'h0000_0004, 32'h0000_0008, 5'd1,  32'd5, 5'd7, 32'h0,
                 5'd2, 32'd12, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(2,  32'h0020_81b3, 32'h0000_0008, 32'h0000_000c, 5'd1,  32'd5, 5'd2, 32'd12,
                 5'd3, 32'd17, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    // sub x4,x3,x1 @0x000c / slli x5,x4,2 @0x0010 / auipc x6,0 @0x0014
    set_exp(3,  32'h4011_8233, 32'h0000_000c, 32'h0000_0010, 5'd3,  32'd17, 5'd1, 32'd5,
                 5'd4, 32'd12, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(4,  32'h0022_1293, 32'h0000_0010, 32'h0000_0014, 5'd4,  32'd12, 5'd2, 32'd12,
                 5'd5, 32'd48, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(5,  32'h0000_0317, 32'h0000_0014, 32'h0000_0018, 5'd0,  32'h0, 5'd0, 32'h0,
                 5'd6, 32'h0000_0014, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    // jal x7,+8 @0x0018 / bne x8,x1,+8 @0x0020 (taken) / beq x8,x8,+4 @0x0028
    set_exp(6,  32'h0080_03ef, 32'h0000_0018, 32'h0000_0020, 5'd0,  32'h0, 5'd8, 32'h0,
                 5'd7, 32'h0000_001c, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(7,  32'h0014_1463, 32'h0000_0020, 32'h0000_0028, 5'd8,  32'd0, 5'd1, 32'd5,
                 5'd0, 32'd0, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(8,  32'h0084_0263, 32'h0000_0028, 32'h0000_002c, 5'd8,  32'd0, 5'd8, 32'd0,
                 5'd0, 32'd0, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    // sw x1,0x100(x0) @0x002c / lw x10,0x100(x0) @0x0030 / sb x1,0x102(x0) @0x0034
    set_exp(9,  32'h1010_2023, 32'h0000_002c, 32'h0000_0030, 5'd0,  32'h0, 5'd1, 32'd5,
                 5'd0, 32'd0, 32'h0000_0100, 4'd0, 4'hf, 32'h0, 32'd5);
    set_exp(10, 32'h1000_2503, 32'h0000_0030, 32'h0000_0034, 5'd0,  32'h0, 5'd0, 32'h0,
                 5'd10, 32'd5, 32'h0000_0100, 4'hf, 4'd0, 32'd5, 32'h0);
    set_exp(11, 32'h1010_0123, 32'h0000_0034, 32'h0000_0038, 5'd0,  32'h0, 5'd1, 32'd5,
                 5'd0, 32'd0, 32'h0000_0100, 4'd0, 4'h4, 32'h0, 32'h0005_0000);
    // lbu x11,0x102(x0) @0x0038 / lb x12,0x102(x0) @0x003c / jalr x0,x7,0x28 @0x0040
    set_exp(12, 32'h1020_4583, 32'h0000_0038, 32'h0000_003c, 5'd0,  32'h0, 5'd2, 32'd12,
                 5'd11, 32'd5, 32'h0000_0100, 4'h4, 4'd0, 32'h0005_0005, 32'h0);
    set_exp(13, 32'h1020_0603, 32'h0000_003c, 32'h0000_0040, 5'd0,  32'h0, 5'd2, 32'd12,
                 5'd12, 32'd5, 32'h0000_0100, 4'h4, 4'd0, 32'h0005_0005, 32'h0);
    set_exp(14, 32'h0283_8067, 32'h0000_0040, 32'h0000_0044, 5'd7,  32'h0000_001c, 5'd8, 32'h0,
                 5'd0, 32'd0, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    // addi x13,x0,0xaa @0x0044 / fence @0x0048 (NOP) / addi x14,x0,5 @0x004c
    set_exp(15, 32'h0aa0_0693, 32'h0000_0044, 32'h0000_0048, 5'd0,  32'h0, 5'd10, 32'd5,
                 5'd13, 32'h0000_00aa, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(16, 32'h0000_000f, 32'h0000_0048, 32'h0000_004c, 5'd0,  32'h0, 5'd0, 32'h0,
                 5'd0, 32'd0, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    set_exp(17, 32'h0050_0713, 32'h0000_004c, 32'h0000_0050, 5'd0,  32'h0, 5'd5, 32'd48,
                 5'd14, 32'd5, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
    // ecall @0x0050 (M1: NOP)
    set_exp(18, 32'h0000_0073, 32'h0000_0050, 32'h0000_0054, 5'd0,  32'h0, 5'd0, 32'h0,
                 5'd0, 32'd0, 32'h0, 4'd0, 4'd0, 32'h0, 32'h0);
  end

  // ---- program preload -----------------------------------------------------------
  initial begin
    mem[32'h0000_0000 >> 2] = 32'h0050_0093;  // addi x1,x0,5
    mem[32'h0000_0004 >> 2] = 32'h0070_8113;  // addi x2,x1,7
    mem[32'h0000_0008 >> 2] = 32'h0020_81b3;  // add x3,x1,x2
    mem[32'h0000_000c >> 2] = 32'h4011_8233;  // sub x4,x3,x1
    mem[32'h0000_0010 >> 2] = 32'h0022_1293;  // slli x5,x4,2
    mem[32'h0000_0014 >> 2] = 32'h0000_0317;  // auipc x6,0
    mem[32'h0000_0018 >> 2] = 32'h0080_03ef;  // jal x7,+8
    mem[32'h0000_001c >> 2] = 32'h0630_0413;  // addi x8,x0,99 (skipped)
    mem[32'h0000_0020 >> 2] = 32'h0014_1463;  // bne x8,x1,+8 (taken)
    mem[32'h0000_0024 >> 2] = 32'h0070_0493;  // addi x9,x0,7 (skipped)
    mem[32'h0000_0028 >> 2] = 32'h0084_0263;  // beq x8,x8,+4 (taken)
    mem[32'h0000_002c >> 2] = 32'h1010_2023;  // sw x1,0x100(x0)
    mem[32'h0000_0030 >> 2] = 32'h1000_2503;  // lw x10,0x100(x0)
    mem[32'h0000_0034 >> 2] = 32'h1010_0123;  // sb x1,0x102(x0)
    mem[32'h0000_0038 >> 2] = 32'h1020_4583;  // lbu x11,0x102(x0)
    mem[32'h0000_003c >> 2] = 32'h1020_0603;  // lb x12,0x102(x0)
    mem[32'h0000_0040 >> 2] = 32'h0283_8067;  // jalr x0,x7,0x28
    mem[32'h0000_0044 >> 2] = 32'h0aa0_0693;  // addi x13,x0,0xaa
    mem[32'h0000_0048 >> 2] = 32'h0000_000f;  // fence
    mem[32'h0000_004c >> 2] = 32'h0050_0713;  // addi x14,x0,5
    mem[32'h0000_0050 >> 2] = 32'h0000_0073;  // ecall (NOP)
  end

  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  task automatic check32(logic [31:0] got, logic [31:0] exp_v, string name, int ord);
    if (got !== exp_v) begin
      $display("FAIL retire %0d %s: got %08x exp %08x", ord, name, got, exp_v);
      fail_count++;
    end
  endtask

  task automatic check8(logic [7:0] got, logic [7:0] exp_v, string name, int ord);
    if (got !== exp_v) begin
      $display("FAIL retire %0d %s: got %02x exp %02x", ord, name, got, exp_v);
      fail_count++;
    end
  endtask

  task automatic check64(logic [63:0] got, logic [63:0] exp_v, string name, int ord);
    if (got !== exp_v) begin
      $display("FAIL retire %0d %s: got %016x exp %016x", ord, name, got, exp_v);
      fail_count++;
    end
  endtask

  // Sample one retire and compare against the expected table.
  task automatic check_retire(int ord);
    check64(rvfi_order,          64'(ord),        "order", ord);
    check32(rvfi_insn,           exp_insn[ord],   "insn", ord);
    check32(rvfi_pc_rdata,       exp_pc_rdata[ord], "pc_rdata", ord);
    check32(rvfi_pc_wdata,       exp_pc_wdata[ord], "pc_wdata", ord);
    check8 (rvfi_rs1_addr,       exp_rs1_addr[ord], "rs1_addr", ord);
    check32(rvfi_rs1_rdata,      exp_rs1_rdata[ord], "rs1_rdata", ord);
    check8 (rvfi_rs2_addr,       exp_rs2_addr[ord], "rs2_addr", ord);
    check32(rvfi_rs2_rdata,      exp_rs2_rdata[ord], "rs2_rdata", ord);
    check8 (rvfi_rd_addr,        exp_rd_addr[ord], "rd_addr", ord);
    check32(rvfi_rd_wdata,       exp_rd_wdata[ord], "rd_wdata", ord);
    check32(rvfi_mem_addr,       exp_mem_addr[ord], "mem_addr", ord);
    check8 (rvfi_mem_rmask,      exp_rmask[ord], "mem_rmask", ord);
    check8 (rvfi_mem_wmask,      exp_wmask[ord], "mem_wmask", ord);
    check32(rvfi_mem_rdata,      exp_mem_rdata[ord], "mem_rdata", ord);
    check32(rvfi_mem_wdata,      exp_mem_wdata[ord], "mem_wdata", ord);
    // Channel invariants on every retire.
    if (rvfi_trap !== 1'b0) begin
      $display("FAIL retire %0d: trap must be 0 in M1 (got %b)", ord, rvfi_trap);
      fail_count++;
    end
    if (rvfi_mode !== 2'd0 || rvfi_ixl !== 2'd1) begin
      $display("FAIL retire %0d: mode/ixl (%b/%b)", ord, rvfi_mode, rvfi_ixl);
      fail_count++;
    end
  endtask

  initial begin
    // Reset.
    rst_ni = 0;
    @(posedge clk);
    @(posedge clk);
    rst_ni = 1;

    // Watch for retires (comb outputs of the WB phase).
    for (int cyc = 0; cyc < 2000; cyc++) begin
      @(posedge clk);
      #1;
      if (rvfi_valid) begin
        check_retire(retired);
        retired++;
        if (retired == 19) begin
          done = 1;
          break;
        end
      end
    end

    if (!done) begin
      $display("FAIL tb_core: only %0d retires in 2000 cycles", retired);
      fail_count++;
    end else begin
      // Final memory contents: mem[0x100] = 0x00050000 (5 written by sw, byte
      // 2 patched by sb).
      if (mem[32'h0000_0100 >> 2] !== 32'h0005_0005) begin
        $display("FAIL tb_core: mem[0x100] = %08x exp 00050005",
                 mem[32'h0000_0100 >> 2]);
        fail_count++;
      end
    end

    if (fail_count == 0) begin
      $display("PASS tb_core (%0d retires)", retired);
    end else begin
      $display("FAIL tb_core (%0d failures)", fail_count);
    end
    $finish;
  end

endmodule
