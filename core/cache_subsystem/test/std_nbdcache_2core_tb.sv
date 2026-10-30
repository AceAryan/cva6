// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.
//
// Description: Phase 2 testbench: two std_nbdcache L1s kept coherent by
//              cc_bus (MSI), sharing one AXI memory. Checks every cycle that
//              a line is M in at most one cache (and then I in the other),
//              that loads are linearizable, that AMOs are atomic and exact,
//              that an SC never succeeds after the other core wrote the line,
//              and that every operation completes (no deadlock/livelock).
//
//              All TB inputs change at the falling edge; combinational DUT
//              outputs are observed 1 time unit later.

`include "axi/typedef.svh"

module std_nbdcache_2core_tb;
  import ariane_pkg::*;
  import std_cache_pkg::*;

  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  localparam int unsigned NC = 2;  // caches
  localparam int unsigned NumPorts = 4;
  localparam int unsigned LdPort = 1;
  localparam int unsigned StPort = 3;
  localparam int unsigned IDX_W = CVA6Cfg.DCACHE_INDEX_WIDTH;
  localparam int unsigned TAG_W = CVA6Cfg.DCACHE_TAG_WIDTH;
  localparam int unsigned OFF_W = CVA6Cfg.DCACHE_OFFSET_WIDTH;
  localparam int unsigned WAYS = CVA6Cfg.DCACHE_SET_ASSOC;
  localparam int unsigned SETS = CVA6Cfg.DCACHE_NUM_WORDS;
  localparam int unsigned LINE_BYTES = CVA6Cfg.DCACHE_LINE_WIDTH / 8;
  localparam logic [63:0] BASE = 64'h8000_0000;
  localparam int unsigned OP_TIMEOUT = 10000;  // cycles for any single operation
  localparam int unsigned MH_IDLE = 0;

  // ------------------
  // Types
  // ------------------
  typedef logic [CVA6Cfg.AxiAddrWidth-1:0] axi_addr_t;
  typedef logic [CVA6Cfg.AxiDataWidth-1:0] axi_data_t;
  typedef logic [CVA6Cfg.AxiDataWidth/8-1:0] axi_strb_t;
  typedef logic [CVA6Cfg.AxiIdWidth-1:0] axi_id_t;
  typedef logic [CVA6Cfg.AxiUserWidth-1:0] axi_user_t;
  `AXI_TYPEDEF_ALL(axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

  typedef struct packed {
    logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [CVA6Cfg.XLEN-1:0]               data_wdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                                  data_req;
    logic                                  data_we;
    logic [(CVA6Cfg.XLEN/8)-1:0]           data_be;
    logic [1:0]                            data_size;
    logic [CVA6Cfg.DcacheIdWidth-1:0]      data_id;
    logic                                  kill_req;
    logic                                  tag_valid;
    logic [7:0]                            cbo_op;
    wt_cache_pkg::ca_op_t                  ca_op;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0]      ca_id;
  } dcache_req_i_t;

  typedef struct packed {
    logic                                 data_gnt;
    logic                                 data_rvalid;
    logic [CVA6Cfg.DcacheIdWidth-1:0]     data_rid;
    logic [CVA6Cfg.XLEN-1:0]              data_rdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] data_ruser;
    logic                                 ca_access_revoked;
    logic                                 data_error;
  } dcache_req_o_t;

  typedef enum int {
    ST_I,
    ST_S,
    ST_M
  } msi_e;

  // ------------------
  // DUTs and bus
  // ------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [NC-1:0] flush, flush_ack;
  dcache_req_i_t [NumPorts-1:0] req_ports_i[NC];
  dcache_req_o_t [NumPorts-1:0] req_ports_o[NC];
  amo_req_t amo_req[NC];
  amo_resp_t amo_resp[NC];
  axi_req_t axi_req[2*NC];  // per cache: refill/write-back, bypass
  axi_resp_t axi_rsp[2*NC];
  cc_req_t [NC-1:0] cc_req;
  logic [NC-1:0] cc_gnt, cc_done;
  cc_snoop_t [NC-1:0] snoop;
  logic [NC-1:0] snoop_ready, snoop_ack;
  logic bus_busy;
  logic [0:0] bus_owner;

  for (genvar c = 0; c < NC; c++) begin : gen_core
    std_nbdcache #(
        .CVA6Cfg(CVA6Cfg),
        .dcache_req_i_t(dcache_req_i_t),
        .dcache_req_o_t(dcache_req_o_t),
        .NumPorts(NumPorts),
        .axi_req_t(axi_req_t),
        .axi_rsp_t(axi_resp_t)
    ) dut (
        .clk_i        (clk),
        .rst_ni       (rst_n),
        .enable_i     (1'b1),
        .flush_i      (flush[c]),
        .flush_ack_o  (flush_ack[c]),
        .miss_o       (),
        .amo_req_i    (amo_req[c]),
        .amo_resp_o   (amo_resp[c]),
        .req_ports_i  (req_ports_i[c]),
        .req_ports_o  (req_ports_o[c]),
        .axi_data_o   (axi_req[2*c]),
        .axi_data_i   (axi_rsp[2*c]),
        .axi_bypass_o (axi_req[2*c+1]),
        .axi_bypass_i (axi_rsp[2*c+1]),
        .cc_req_o     (cc_req[c]),
        .cc_gnt_i     (cc_gnt[c]),
        .cc_done_o    (cc_done[c]),
        .snoop_i      (snoop[c]),
        .snoop_ready_o(snoop_ready[c]),
        .snoop_ack_o  (snoop_ack[c])
    );
  end

  cc_bus #(
      .NumCaches(NC)
  ) i_bus (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .req_i        (cc_req),
      .gnt_o        (cc_gnt),
      .done_i       (cc_done),
      .snoop_o      (snoop),
      .snoop_ready_i(snoop_ready),
      .snoop_ack_i  (snoop_ack),
      .busy_o       (bus_busy),
      .owner_o      (bus_owner)
  );

  // ------------------
  // Memory and golden model
  // ------------------
  logic [7:0] mem[logic [63:0]];  // backing store; a write lands when its B is sent
  logic [31:0] hist[logic [63:0]][$];  // per 32b word: every value it held, in order
  int unsigned line_wr[logic [63:0]][NC];  // per line: writes performed by each core
  int unsigned n_errors = 0;

  function automatic logic [7:0] init_byte(input logic [63:0] a);
    return a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'h5a;
  endfunction

  function automatic logic [7:0] mem_rd(input logic [63:0] a);
    return mem.exists(a) ? mem[a] : init_byte(a);
  endfunction

  function automatic logic [31:0] mem_rd_word(input logic [63:0] a);
    return {mem_rd(a + 3), mem_rd(a + 2), mem_rd(a + 1), mem_rd(a)};
  endfunction

  function automatic logic [63:0] line_of(input logic [63:0] a);
    return {a[63:OFF_W], {OFF_W{1'b0}}};
  endfunction

  function automatic void hist_init(input logic [63:0] wa);
    if (!hist.exists(wa)) hist[wa].push_back(mem_rd_word(wa));
  endfunction

  function automatic logic [31:0] gold(input logic [63:0] wa);
    hist_init(wa);
    return hist[wa][$];
  endfunction

  function automatic void gold_write(input int c, input logic [63:0] wa, input logic [31:0] d);
    hist_init(wa);
    hist[wa].push_back(d);
    if (!line_wr.exists(line_of(wa))) line_wr[line_of(wa)] = '{default: 0};
    line_wr[line_of(wa)][c]++;
  endfunction

  function automatic int unsigned writes_by(input int c, input logic [63:0] a);
    return line_wr.exists(line_of(a)) ? line_wr[line_of(a)][c] : 0;
  endfunction

  function automatic void error(input string msg);
    n_errors++;
    $display("[%0t] ERROR: %s", $time, msg);
    if (n_errors > 20) $fatal(1, "too many errors");
  endfunction

  task automatic wait_timeout(inout int unsigned t, input string what);
    t++;
    if (t > OP_TIMEOUT)
      $fatal(1, "[%0t] liveness: %s did not complete in %0d cycles", $time, what, OP_TIMEOUT);
  endtask

  // ------------------
  // AXI memory, one slave per cache port, one shared store
  // ------------------
  int unsigned axi_stall_pct = 30;
  int unsigned n_axi_writes, n_axi_reads;

  for (genvar p = 0; p < 2 * NC; p++) begin : gen_axi_mem
    typedef struct {
      axi_aw_chan_t aw;
      axi_w_chan_t  w[$];
    } wr_t;
    typedef struct {
      axi_ar_chan_t ar;
      int unsigned  beat;
    } rd_t;

    axi_aw_chan_t aw_q[$];
    axi_w_chan_t w_q[$];
    wr_t b_q[$];
    rd_t r_q[$];

    initial begin
      int unsigned seed;
      if (!$value$plusargs("seed=%d", seed)) seed = 1;
      void'($urandom(seed * 7 + p + 1));
      axi_rsp[p] = '0;
      forever begin
        @(negedge clk);
        axi_rsp[p].aw_ready = rst_n && ($urandom_range(99) >= axi_stall_pct);
        axi_rsp[p].w_ready = rst_n && ($urandom_range(99) >= axi_stall_pct);
        axi_rsp[p].ar_ready = rst_n && ($urandom_range(99) >= axi_stall_pct);
        axi_rsp[p].b_valid = (b_q.size() != 0) && ($urandom_range(99) >= axi_stall_pct);
        if (b_q.size() != 0) begin
          axi_rsp[p].b.id = b_q[0].aw.id;
          axi_rsp[p].b.resp = axi_pkg::RESP_OKAY;
        end
        axi_rsp[p].r_valid = (r_q.size() != 0) && ($urandom_range(99) >= axi_stall_pct);
        if (r_q.size() != 0) begin
          automatic logic [63:0] a;
          a = (r_q[0].ar.addr & ~64'(CVA6Cfg.AxiDataWidth / 8 - 1)) +
              r_q[0].beat * (CVA6Cfg.AxiDataWidth / 8);
          for (int b = 0; b < CVA6Cfg.AxiDataWidth / 8; b++)
          axi_rsp[p].r.data[b*8+:8] = mem_rd(a + b);
          axi_rsp[p].r.id = r_q[0].ar.id;
          axi_rsp[p].r.resp = axi_pkg::RESP_OKAY;
          axi_rsp[p].r.last = (r_q[0].beat == r_q[0].ar.len);
        end
        #1;
        if (axi_req[p].aw_valid && axi_rsp[p].aw_ready) begin
          if (axi_req[p].aw.atop != '0) error("unexpected AXI atomic, cacheable AMOs run in the cache");
          aw_q.push_back(axi_req[p].aw);
        end
        if (axi_req[p].w_valid && axi_rsp[p].w_ready) w_q.push_back(axi_req[p].w);
        if (axi_req[p].ar_valid && axi_rsp[p].ar_ready) begin
          automatic rd_t r;
          if (axi_req[p].ar.burst != axi_pkg::BURST_INCR && axi_req[p].ar.len != 0)
            error("only INCR read bursts are modelled");
          r.ar = axi_req[p].ar;
          r.beat = 0;
          r_q.push_back(r);
          n_axi_reads++;
        end
        if (axi_rsp[p].r_valid && axi_req[p].r_ready) begin
          if (r_q[0].beat == r_q[0].ar.len) void'(r_q.pop_front());
          else r_q[0].beat++;
        end
        if (axi_rsp[p].b_valid && axi_req[p].b_ready) begin
          automatic wr_t wr = b_q.pop_front();
          for (int i = 0; i < wr.w.size(); i++) begin
            automatic logic [63:0] a;
            a = (wr.aw.addr & ~64'(CVA6Cfg.AxiDataWidth / 8 - 1)) + i * (CVA6Cfg.AxiDataWidth / 8);
            for (int b = 0; b < CVA6Cfg.AxiDataWidth / 8; b++)
            if (wr.w[i].strb[b]) mem[a+b] = wr.w[i].data[b*8+:8];
          end
          n_axi_writes++;
        end
        if (aw_q.size() != 0) begin
          automatic int last = -1;
          foreach (w_q[i]) if (last < 0 && w_q[i].last) last = i;
          if (last >= 0) begin
            automatic wr_t wr;
            wr.w.delete();  // block locals are not re-initialised per iteration
            wr.aw = aw_q.pop_front();
            for (int i = 0; i <= last; i++) wr.w.push_back(w_q.pop_front());
            if (wr.w.size() != int'(wr.aw.len) + 1) error("AXI write beat count mismatch");
            b_q.push_back(wr);
          end
        end
      end
    end
  end

  // ------------------
  // Line state of both caches, read straight from the arrays
  // ------------------
  // direct reads of the arrays; generate scopes need constant indices, so the
  // 2 caches x 8 ways are spelled out
`define TB_TAG(C, W) \
  gen_core[C].dut.sram_block[W].tag_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[set]
`define TB_VD(C) gen_core[C].dut.valid_dirty_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[set]

  initial if (WAYS != 8 || NC != 2) $fatal(1, "state peek is written for 2 caches x 8 ways");

  function automatic logic [63:0] tag_rd(input int c, input int w, input int set);
    case (c * 8 + w)
      0: return `TB_TAG(0, 0);
      1: return `TB_TAG(0, 1);
      2: return `TB_TAG(0, 2);
      3: return `TB_TAG(0, 3);
      4: return `TB_TAG(0, 4);
      5: return `TB_TAG(0, 5);
      6: return `TB_TAG(0, 6);
      7: return `TB_TAG(0, 7);
      8: return `TB_TAG(1, 0);
      9: return `TB_TAG(1, 1);
      10: return `TB_TAG(1, 2);
      11: return `TB_TAG(1, 3);
      12: return `TB_TAG(1, 4);
      13: return `TB_TAG(1, 5);
      14: return `TB_TAG(1, 6);
      15: return `TB_TAG(1, 7);
      default: return '0;
    endcase
  endfunction

  function automatic logic [63:0] vd_rd(input int c, input int set);
    return (c == 0) ? `TB_VD(0) : `TB_VD(1);
  endfunction

  function automatic msi_e state_of(input int c, input logic [63:0] addr);
    automatic int set = addr[IDX_W-1:OFF_W];
    automatic int hits = 0;
    automatic msi_e st = ST_I;
    for (int w = 0; w < WAYS; w++) begin
      automatic logic [63:0] vd = vd_rd(c, set);
      if (vd[8*w+1] && tag_rd(c, w, set) [TAG_W-1:0] == addr[IDX_W+TAG_W-1:IDX_W]) begin
        hits++;
        st = vd[8*w+2] ? ST_M : ST_S;
        if (vd[8*w] && !vd[8*w+2])
          error($sformatf("cache %0d line %h dirty but not owned", c, addr));
      end
    end
    if (hits > 1) error($sformatf("cache %0d line %h present in %0d ways", c, addr, hits));
    return st;
  endfunction

  // single writer, multiple readers: checked every cycle on every line used
  logic [63:0] pool[$];
  int unsigned n_swmr_checks = 0;
  initial begin
    forever begin
      @(negedge clk);
      #1;
      if (!rst_n) continue;
      foreach (pool[i]) begin
        automatic msi_e s0 = state_of(0, pool[i]);
        automatic msi_e s1 = state_of(1, pool[i]);
        n_swmr_checks++;
        if ((s0 == ST_M && s1 != ST_I) || (s1 == ST_M && s0 != ST_I))
          error($sformatf("SWMR violated on %h: cache0=%s cache1=%s", pool[i], s0.name(), s1.name()));
      end
    end
  end

  // fairness: a cache that keeps requesting is served before the other cache
  // gets a second tenure
  int unsigned skipped[NC];
  int unsigned max_skipped = 0;
  initial begin
    forever begin
      @(negedge clk);
      #1;
      if (!rst_n) continue;
      for (int c = 0; c < NC; c++) begin
        if (cc_gnt[c]) skipped[c] = 0;
        else if (cc_gnt[1-c] && cc_req[c].valid) begin
          skipped[c]++;
          if (skipped[c] > max_skipped) max_skipped = skipped[c];
          if (skipped[c] > 1) error($sformatf("cache %0d passed over twice while requesting", c));
        end
      end
    end
  end

  function automatic void use_line(input logic [63:0] a);
    foreach (pool[i]) if (pool[i] == line_of(a)) return;
    pool.push_back(line_of(a));
  endfunction

  // ------------------
  // Drivers
  // ------------------
  int unsigned n_ld[NC], n_st[NC], n_amo[NC], n_sc_ok[NC], n_sc_fail[NC];

  task automatic do_load(input int c, input logic [63:0] addr, output logic [31:0] data);
    int unsigned t;
    int unsigned ver_lo;
    logic [63:0] wa;
    logic ok;
    t = 0;
    wa = {addr[63:2], 2'b00};
    use_line(addr);
    @(negedge clk);
    req_ports_i[c][LdPort] = '0;
    req_ports_i[c][LdPort].data_req = 1'b1;
    req_ports_i[c][LdPort].address_index = addr[IDX_W-1:0];
    req_ports_i[c][LdPort].data_be = '1;
    req_ports_i[c][LdPort].data_size = 2'b10;
    #1;
    while (!req_ports_o[c][LdPort].data_gnt) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("core %0d load gnt %h", c, addr));
    end
    hist_init(wa);
    ver_lo = hist[wa].size() - 1;
    @(negedge clk);
    req_ports_i[c][LdPort].data_req = 1'b0;
    req_ports_i[c][LdPort].tag_valid = 1'b1;
    req_ports_i[c][LdPort].address_tag = addr[IDX_W+TAG_W-1:IDX_W];
    #1;
    while (!req_ports_o[c][LdPort].data_rvalid) begin
      @(negedge clk);
      req_ports_i[c][LdPort].tag_valid = 1'b0;
      #1;
      wait_timeout(t, $sformatf("core %0d load rvalid %h", c, addr));
    end
    data = req_ports_o[c][LdPort].data_rdata;
    ok = 1'b0;
    for (int i = ver_lo; i < hist[wa].size(); i++) if (hist[wa][i] === data) ok = 1'b1;
    if (!ok)
      error($sformatf("core %0d load %h returned %h, expected %h or later", c, addr, data,
                      hist[wa][ver_lo]));
    n_ld[c]++;
    @(negedge clk);
    req_ports_i[c][LdPort].tag_valid = 1'b0;
  endtask

  task automatic do_store(input int c, input logic [63:0] addr, input logic [31:0] data);
    int unsigned t;
    t = 0;
    use_line(addr);
    @(negedge clk);
    req_ports_i[c][StPort] = '0;
    req_ports_i[c][StPort].data_req = 1'b1;
    req_ports_i[c][StPort].data_we = 1'b1;
    req_ports_i[c][StPort].address_index = addr[IDX_W-1:0];
    req_ports_i[c][StPort].address_tag = addr[IDX_W+TAG_W-1:IDX_W];
    req_ports_i[c][StPort].data_wdata = data;
    req_ports_i[c][StPort].data_be = '1;
    req_ports_i[c][StPort].data_size = 2'b10;
    #1;
    while (!req_ports_o[c][StPort].data_gnt) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("core %0d store gnt %h", c, addr));
    end
    gold_write(c, {addr[63:2], 2'b00}, data);
    n_st[c]++;
    @(negedge clk);
    req_ports_i[c][StPort] = '0;
  endtask

  // LR reservation as the TB sees it: line and the other core's write count
  logic [63:0] tb_resv_line[NC];
  int unsigned tb_resv_other[NC];

  function automatic logic [31:0] amo_expect(input amo_t op, input logic [31:0] a,
                                             input logic [31:0] b);
    case (op)
      AMO_SWAP: return b;
      AMO_ADD:  return a + b;
      AMO_AND:  return a & b;
      AMO_OR:   return a | b;
      AMO_XOR:  return a ^ b;
      AMO_MAX:  return ($signed(a) > $signed(b)) ? a : b;
      AMO_MIN:  return ($signed(a) < $signed(b)) ? a : b;
      AMO_MAXU: return (a > b) ? a : b;
      AMO_MINU: return (a < b) ? a : b;
      default:  return b;  // SC
    endcase
  endfunction

  // AMOs are performed in the acknowledged cycle, under the cache's tenure
  task automatic do_amo(input int c, input amo_t op, input logic [63:0] addr,
                        input logic [31:0] opb, output logic [31:0] res);
    int unsigned t;
    logic [63:0] wa;
    logic [31:0] old;
    t = 0;
    wa = {addr[63:2], 2'b00};
    use_line(addr);
    @(negedge clk);
    amo_req[c].req = 1'b1;
    amo_req[c].amo_op = op;
    amo_req[c].size = 2'b10;
    amo_req[c].operand_a = addr;
    amo_req[c].operand_b = {32'b0, opb};
    #1;
    while (!amo_resp[c].ack) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("core %0d %s %h", c, op.name(), addr));
    end
    res = amo_resp[c].result[31:0];
    if (amo_resp[c].result[63:32] !== {32{res[31]}})
      error($sformatf("core %0d %s result not sign-extended: %h", c, op.name(), amo_resp[c].result));
    old = gold(wa);
    case (op)
      AMO_LR: begin
        if (res !== old) error($sformatf("core %0d LR %h returned %h, memory holds %h", c, addr, res, old));
        tb_resv_line[c] = line_of(addr);
        tb_resv_other[c] = writes_by(1 - c, addr);
      end
      AMO_SC: begin
        if (res == 0) begin
          if (tb_resv_line[c] != line_of(addr))
            error($sformatf("core %0d SC %h succeeded without an LR on that line", c, addr));
          if (writes_by(1 - c, addr) != tb_resv_other[c])
            error($sformatf("core %0d SC %h succeeded although core %0d wrote the line", c, addr, 1 - c));
          gold_write(c, wa, opb);
          n_sc_ok[c]++;
        end else begin
          if (res != 1) error($sformatf("core %0d SC returned %h", c, res));
          n_sc_fail[c]++;
        end
        tb_resv_line[c] = '1;
      end
      default: begin
        if (res !== old)
          error($sformatf("core %0d %s %h returned %h, memory holds %h", c, op.name(), addr, res, old));
        gold_write(c, wa, amo_expect(op, old, opb));
      end
    endcase
    n_amo[c]++;
    @(negedge clk);
    amo_req[c] = '0;
  endtask

  task automatic do_flush(input int c);
    int unsigned t;
    t = 0;
    @(negedge clk);
    flush[c] = 1'b1;
    #1;
    while (!flush_ack[c]) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("core %0d flush", c));
    end
    @(negedge clk);
    flush[c] = 1'b0;
  endtask

  task automatic settle();
    int unsigned t;
    t = 0;
    while (bus_busy || int'(gen_core[0].dut.i_miss_handler.state_q) != MH_IDLE ||
           int'(gen_core[1].dut.i_miss_handler.state_q) != MH_IDLE) begin
      @(negedge clk);
      #1;
      wait_timeout(t, "settle");
    end
  endtask

  task automatic expect_states(input logic [63:0] addr, input msi_e e0, input msi_e e1,
                               input string ctx);
    msi_e s0, s1;
    settle();
    s0 = state_of(0, addr);
    s1 = state_of(1, addr);
    if (s0 != e0 || s1 != e1)
      error($sformatf("%s: line %h is %s/%s, expected %s/%s", ctx, addr, s0.name(), s1.name(),
                      e0.name(), e1.name()));
  endtask

  function automatic logic [63:0] la(input int unsigned set, input int unsigned tag,
                                     input int unsigned word = 0);
    return BASE + (64'(tag) << IDX_W) + (64'(set) << OFF_W) + 64'(4 * word);
  endfunction

  // ------------------
  // Tests
  // ------------------
  task automatic test_handoff();
    logic [31:0] d;
    logic [63:0] x;
    $display("[%0t] T1: A writes, B reads, B writes", $time);
    x = la(1, 1);
    do_store(0, x, 32'haaaa_0001);
    expect_states(x, ST_M, ST_I, "A wrote");
    do_load(1, x, d);
    if (d != 32'haaaa_0001) error($sformatf("B read %h, not A's value", d));
    expect_states(x, ST_S, ST_S, "B read");
    do_store(1, x, 32'hbbbb_0002);
    expect_states(x, ST_I, ST_M, "B wrote");
    do_load(0, x, d);
    if (d != 32'hbbbb_0002) error($sformatf("A read %h, not B's value", d));
    expect_states(x, ST_S, ST_S, "A read back");
    // the other word of the line survives every hand-off
    do_store(0, la(1, 1, 1), 32'haaaa_0003);
    expect_states(x, ST_M, ST_I, "A wrote word 1");
    do_load(1, x, d);
    if (d != 32'hbbbb_0002) error($sformatf("word 0 lost: %h", d));
    do_load(1, la(1, 1, 1), d);
    if (d != 32'haaaa_0003) error($sformatf("word 1 lost: %h", d));
  endtask

  // both caches ask for ownership of the same line in the same cycle
  task automatic test_simultaneous_getm(input int unsigned rounds);
    $display("[%0t] T2: simultaneous GetM, %0d rounds", $time, rounds);
    for (int r = 0; r < rounds; r++) begin
      automatic logic [63:0] x = la(2, 1 + r % 3, r % 4);
      automatic logic [31:0] d;
      // start from a random sharing state
      case (r % 3)
        0: begin
          do_load(0, x, d);
          do_load(1, x, d);
        end
        1: do_store(0, x, $urandom);
        default: ;
      endcase
      settle();
      fork
        do_store(0, x, 32'hc000_0000 + r);
        do_store(1, x, 32'hd000_0000 + r);
      join
      settle();
      // exactly one of them holds the line now, and its value is the last write
      begin
        automatic msi_e s0 = state_of(0, x), s1 = state_of(1, x);
        if (!((s0 == ST_M && s1 == ST_I) || (s0 == ST_I && s1 == ST_M)))
          error($sformatf("after racing stores %h is %s/%s", x, s0.name(), s1.name()));
      end
      do_load(r % 2, x, d);
      if (d != gold({x[63:2], 2'b00})) error($sformatf("racing stores: read %h", d));
    end
    // and the same with AMOs on one counter
    fork
      for (int i = 0; i < rounds; i++) begin
        logic [31:0] d;
        do_amo(0, AMO_ADD, la(3, 1), 1, d);
      end
      for (int i = 0; i < rounds; i++) begin
        logic [31:0] d;
        do_amo(1, AMO_ADD, la(3, 1), 1, d);
      end
    join
  endtask

  // atomicity: counters incremented by both cores
  bit amo_seen[logic [31:0]];

  task automatic amo_incrementer(input int c, input logic [63:0] ca, input int unsigned n);
    for (int i = 0; i < n; i++) begin
      logic [31:0] old;
      do_amo(c, AMO_ADD, ca, 1, old);
      if (amo_seen.exists(old)) error($sformatf("two AMOs returned the same old value %0d", old));
      amo_seen[old] = 1;
    end
  endtask

  task automatic lrsc_incrementer(input int c, input logic [63:0] cl, input int unsigned n);
    for (int i = 0; i < n; i++) begin
      logic [31:0] v, r;
      int unsigned tries;
      tries = 0;
      do begin
        do_amo(c, AMO_LR, cl, 0, v);
        do_amo(c, AMO_SC, cl, v + 1, r);
        tries++;
        if ($test$plusargs("lrscdebug"))
          $display("[%0t] core %0d LR=%h SC->%0d resv=%b", $time, c, v, r,
                   (c == 0) ? gen_core[0].dut.i_miss_handler.resv_valid_q :
                              gen_core[1].dut.i_miss_handler.resv_valid_q);
        if (tries > 500) $fatal(1, "[%0t] livelock: core %0d LR/SC did not succeed", $time, c);
      end while (r != 0);
    end
  endtask

  task automatic test_counters(input int unsigned n);
    logic [63:0] ca, cl;
    logic [31:0] d;
    $display("[%0t] T3: AMO and LR/SC counters, %0d increments per core", $time, n);
    ca = la(4, 1);
    cl = la(4, 2);  // same set, different line
    do_store(0, ca, 32'h0);
    do_store(0, cl, 32'h0);
    amo_seen.delete();
    fork
      amo_incrementer(0, ca, n);
      amo_incrementer(1, ca, n);
    join
    $display("[%0t] T3: LR/SC on one line from both cores", $time);
    fork
      lrsc_incrementer(0, cl, n);
      lrsc_incrementer(1, cl, n);
    join
    $display("[%0t] T3: AMO and LR/SC on two lines of one set", $time);
    // both at once, on lines of the same set
    fork
      amo_incrementer(0, ca, n);
      lrsc_incrementer(1, cl, n);
    join
    do_load(1, ca, d);
    if (d != 3 * n) error($sformatf("AMO counter is %0d, expected %0d", d, 3 * n));
    do_load(0, cl, d);
    if (d != 3 * n) error($sformatf("LR/SC counter is %0d, expected %0d", d, 3 * n));
  endtask

  // random traffic from both cores on a small pool of lines
  bit pause[NC];
  bit ld_active[NC], st_active[NC];

  function automatic logic [63:0] rnd_addr(input int unsigned nsets, input int unsigned ntags);
    return la(40 + $urandom_range(nsets - 1), $urandom_range(ntags - 1), $urandom_range(3));
  endfunction

  task automatic agent_load(input int c, input int unsigned n, input int unsigned nsets,
                            input int unsigned ntags);
    for (int i = 0; i < n; i++) begin
      logic [31:0] d;
      while (pause[c]) @(negedge clk);
      ld_active[c] = 1;
      do_load(c, rnd_addr(nsets, ntags), d);
      ld_active[c] = 0;
    end
  endtask

  task automatic agent_store(input int c, input int unsigned n, input int unsigned nsets,
                             input int unsigned ntags);
    for (int i = 0; i < n; i++) begin
      while (pause[c]) @(negedge clk);
      st_active[c] = 1;
      do_store(c, rnd_addr(nsets, ntags), $urandom);
      st_active[c] = 0;
    end
  endtask

  // AMOs, LR/SC and flushes: the core's ports are drained first, as the commit
  // stage does
  task automatic agent_atomic(input int c, input int unsigned n, input int unsigned nsets,
                              input int unsigned ntags);
    for (int i = 0; i < n; i++) begin
      logic [63:0] a;
      logic [31:0] d;
      int unsigned t;
      repeat ($urandom_range(40)) @(negedge clk);
      pause[c] = 1;
      t = 0;
      while (ld_active[c] || st_active[c]) begin
        @(negedge clk);
        wait_timeout(t, "port drain");
      end
      a = rnd_addr(nsets, ntags);
      case ($urandom_range(5))
        0: do_amo(c, AMO_SWAP, a, $urandom, d);
        1: do_amo(c, AMO_ADD, a, $urandom, d);
        2: do_amo(c, amo_t'($urandom_range(AMO_AND, AMO_MINU)), a, $urandom, d);
        3: begin
          do_amo(c, AMO_LR, a, 0, d);
          // within the LR hold window, or long after it so the reservation
          // can be lost to the other core
          if ($urandom_range(1)) repeat ($urandom_range(20)) @(negedge clk);
          else repeat ($urandom_range(80, 300)) @(negedge clk);
          do_amo(c, AMO_SC, a, d + 1, d);
        end
        4: begin
          // SC without a preceding LR on that line must fail
          if ($urandom_range(1)) do_amo(c, AMO_LR, rnd_addr(nsets, ntags), 0, d);
          do_amo(c, AMO_SC, a, $urandom, d);
        end
        default: do_flush(c);
      endcase
      pause[c] = 0;
    end
  endtask

  task automatic test_random(input int unsigned n_ops, input int unsigned nsets,
                             input int unsigned ntags);
    $display("[%0t] T4: random, %0d ops per agent, %0d sets x %0d tags", $time, n_ops, nsets, ntags);
    for (int c = 0; c < NC; c++) begin
      pause[c] = 0;
      ld_active[c] = 0;
      st_active[c] = 0;
    end
    fork
      agent_load(0, n_ops, nsets, ntags);
      agent_store(0, n_ops, nsets, ntags);
      agent_atomic(0, n_ops / 8, nsets, ntags);
      agent_load(1, n_ops, nsets, ntags);
      agent_store(1, n_ops, nsets, ntags);
      agent_atomic(1, n_ops / 8, nsets, ntags);
    join
  endtask

  // ------------------
  // Main
  // ------------------
  initial begin
    int unsigned seed;
    int unsigned n_random;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("nrandom=%d", n_random)) n_random = 2000;
    void'($urandom(seed));
    $display("2-core MSI testbench, seed=%0d", seed);

    flush = '0;
    for (int c = 0; c < NC; c++) begin
      req_ports_i[c] = '0;
      amo_req[c] = '0;
      tb_resv_line[c] = '1;
    end
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    settle();

    test_handoff();
    test_simultaneous_getm(30);
    test_counters(60);
    // one random configuration per run: Verilator 5.032 asserts when a task
    // with fork/join is entered twice
    if ($test$plusargs("hot")) test_random(n_random, 1, 2);  // two hot lines
    else test_random(n_random, 2, 10);  // heavy sharing and evictions

    // write everything back and compare memory with the golden model
    do_flush(0);
    do_flush(1);
    foreach (hist[wa])
    if (mem_rd_word(wa) !== hist[wa][$])
      error($sformatf("final memory mismatch at %h: mem=%h gold=%h", wa, mem_rd_word(wa), hist[wa][$]));

    $display("coverage: loads=%0d/%0d stores=%0d/%0d amos=%0d/%0d sc ok=%0d/%0d sc fail=%0d/%0d",
             n_ld[0], n_ld[1], n_st[0], n_st[1], n_amo[0], n_amo[1], n_sc_ok[0], n_sc_ok[1],
             n_sc_fail[0], n_sc_fail[1]);
    $display("coverage: AXI line writes=%0d reads=%0d, SWMR checks=%0d, max times passed over=%0d",
             n_axi_writes, n_axi_reads, n_swmr_checks, max_skipped);
    if (n_errors != 0) $fatal(1, "FAILED with %0d errors", n_errors);
    $display("PASSED");
    $finish;
  end

  // per-cycle trace with +debug
  initial begin
    if ($test$plusargs("debug")) begin
      forever begin
        @(negedge clk);
        #1;
        $display("[%0t] mh0=%0d mh1=%0d bus=%0d own=%0d req=%b%b gnt=%b done=%b snp=%b rdy=%b ack=%b amo=%b%b",
                 $time, gen_core[0].dut.i_miss_handler.state_q,
                 gen_core[1].dut.i_miss_handler.state_q, i_bus.state_q, bus_owner, cc_req[1].valid,
                 cc_req[0].valid, cc_gnt, cc_done, {snoop[1].valid, snoop[0].valid}, snoop_ready,
                 snoop_ack, amo_req[1].req, amo_req[0].req);
      end
    end
  end

endmodule
