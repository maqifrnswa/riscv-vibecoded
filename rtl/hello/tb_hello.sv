// SPDX-License-Identifier: Apache-2.0
//
// tb_hello: self-checking testbench for the hello smoke module.
//
// Simulation-only (not synthesizable). Applies async reset, toggles en_i, and
// checks that out_o follows the gated counter as expected.

`timescale 1ns/1ps

module tb_hello;

  localparam time CLK_PERIOD = 10ns;

  logic       clk_i;
  logic       rst_ni;
  logic       en_i;
  logic [7:0] out_o;

  hello dut (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (en_i),
      .out_o (out_o)
  );

  // Free-running clock.
  initial begin
    clk_i = 1'b0;
    forever #(CLK_PERIOD / 2) clk_i = ~clk_i;
  end

  // Stimulus + checks.
  initial begin
    en_i   = 1'b0;
    rst_ni = 1'b0;  // assert reset
    #(CLK_PERIOD);
    rst_ni = 1'b1;  // release reset

    // en_i low: counter must stay at zero.
    #(CLK_PERIOD);
    if (out_o != 8'h00) begin
      $display("FAIL: out_o = %02h, expected 00", out_o);
      $finish(1);
    end

    // en_i high for three cycles: counter increments to 3.
    en_i = 1'b1;
    repeat (3) begin
      #(CLK_PERIOD);
    end
    if (out_o != 8'h03) begin
      $display("FAIL: out_o = %02h, expected 03", out_o);
      $finish(1);
    end

    $display("PASS: tb_hello");
    $finish(0);
  end

endmodule
