module wt_dcache_ca_tag_cmp_tb;

  localparam int unsigned DEPTH = 8;
  localparam int unsigned ADDR_WIDTH = 44;

  logic [DEPTH-1:0] valid;
  logic [DEPTH-1:0][ADDR_WIDTH-1:0] tag_set;
  logic [ADDR_WIDTH-1:0] query_addr;
  logic [DEPTH-1:0] match_oh;
  logic hit;

  wt_dcache_ca_tag_cmp #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DEPTH(DEPTH)
  ) dut (
      .valid_i(valid),
      .addr_i(tag_set),
      .query_addr_i(query_addr),
      .match_oh_o(match_oh),
      .hit_o(hit)
  );

  task automatic check_case(
      input string name,
      input logic [ADDR_WIDTH-1:0] addr,
      input logic legacy_ca_hit
  );
    query_addr = addr;
    #1;
    if (hit !== legacy_ca_hit) begin
      $fatal(1, "%s: comparator=%b expected legacy CA marker=%b", name, hit, legacy_ca_hit);
    end
  endtask

  initial begin
    valid = '0;
    tag_set = '0;
    tag_set[1] = 44'h123456789ab;
    tag_set[6] = 44'h23456789abc;
    valid[1] = 1'b1;
    valid[6] = 1'b1;

    check_case("tracked snoop hit", tag_set[1], 1'b1);
    check_case("untracked snoop miss", 44'h3456789abcd, 1'b0);
    check_case("tracked eviction hit", tag_set[6], 1'b1);
    check_case("untracked eviction miss", 44'h456789abcde, 1'b0);

    $finish;
  end

endmodule
