// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.
//
// Description: Conditional-access state of one hart for the write-back
//              std_nbdcache (Singh, Brown, Spear: "Efficient Hardware
//              Primitives for Immediate Memory Reclamation in Optimistic Data
//              Structures"):
//                tagSet           line addresses tagged by committed creads
//                accessRevokedBit set when a tagged line is invalidated by
//                                 another core, evicted, the tagSet overflows,
//                                 or a trap is taken with lines tagged
//                CAFAIL           set by a failed cread or cwrite
//              untagAll clears all three, untagOne drops one tag.
//
//              creads, untagOne and untagAll run speculatively in the load
//              path: they are recorded by transaction ID when the cache sees
//              them and take effect when they commit. cwrite runs at commit
//              (AMO path), so its check is against committed state only.
//
//              Ordering rules for the speculative part:
//              - while an untagAll is pending, no further CA request is
//                accepted, so a cread never checks a revoked bit that an
//                older untagAll is about to clear
//              - a cread fails if access is revoked or if the line of an
//                older, still pending cread was already invalidated: the
//                older cread will revoke access when it commits, and data
//                read after that point may come from a reclaimed node

module ca_tag_set
  import wt_cache_pkg::*;
#(
    parameter int unsigned DEPTH = 8,
    parameter int unsigned ADDR_WIDTH = 56,
    parameter int unsigned LINE_OFFSET_BITS = 6,
    parameter int unsigned ID_WIDTH = 4,
    parameter int unsigned NUM_COMMIT_PORTS = 1
) (
    input logic clk_i,
    input logic rst_ni,
    // drop everything not yet committed
    input logic flush_i,
    // a CA operation reaches the cache (load path)
    input logic issue_valid_i,
    input ca_op_t issue_op_i,
    input logic [ID_WIDTH-1:0] issue_id_i,
    input logic [ADDR_WIDTH-1:0] issue_addr_i,
    // the cache answered this cread with a failure
    input logic cread_fail_valid_i,
    input logic [ID_WIDTH-1:0] cread_fail_id_i,
    // commits
    input logic [NUM_COMMIT_PORTS-1:0] commit_valid_i,
    input logic [NUM_COMMIT_PORTS-1:0][ID_WIDTH-1:0] commit_id_i,
    // local loss of a line (eviction, flush) or of everything (trap)
    input logic invalidate_valid_i,
    input logic invalidate_all_i,
    input logic [ADDR_WIDTH-1:0] invalidate_addr_i,
    // another core takes ownership of a line we hold (GetM snoop hit)
    input logic snoop_invalidate_valid_i,
    input logic [ADDR_WIDTH-1:0] snoop_invalidate_addr_i,
    // cwrite at commit
    input logic [ADDR_WIDTH-1:0] cwrite_addr_i,
    output logic cwrite_allowed_o,
    input logic cwrite_fail_i,
    // status
    output logic cread_revoked_o,
    output logic untag_all_pending_o,
    output logic access_revoked_o,
    output logic cafail_o
);

  localparam int unsigned PENDING_DEPTH = 1 << ID_WIDTH;

  logic [DEPTH-1:0] tag_valid_q, tag_valid_d;
  logic [DEPTH-1:0][ADDR_WIDTH-1:0] tag_addr_q, tag_addr_d;
  logic [PENDING_DEPTH-1:0] pending_valid_q, pending_valid_d;
  ca_op_t [PENDING_DEPTH-1:0] pending_op_q, pending_op_d;
  logic [PENDING_DEPTH-1:0][ADDR_WIDTH-1:0] pending_addr_q, pending_addr_d;
  logic [PENDING_DEPTH-1:0] pending_invalidated_q, pending_invalidated_d;
  logic [PENDING_DEPTH-1:0] pending_failed_q, pending_failed_d;
  logic revoked_q, revoked_d;
  logic cafail_q, cafail_d;

  function automatic logic [ADDR_WIDTH-1:0] line_address(input logic [ADDR_WIDTH-1:0] address);
    return (address >> LINE_OFFSET_BITS) << LINE_OFFSET_BITS;
  endfunction

  // does a local or remote invalidation in this cycle hit line `a`?
  function automatic logic invalidates(input logic [ADDR_WIDTH-1:0] a);
    return (invalidate_valid_i && (invalidate_all_i || a == line_address(invalidate_addr_i))) ||
           (snoop_invalidate_valid_i && a == line_address(snoop_invalidate_addr_i));
  endfunction

  always_comb begin : p_update
    automatic logic found, free_found;
    automatic int unsigned free_idx;

    tag_valid_d = tag_valid_q;
    tag_addr_d = tag_addr_q;
    pending_valid_d = pending_valid_q;
    pending_op_d = pending_op_q;
    pending_addr_d = pending_addr_q;
    pending_invalidated_d = pending_invalidated_q;
    pending_failed_d = pending_failed_q;
    revoked_d = revoked_q;
    cafail_d = cafail_q;

    // commits, in program order across the commit ports
    for (int c = 0; c < NUM_COMMIT_PORTS; c++) begin
      if (commit_valid_i[c] && !flush_i && pending_valid_d[commit_id_i[c]]) begin
        unique case (pending_op_d[commit_id_i[c]])
          CA_CREAD: begin
            if (pending_failed_d[commit_id_i[c]]) begin
              cafail_d = 1'b1;
            end else if (pending_invalidated_d[commit_id_i[c]]) begin
              // the line went away between the access and the commit
              revoked_d = 1'b1;
            end else begin
              found = 1'b0;
              free_found = 1'b0;
              free_idx = 0;
              for (int i = 0; i < DEPTH; i++) begin
                if (tag_valid_d[i] && tag_addr_d[i] == pending_addr_d[commit_id_i[c]]) begin
                  found = 1'b1;
                end else if (!tag_valid_d[i] && !free_found) begin
                  free_found = 1'b1;
                  free_idx = i;
                end
              end
              if (!found) begin
                if (free_found) begin
                  tag_valid_d[free_idx] = 1'b1;
                  tag_addr_d[free_idx]  = pending_addr_d[commit_id_i[c]];
                end else begin
                  // tagSet overflow, as an eviction of a tagged line would
                  revoked_d = 1'b1;
                end
              end
            end
          end
          CA_UNTAG_ONE: begin
            for (int i = 0; i < DEPTH; i++)
            if (tag_valid_d[i] && tag_addr_d[i] == pending_addr_d[commit_id_i[c]])
              tag_valid_d[i] = 1'b0;
          end
          CA_UNTAG_ALL: begin
            tag_valid_d = '0;
            revoked_d   = 1'b0;
            cafail_d    = 1'b0;
          end
          default: ;
        endcase
        pending_valid_d[commit_id_i[c]] = 1'b0;
      end
    end

    // a failed cwrite is non-speculative, it runs at commit
    if (cwrite_fail_i) cafail_d = 1'b1;

    if (issue_valid_i && !flush_i && issue_op_i inside {CA_CREAD, CA_UNTAG_ONE, CA_UNTAG_ALL}) begin
      pending_valid_d[issue_id_i]       = 1'b1;
      pending_op_d[issue_id_i]          = issue_op_i;
      pending_addr_d[issue_id_i]        = line_address(issue_addr_i);
      pending_invalidated_d[issue_id_i] = 1'b0;
      pending_failed_d[issue_id_i]      = 1'b0;
    end
    // after the issue: a cache hit records and answers a cread in one cycle
    if (cread_fail_valid_i) pending_failed_d[cread_fail_id_i] = 1'b1;

    // invalidations: a tagged line revokes access, a pending cread remembers
    for (int i = 0; i < DEPTH; i++) begin
      if (tag_valid_d[i] && invalidates(tag_addr_d[i])) begin
        tag_valid_d[i] = 1'b0;
        revoked_d = 1'b1;
      end
    end
    for (int i = 0; i < PENDING_DEPTH; i++) begin
      if (pending_valid_d[i] && pending_op_d[i] == CA_CREAD && invalidates(pending_addr_d[i]))
        pending_invalidated_d[i] = 1'b1;
    end

    if (flush_i) pending_valid_d = '0;
  end

  always_comb begin : p_status
    automatic logic tag_hit_now, pending_lost;
    tag_hit_now = 1'b0;
    pending_lost = 1'b0;
    cwrite_allowed_o = 1'b0;
    untag_all_pending_o = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (tag_valid_q[i] && invalidates(tag_addr_q[i])) tag_hit_now = 1'b1;
      if (tag_valid_q[i] && tag_addr_q[i] == line_address(cwrite_addr_i)) cwrite_allowed_o = 1'b1;
    end
    for (int i = 0; i < PENDING_DEPTH; i++) begin
      if (pending_valid_q[i] && pending_op_q[i] == CA_CREAD &&
          (pending_invalidated_q[i] || invalidates(pending_addr_q[i])))
        pending_lost = 1'b1;
      if (pending_valid_q[i] && pending_op_q[i] == CA_UNTAG_ALL) untag_all_pending_o = 1'b1;
    end
    // cwrite: the address is tagged and access is not (being) revoked
    cwrite_allowed_o = cwrite_allowed_o && !revoked_q && !tag_hit_now;
    cread_revoked_o  = revoked_q || tag_hit_now || pending_lost;
    access_revoked_o = revoked_q;
    cafail_o         = cafail_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      tag_valid_q           <= '0;
      tag_addr_q            <= '0;
      pending_valid_q       <= '0;
      pending_op_q          <= {PENDING_DEPTH{CA_NONE}};
      pending_addr_q        <= '0;
      pending_invalidated_q <= '0;
      pending_failed_q      <= '0;
      revoked_q             <= 1'b0;
      cafail_q              <= 1'b0;
    end else begin
      tag_valid_q           <= tag_valid_d;
      tag_addr_q            <= tag_addr_d;
      pending_valid_q       <= pending_valid_d;
      pending_op_q          <= pending_op_d;
      pending_addr_q        <= pending_addr_d;
      pending_invalidated_q <= pending_invalidated_d;
      pending_failed_q      <= pending_failed_d;
      revoked_q             <= revoked_d;
      cafail_q              <= cafail_d;
    end
  end

  //pragma translate_off
  initial begin : p_parameter_checks
    assert (DEPTH > 0) else $fatal(1, "CA tag-set depth must be nonzero");
    assert (LINE_OFFSET_BITS < ADDR_WIDTH) else $fatal(1, "CA line offset too large");
  end
  //pragma translate_on

endmodule
