// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.

module wt_dcache_ca_tag_set
  import wt_cache_pkg::*;
#(
    parameter int unsigned DEPTH = 8,
    parameter int unsigned ADDR_WIDTH = 56,
    parameter int unsigned LINE_OFFSET_BITS = 6,
    parameter int unsigned ID_WIDTH = 4,
    parameter int unsigned PENDING_DEPTH = 1 << ID_WIDTH,
    parameter int unsigned NUM_COMMIT_PORTS = 1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,
    input logic issue_valid_i,
    input ca_op_t issue_op_i,
    input logic [ID_WIDTH-1:0] issue_id_i,
    input logic [ADDR_WIDTH-1:0] issue_addr_i,
    input logic [NUM_COMMIT_PORTS-1:0] commit_valid_i,
    input logic [NUM_COMMIT_PORTS-1:0][ID_WIDTH-1:0] commit_id_i,
    input logic invalidate_valid_i,
    input logic invalidate_all_i,
    input logic [ADDR_WIDTH-1:0] invalidate_addr_i,
    input logic [ADDR_WIDTH-1:0] cwrite_addr_i,
    output logic access_revoked_o,
    output logic cwrite_allowed_o,
    output logic [PENDING_DEPTH-1:0] query_failed_o
);

  logic [DEPTH-1:0] tag_valid_q, tag_valid_d;
  logic [DEPTH-1:0][ADDR_WIDTH-1:0] tag_addr_q, tag_addr_d;
  logic [PENDING_DEPTH-1:0] pending_valid_q, pending_valid_d;
  logic [PENDING_DEPTH-1:0][2:0] pending_op_q, pending_op_d;
  logic [PENDING_DEPTH-1:0][ADDR_WIDTH-1:0] pending_addr_q, pending_addr_d;
  logic [PENDING_DEPTH-1:0] pending_invalidated_q, pending_invalidated_d;
  logic revoked_q, revoked_d;
  logic cwrite_tag_found, committed_invalidate_match;

  function automatic logic [ADDR_WIDTH-1:0] line_address(input logic [ADDR_WIDTH-1:0] address);
    return (address >> LINE_OFFSET_BITS) << LINE_OFFSET_BITS;
  endfunction

  always_comb begin : p_tag_set
    logic found;
    logic free_found;
    logic committed_match;
    int unsigned free_idx;

    tag_valid_d = tag_valid_q;
    tag_addr_d = tag_addr_q;
    pending_valid_d = pending_valid_q;
    pending_op_d = pending_op_q;
    pending_addr_d = pending_addr_q;
    pending_invalidated_d = pending_invalidated_q;
    revoked_d = revoked_q;
    found = 1'b0;
    free_found = 1'b0;
    committed_match = 1'b0;
    free_idx = 0;

    for (int c = 0; c < NUM_COMMIT_PORTS; c++) begin
      if (commit_valid_i[c] && !flush_i && int'(commit_id_i[c]) < PENDING_DEPTH &&
          pending_valid_d[commit_id_i[c]]) begin
        unique case (pending_op_d[commit_id_i[c]])
          CA_CREAD: begin
            found = 1'b0;
            free_found = 1'b0;
            for (int i = 0; i < DEPTH; i++) begin
              if (tag_valid_d[i] && tag_addr_d[i] == pending_addr_d[commit_id_i[c]]) begin
                found = 1'b1;
              end else if (!tag_valid_d[i] && !free_found) begin
                free_found = 1'b1;
                free_idx = i;
              end
            end
            if (pending_invalidated_d[commit_id_i[c]]) begin
              revoked_d = 1'b1;
            end else if (!found) begin
              if (free_found) begin
                tag_valid_d[free_idx] = 1'b1;
                tag_addr_d[free_idx] = pending_addr_d[commit_id_i[c]];
              end else begin
                revoked_d = 1'b1;
              end
            end
          end
          CA_UNTAG_ONE: begin
            for (int i = 0; i < DEPTH; i++) begin
              if (tag_valid_d[i] && tag_addr_d[i] == pending_addr_d[commit_id_i[c]]) begin
                tag_valid_d[i] = 1'b0;
              end
            end
          end
          CA_UNTAG_ALL: begin
            tag_valid_d = '0;
            revoked_d = 1'b0;
          end
          default: begin
          end
        endcase
        pending_valid_d[commit_id_i[c]] = 1'b0;
        pending_invalidated_d[commit_id_i[c]] = 1'b0;
      end
    end

    if (issue_valid_i && !flush_i && int'(issue_id_i) < PENDING_DEPTH &&
        issue_op_i inside {CA_CREAD, CA_UNTAG_ONE, CA_UNTAG_ALL}) begin
      pending_valid_d[issue_id_i] = 1'b1;
      pending_op_d[issue_id_i] = issue_op_i;
      pending_addr_d[issue_id_i] = line_address(issue_addr_i);
      pending_invalidated_d[issue_id_i] = 1'b0;
    end

    if (invalidate_valid_i) begin
      for (int i = 0; i < DEPTH; i++) begin
        if (tag_valid_d[i] &&
            (invalidate_all_i || tag_addr_d[i] == line_address(invalidate_addr_i))) begin
          committed_match = 1'b1;
          tag_valid_d[i] = 1'b0;
        end
      end
      for (int i = 0; i < PENDING_DEPTH; i++) begin
        if (pending_valid_d[i] && pending_op_d[i] == CA_CREAD &&
            (invalidate_all_i || pending_addr_d[i] == line_address(invalidate_addr_i))) begin
          pending_invalidated_d[i] = 1'b1;
        end
      end
      if (committed_match) revoked_d = 1'b1;
    end

    if (flush_i) begin
      pending_valid_d = '0;
      pending_invalidated_d = '0;
    end
  end

  always_comb begin : p_status_lookup
    access_revoked_o = revoked_q;
    cwrite_tag_found = 1'b0;
    committed_invalidate_match = 1'b0;
    for (int i = 0; i < DEPTH; i++) begin
      if (tag_valid_q[i]) begin
        if (tag_addr_q[i] == line_address(cwrite_addr_i)) cwrite_tag_found = 1'b1;
        if (invalidate_valid_i &&
            (invalidate_all_i || tag_addr_q[i] == line_address(invalidate_addr_i))) begin
          committed_invalidate_match = 1'b1;
        end
      end
    end
    if (committed_invalidate_match) access_revoked_o = 1'b1;
    cwrite_allowed_o = cwrite_tag_found && !revoked_q && !committed_invalidate_match;
  end

  always_comb begin : p_query_status
    query_failed_o = '0;
    for (int i = 0; i < PENDING_DEPTH; i++) begin
      query_failed_o[i] = pending_valid_q[i] && pending_op_q[i] == CA_CREAD &&
                          !flush_i &&
                          (pending_invalidated_q[i] || (invalidate_valid_i &&
                            (invalidate_all_i ||
                             pending_addr_q[i] == line_address(invalidate_addr_i))));
    end
  end

  initial begin : p_parameter_checks
    assert (DEPTH > 0) else $fatal(1, "CA tag-set depth must be nonzero");
    assert (PENDING_DEPTH > 0 && PENDING_DEPTH <= (1 << ID_WIDTH))
    else $fatal(1, "CA pending depth must fit the transaction ID");
    assert (LINE_OFFSET_BITS < ADDR_WIDTH)
    else $fatal(1, "CA line offset must be smaller than the address width");
    assert (NUM_COMMIT_PORTS > 0) else $fatal(1, "CA needs at least one commit port");
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      tag_valid_q <= '0;
      tag_addr_q <= '0;
      pending_valid_q <= '0;
      pending_op_q <= '0;
      pending_addr_q <= '0;
      pending_invalidated_q <= '0;
      revoked_q <= 1'b0;
    end else begin
      tag_valid_q <= tag_valid_d;
      tag_addr_q <= tag_addr_d;
      pending_valid_q <= pending_valid_d;
      pending_op_q <= pending_op_d;
      pending_addr_q <= pending_addr_d;
      pending_invalidated_q <= pending_invalidated_d;
      revoked_q <= revoked_d;
    end
  end

endmodule
