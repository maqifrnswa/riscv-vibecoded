// up5k-rv -- M1 P2-2: register file.
//
// 32 x 32-bit distributed register file with two asynchronous (combinational)
// read ports and one write port. x0 is hardwired to zero: reads return 0 and
// writes to x0 are ignored.
//
// Reads are combinational (data appears in the same cycle as the address);
// writes commit at the clock edge. This is the hazard-free core's only
// storage: the pipeline guarantees the writeback of instruction i commits
// before the ID-stage read of instruction i+1 (deepwork P2-7 scheduling
// contract), so no forwarding/bypass is required here.
//
// Stage scope (deepwork m1-core-rvfi.md P2-2): this file + its test only.

module regfile (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Write port.
  input  logic [ 4:0] waddr_i,
  input  logic [31:0] wdata_i,
  input  logic        we_i,

  // Read ports (asynchronous).
  input  logic [ 4:0] raddr_a_i,
  input  logic [ 4:0] raddr_b_i,
  output logic [31:0] rdata_a_o,
  output logic [31:0] rdata_b_o
);

  logic [31:0] mem [32];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < 32; i++) begin
        mem[i] <= 32'd0;
      end
    end else if (we_i && (waddr_i != 5'd0)) begin
      mem[waddr_i] <= wdata_i;
    end
  end

  assign rdata_a_o = (raddr_a_i == 5'd0) ? 32'd0 : mem[raddr_a_i];
  assign rdata_b_o = (raddr_b_i == 5'd0) ? 32'd0 : mem[raddr_b_i];

endmodule
