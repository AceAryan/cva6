// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.
//
// Description: Atomic broadcast bus for MSI coherence between private
//              std_nbdcache L1s. One tenure exists at a time:
//                1. pick a requesting cache, round robin
//                2. GetS/GetM: snoop every other cache and wait for all acks
//                   (an ack means any dirty copy is already in memory)
//                3. grant the requester, which then uses memory on its own
//                   AXI port
//                4. the requester ends the tenure with done
//              A PutM is granted without snoops, the requester owns the line.
//              Caches answer snoops without the bus, so a snoop always
//              completes and the bus cannot deadlock.

module cc_bus
  import std_cache_pkg::*;
#(
    parameter int unsigned NumCaches = 2
) (
    input logic clk_i,
    input logic rst_ni,
    // requests
    input cc_req_t [NumCaches-1:0] req_i,
    output logic [NumCaches-1:0] gnt_o,
    input logic [NumCaches-1:0] done_i,
    // snoops
    output cc_snoop_t [NumCaches-1:0] snoop_o,
    input logic [NumCaches-1:0] snoop_ready_i,
    input logic [NumCaches-1:0] snoop_ack_i,
    // the cache owning the current tenure, for performance counters
    output logic busy_o,
    output logic [$clog2(NumCaches > 1 ? NumCaches : 2)-1:0] owner_o
);

  localparam int unsigned IdxWidth = $clog2(NumCaches > 1 ? NumCaches : 2);

  typedef enum logic [1:0] {
    IDLE,
    SNOOP,
    GRANT,
    TENURE
  } state_e;
  state_e state_d, state_q;

  logic [IdxWidth-1:0] owner_d, owner_q;
  logic [IdxWidth-1:0] rr_d, rr_q;  // first cache to consider next
  cc_req_t cur_d, cur_q;
  logic [NumCaches-1:0] accepted_d, accepted_q;
  logic [NumCaches-1:0] acked_d, acked_q;

  assign busy_o  = (state_q != IDLE);
  assign owner_o = owner_q;

  always_comb begin
    state_d    = state_q;
    owner_d    = owner_q;
    rr_d       = rr_q;
    cur_d      = cur_q;
    accepted_d = accepted_q;
    acked_d    = acked_q;
    gnt_o      = '0;
    snoop_o    = '0;

    unique case (state_q)
      IDLE: begin
        for (int unsigned k = 0; k < NumCaches; k++) begin
          automatic int unsigned c = (int'(rr_q) + k) % NumCaches;
          if (req_i[c].valid) begin
            owner_d    = IdxWidth'(c);
            cur_d      = req_i[c];
            accepted_d = '0;
            acked_d    = '0;
            // nothing to snoop for a write-back, or with a single cache
            accepted_d[c] = 1'b1;
            acked_d[c]    = 1'b1;
            state_d    = (req_i[c].req_type == CC_PUTM || NumCaches == 1) ? GRANT : SNOOP;
            break;
          end
        end
      end

      SNOOP: begin
        for (int unsigned c = 0; c < NumCaches; c++) begin
          snoop_o[c].valid    = !accepted_q[c];
          snoop_o[c].req_type = cur_q.req_type;
          snoop_o[c].addr     = cur_q.addr;
          if (snoop_o[c].valid && snoop_ready_i[c]) accepted_d[c] = 1'b1;
          if (snoop_ack_i[c] && accepted_q[c]) acked_d[c] = 1'b1;
        end
        if (&acked_d) state_d = GRANT;
      end

      GRANT: begin
        // the requester waits for the grant and only leaves its request
        // state for a snoop, which cannot happen while we serve it
        gnt_o[owner_q] = req_i[owner_q].valid;
        state_d = req_i[owner_q].valid ? TENURE : IDLE;
      end

      TENURE: begin
        if (done_i[owner_q]) begin
          state_d = IDLE;
          rr_d    = IdxWidth'((int'(owner_q) + 1) % NumCaches);
        end
      end

      default: state_d = IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= IDLE;
      owner_q    <= '0;
      rr_q       <= '0;
      cur_q      <= '0;
      accepted_q <= '0;
      acked_q    <= '0;
    end else begin
      state_q    <= state_d;
      owner_q    <= owner_d;
      rr_q       <= rr_d;
      cur_q      <= cur_d;
      accepted_q <= accepted_d;
      acked_q    <= acked_d;
    end
  end

  //pragma translate_off
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned c = 0; c < NumCaches; c++) begin
        if (done_i[c] && !(state_q == TENURE && owner_q == c))
          $error("[cc_bus] done from cache %0d outside of its tenure", c);
        if (snoop_ack_i[c] && !(state_q == SNOOP && accepted_q[c] && !acked_q[c]))
          $error("[cc_bus] unexpected snoop ack from cache %0d", c);
      end
      if (state_q == GRANT && !req_i[owner_q].valid)
        $error("[cc_bus] requester %0d withdrew before its grant", owner_q);
    end
  end
`endif
  //pragma translate_on

endmodule
