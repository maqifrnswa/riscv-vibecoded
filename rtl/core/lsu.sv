// up5k-rv -- M1 P2-5: load/store unit.
//
// Combinational load/store datapath for RV32I:
//   - `addr_o`  : word-aligned address for the bus  = {addr[31:2], 2'b00}
//   - `be_o`    : byte enables selecting the accessed lanes
//   - `wdata_o` : store data placed in the correct byte lanes
//   - `rd_data_o`: load data sign/zero-extended to 32 bits
//
// funct3 selectors: 000 lb/sb, 001 lh/sh, 010 lw/sw, 100 lbu, 101 lhu.
// `store_i` disambiguates load from store for the shared funct3 values
// (000/001/010) -- the opcode distinguishes them, not funct3.
// Invalid funct3 values (e.g. 011) produce no access (all-zero outputs); the
// core guards against ever reaching the LSU with those via decoder is_nop.
//
// The core's M1 scope is aligned accesses only (misaligned -> trap is M2;
// riscv-formal alignment handling is a P3 gate item). Lane behaviour for
// misaligned addresses is deterministic but not architecturally meaningful
// until M2.
//
// Stage scope (deepwork m1-core-rvfi.md P2-5): this file + its test only.

import up5k_rv_pkg::*;

module lsu (
  input  logic [31:0] addr_i,
  input  logic [ 2:0] funct3_i,
  input  logic        store_i,
  input  logic [31:0] wdata_i,
  input  logic [31:0] rdata_i,
  output logic [31:0] addr_o,
  output logic [ 3:0] be_o,
  output logic [31:0] wdata_o,
  output logic [31:0] rd_data_o
);

  logic [7:0]  load_byte;   // byte at addr_i[1:0]
  logic [15:0] load_half;   // halfword at addr_i[1]

  always_comb begin
    addr_o    = {addr_i[31:2], 2'b00};
    be_o      = 4'd0;
    wdata_o   = 32'd0;
    rd_data_o = 32'd0;

    load_byte = rdata_i[8 * addr_i[1:0] +: 8];
    load_half = rdata_i[16 * addr_i[1] +: 16];

    if (store_i) begin
      // ---- stores -------------------------------------------------------------
      unique case (funct3_i)
        FUNCT3_SB: begin
          be_o    = 4'b0001 << addr_i[1:0];
          wdata_o = wdata_i[7:0] << (8 * addr_i[1:0]);
        end
        FUNCT3_SH: begin
          be_o    = 4'b0011 << addr_i[1:0];
          wdata_o = wdata_i[15:0] << (16 * addr_i[1]);
        end
        FUNCT3_SW: begin
          be_o    = 4'b1111;
          wdata_o = wdata_i;
        end
        default: ;  // invalid store funct3: no access
      endcase
    end else begin
      // ---- loads -------------------------------------------------------------
      unique case (funct3_i)
        FUNCT3_LB: begin
          be_o      = 4'b0001 << addr_i[1:0];
          rd_data_o = {{24{load_byte[7]}}, load_byte};
        end
        FUNCT3_LH: begin
          be_o      = 4'b0011 << addr_i[1:0];
          rd_data_o = {{16{load_half[15]}}, load_half};
        end
        FUNCT3_LW: begin
          be_o      = 4'b1111;
          rd_data_o = rdata_i;
        end
        FUNCT3_LBU: begin
          be_o      = 4'b0001 << addr_i[1:0];
          rd_data_o = {24'd0, load_byte};
        end
        FUNCT3_LHU: begin
          be_o      = 4'b0011 << addr_i[1:0];
          rd_data_o = {16'd0, load_half};
        end
        default: ;  // invalid load funct3: no access
      endcase
    end
  end

endmodule
