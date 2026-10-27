module wt_dcache_ca_tag_set_tb;

  localparam int unsigned DEPTH = 2;
  localparam int unsigned ADDR_WIDTH = 16;
  localparam int unsigned ID_WIDTH = 2;
  localparam int unsigned NUM_COMMIT_PORTS = 2;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic flush;
  logic issue_valid;
  wt_cache_pkg::ca_op_t issue_op;
  logic [ID_WIDTH-1:0] issue_id;
  logic [ADDR_WIDTH-1:0] issue_addr;
  logic [NUM_COMMIT_PORTS-1:0] commit_valid;
  logic [NUM_COMMIT_PORTS-1:0][ID_WIDTH-1:0] commit_id;
  logic invalidate_valid;
  logic invalidate_all;
  logic [ADDR_WIDTH-1:0] invalidate_addr;
  logic [ADDR_WIDTH-1:0] cwrite_addr;
  logic [ID_WIDTH-1:0] query_id;
  logic revoked;
  logic cwrite_allowed;
  logic [(1 << ID_WIDTH)-1:0] query_failed;

  always #5 clk = ~clk;

  wt_dcache_ca_tag_set #(
      .DEPTH(DEPTH),
      .ADDR_WIDTH(ADDR_WIDTH),
      .LINE_OFFSET_BITS(4),
      .ID_WIDTH(ID_WIDTH),
      .NUM_COMMIT_PORTS(NUM_COMMIT_PORTS)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .flush_i(flush),
      .issue_valid_i(issue_valid),
      .issue_op_i(issue_op),
      .issue_id_i(issue_id),
      .issue_addr_i(issue_addr),
      .commit_valid_i(commit_valid),
      .commit_id_i(commit_id),
      .invalidate_valid_i(invalidate_valid),
      .invalidate_all_i(invalidate_all),
      .invalidate_addr_i(invalidate_addr),
      .cwrite_addr_i(cwrite_addr),
      .access_revoked_o(revoked),
      .cwrite_allowed_o(cwrite_allowed),
      .query_failed_o(query_failed)
  );

  task automatic cycle;
    @(posedge clk);
    #1;
  endtask

  task automatic issue(input wt_cache_pkg::ca_op_t op, input logic [ID_WIDTH-1:0] id,
                       input logic [ADDR_WIDTH-1:0] addr);
    issue_valid = 1'b1;
    issue_op = op;
    issue_id = id;
    issue_addr = addr;
    cycle();
    issue_valid = 1'b0;
  endtask

  task automatic commit(input logic [ID_WIDTH-1:0] id);
    commit_valid = '0;
    commit_valid[0] = 1'b1;
    commit_id[0] = id;
    cycle();
    commit_valid = '0;
  endtask

  initial begin
    flush = 1'b0;
    issue_valid = 1'b0;
    issue_op = wt_cache_pkg::CA_NONE;
    issue_id = '0;
    issue_addr = '0;
    commit_valid = '0;
    commit_id = '0;
    invalidate_valid = 1'b0;
    invalidate_all = 1'b0;
    invalidate_addr = '0;
    cwrite_addr = '0;
    query_id = '0;

    cycle();
    rst_n = 1'b1;
    cycle();

    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h1200);
    if (revoked) $fatal(1, "first CREAD unexpectedly revoked");
    commit(2'd0);
    cwrite_addr = 16'h1208;
    #1;
    if (!cwrite_allowed) $fatal(1, "tagged line did not allow CWRITE");
    cwrite_addr = 16'h1240;
    #1;
    if (cwrite_allowed) $fatal(1, "untagged line allowed CWRITE");
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h1208;
    #1;
    if (!revoked) $fatal(1, "same-line invalidation did not match");
    cycle();
    invalidate_valid = 1'b0;
    if (!revoked) $fatal(1, "same-line invalidation did not latch revocation");
    if (cwrite_allowed) $fatal(1, "revoked access allowed CWRITE");

    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd1, '0);
    commit(2'd1);
    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h1200);
    commit(2'd0);
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h1240;
    #1;
    if (revoked) $fatal(1, "different cache line unexpectedly matched");
    invalidate_addr = 16'h1200;
    #1;
    if (!revoked) $fatal(1, "matching invalidation was not visible combinationally");
    cycle();
    invalidate_valid = 1'b0;
    if (!revoked) $fatal(1, "matching invalidation did not latch revocation");

    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd1, '0);
    commit(2'd1);
    if (revoked) $fatal(1, "UNTAG_ALL did not clear revocation");

    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h2000);
    query_id = 2'd0;
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h2008;
    #1;
    if (revoked) $fatal(1, "speculative invalidation revoked before commit");
    if (!query_failed[query_id]) $fatal(1, "pending CREAD failure was not visible");
    query_id = 2'd1;
    #1;
    if (query_failed[query_id]) $fatal(1, "pending CREAD failure leaked to another ID");
    query_id = 2'd0;
    cycle();
    invalidate_valid = 1'b0;
    if (!query_failed[query_id]) $fatal(1, "pending CREAD failure was not retained");
    commit(2'd0);
    if (!revoked) $fatal(1, "invalidation before commit was lost");
    if (query_failed[query_id]) $fatal(1, "committed CREAD failure remained pending");
    cwrite_addr = 16'h2008;
    #1;
    if (cwrite_allowed) $fatal(1, "invalidated pending CREAD allowed CWRITE");

    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd1, '0);
    commit(2'd1);
    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h2800);
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h2800;
    #1;
    if (!query_failed[query_id]) $fatal(1, "pending CREAD invalidation was not visible");
    flush = 1'b1;
    #1;
    if (query_failed[query_id]) $fatal(1, "flush did not clear pending CREAD failure");
    cycle();
    flush = 1'b0;
    invalidate_valid = 1'b0;
    if (query_failed[query_id]) $fatal(1, "flushed CREAD left pending query state");
    commit(2'd0);
    if (revoked) $fatal(1, "flushed speculative CREAD committed stale state");

    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h3000);
    commit(2'd0);
    issue(wt_cache_pkg::CA_CREAD, 2'd1, 16'h3008);
    commit(2'd1);
    issue(wt_cache_pkg::CA_CREAD, 2'd2, 16'h4000);
    commit(2'd2);
    issue(wt_cache_pkg::CA_CREAD, 2'd3, 16'h5000);
    if (revoked) $fatal(1, "speculative overflow revoked before commit");
    commit(2'd3);
    if (!revoked) $fatal(1, "tag-set overflow did not revoke at commit");

    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd3, '0);
    commit(2'd3);
    if (cwrite_allowed) $fatal(1, "UNTAG_ALL left a CWRITE tag");
    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h6000);
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h6000;
    #1;
    if (revoked) $fatal(1, "speculative same-cycle invalidation revoked too early");
    cycle();
    invalidate_valid = 1'b0;
    commit(2'd0);
    if (!revoked) $fatal(1, "same-cycle issue/invalidation was lost at commit");
    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd3, '0);
    commit(2'd3);

    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h7000);
    issue(wt_cache_pkg::CA_CREAD, 2'd1, 16'h8000);
    commit_valid = 2'b11;
    commit_id[0] = 2'd0;
    commit_id[1] = 2'd1;
    cycle();
    commit_valid = '0;
    cwrite_addr = 16'h7008;
    #1;
    if (!cwrite_allowed) $fatal(1, "first simultaneous commit was lost");
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h7008;
    #1;
    if (!revoked) $fatal(1, "multi-port commit did not create both tags");
    cycle();
    invalidate_valid = 1'b0;
    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd2, '0);
    commit(2'd2);
    issue(wt_cache_pkg::CA_CREAD, 2'd1, 16'h8000);
    commit_valid = 2'b10;
    commit_id[1] = 2'd1;
    cycle();
    commit_valid = '0;
    cwrite_addr = 16'h8008;
    #1;
    if (!cwrite_allowed) $fatal(1, "second-port-only commit was lost");
    invalidate_valid = 1'b1;
    invalidate_addr = 16'h8008;
    #1;
    if (!revoked) $fatal(1, "second multi-port commit was not recorded");
    cycle();
    invalidate_valid = 1'b0;
    if (cwrite_allowed) $fatal(1, "invalidated tag allowed CWRITE");

    issue(wt_cache_pkg::CA_UNTAG_ALL, 2'd2, '0);
    commit(2'd2);
    issue(wt_cache_pkg::CA_CREAD, 2'd0, 16'h9000);
    commit(2'd0);
    cwrite_addr = 16'h9008;
    invalidate_valid = 1'b1;
    invalidate_all = 1'b1;
    #1;
    if (!revoked || cwrite_allowed) $fatal(1, "global invalidation did not revoke CWRITE");
    cycle();
    invalidate_valid = 1'b0;
    invalidate_all = 1'b0;

    $display("CA tag-set tests passed");
    $finish;
  end

endmodule
