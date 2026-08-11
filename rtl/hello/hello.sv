// SPDX-License-Identifier: Apache-2.0
//
// hello: minimal smoke module for the M0 lint gate.
//
// A trivial gated 8-bit counter whose value is echoed to the output. This
// module exists only to prove the `yosys read_slang` + `verilator --lint-only`
// gate runs clean; it is not real RTL and will be deleted at M1.

module hello (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       en_i,
    output logic [7:0] out_o
);

  logic [7:0] counter_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      counter_q <= 8'h00;
    end else if (en_i) begin
      counter_q <= counter_q + 8'h01;
    end
  end

  always_comb begin
    out_o = counter_q;
  end

endmodule
