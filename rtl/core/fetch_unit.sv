// up5k-rv -- M1 P2-6: fetch unit.
//
// IF1/IF2 fetch machine: issues a read-only, word-aligned, full-word SBus
// request for `fetch_pc_i` and captures the returned word + its PC.
//
// Behavior:
//   - F_IDLE: samples `start_i` (begin fetching `fetch_pc_i`) and
//     `redirect_i` (begin fetching `redirect_target_i`). start_i is only
//     meaningful while idle; the core guarantees that.
//   - F_REQ : drives req_valid_o/req_addr_o until rsp_valid_i. On the
//     response, captures rsp_rdata_i + the request PC into word_o/word_pc_o
//     and returns to F_IDLE. Works for both combinational (rsp_valid_i
//     asserted in the request cycle) and registered (asserted one cycle
//     later) responses.
//   - `redirect_i` (sampled in any state) aborts the in-flight fetch and
//     restarts a new request at redirect_target_i; the aborted request's
//     response is NOT captured.
//
// Redirect with a REGISTERED-response slave: a stale response for the
// aborted address may still arrive (the slave already committed to it), and
// this module would mis-capture it. The M1 core's memory slave is therefore
// required to answer combinationally (rsp_valid_i = f(req_valid_o)); the
// registered-latency SoC path (M5) will add stale-response suppression.
//
// word_valid_o is a combinational pulse, high during the cycle the response
// arrives for a fetch in F_REQ. The consuming pipeline may use it to accept
// the word at the following edge (word_o is latched at that same edge).
//
// Stage scope (deepwork m1-core-rvfi.md P2-6): this file + its test only.

import up5k_rv_pkg::*;

module fetch_unit (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Control.
  input  logic        start_i,        // begin fetching fetch_pc_i (sampled in F_IDLE)
  input  logic [31:0] fetch_pc_i,
  input  logic        redirect_i,     // abort in-flight fetch, fetch redirect_target_i
  input  logic [31:0] redirect_target_i,

  // Fetched word output.
  output logic [31:0] word_o,
  output logic [31:0] word_pc_o,
  output logic        word_valid_o,   // comb pulse: response cycle of a completed fetch

  // SBus master (read-only, full-word, word-aligned).
  output logic        req_valid_o,
  output logic [31:0] req_addr_o,
  output logic [ 3:0] req_be_o,
  input  logic        rsp_valid_i,
  input  logic [31:0] rsp_rdata_i
);

  fetch_phase_e fetch_phase_q;
  logic [31:0]  fetch_pc_q;  // address of the in-flight request (or next start target)
  logic [31:0]  word_q;      // last captured word
  logic [31:0]  word_pc_q;   // PC the captured word was fetched from

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_phase_q <= F_IDLE;
      fetch_pc_q    <= 32'd0;
      word_q        <= 32'd0;
      word_pc_q     <= 32'd0;
    end else begin
      // Capture the response for the current request (never for an aborted
      // fetch: redirect_i takes precedence and the stale rsp is ignored).
      if ((fetch_phase_q == F_REQ) && rsp_valid_i && !redirect_i) begin
        word_q    <= rsp_rdata_i;
        word_pc_q <= fetch_pc_q;
      end
      // State / address update.
      if (redirect_i) begin
        fetch_phase_q <= F_REQ;
        fetch_pc_q    <= redirect_target_i;
      end else if ((fetch_phase_q == F_IDLE) && start_i) begin
        fetch_phase_q <= F_REQ;
        fetch_pc_q    <= fetch_pc_i;
      end else if ((fetch_phase_q == F_REQ) && rsp_valid_i) begin
        fetch_phase_q <= F_IDLE;
      end
    end
  end

  assign req_valid_o  = (fetch_phase_q == F_REQ);
  assign req_addr_o   = fetch_pc_q;
  assign req_be_o     = 4'hF;
  assign word_valid_o = (fetch_phase_q == F_REQ) && rsp_valid_i;

  assign word_o    = word_q;
  assign word_pc_o = word_pc_q;

endmodule
