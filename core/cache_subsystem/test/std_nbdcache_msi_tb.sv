// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.
//
// Description: Phase 1 MSI testbench for the write-back std_nbdcache. Drives
//              the load/store ports, a coherence-bus stub, and synthetic
//              snoops from a "remote" agent that writes memory directly after
//              a GetM. Checks line states (peeked from the arrays), write-back
//              data, linearizable load values, and liveness.
//
//              All TB inputs change at the falling edge; combinational DUT
//              outputs are observed 1 time unit later and take effect at the
//              next rising edge.

`include "axi/typedef.svh"

module std_nbdcache_msi_tb;
  import ariane_pkg::*;
  import std_cache_pkg::*;

  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  localparam int unsigned NumPorts = 4;
  localparam int unsigned LdPort = 1;
  localparam int unsigned StPort = 3;
  localparam int unsigned IDX_W = CVA6Cfg.DCACHE_INDEX_WIDTH;
  localparam int unsigned TAG_W = CVA6Cfg.DCACHE_TAG_WIDTH;
  localparam int unsigned OFF_W = CVA6Cfg.DCACHE_OFFSET_WIDTH;
  localparam int unsigned WAYS = CVA6Cfg.DCACHE_SET_ASSOC;
  localparam int unsigned XLEN = CVA6Cfg.XLEN;
  localparam int unsigned LINE_BYTES = CVA6Cfg.DCACHE_LINE_WIDTH / 8;
  localparam logic [63:0] BASE = 64'h8000_0000;
  localparam int unsigned OP_TIMEOUT = 5000;  // cycles for any single operation

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

  // miss_handler state encodings observed for coverage
  localparam int unsigned MH_IDLE = 0;
  localparam int unsigned MH_FLUSH_REQ_STATUS = 4;
  localparam int unsigned MH_BUS_REQ = 14;
  localparam int unsigned MH_FLUSH_BUS_REQ = 15;

  typedef enum int {
    ST_I,
    ST_S,
    ST_M
  } msi_e;

  // ------------------
  // DUT
  // ------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic flush;
  logic flush_ack;
  logic miss;
  dcache_req_i_t [NumPorts-1:0] req_ports_i;
  dcache_req_o_t [NumPorts-1:0] req_ports_o;
  axi_req_t axi_data_req, axi_bypass_req;
  axi_resp_t axi_data_rsp, axi_bypass_rsp;
  cc_req_t cc_req;
  logic cc_gnt;
  logic cc_done;
  cc_snoop_t snoop;
  logic snoop_ready;
  logic snoop_ack;

  always #5 clk = ~clk;

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
      .flush_i      (flush),
      .flush_ack_o  (flush_ack),
      .miss_o       (miss),
      .amo_req_i    ('0),
      .amo_resp_o   (),
      .req_ports_i  (req_ports_i),
      .req_ports_o  (req_ports_o),
      .axi_data_o   (axi_data_req),
      .axi_data_i   (axi_data_rsp),
      .axi_bypass_o (axi_bypass_req),
      .axi_bypass_i (axi_bypass_rsp),
      .cc_req_o     (cc_req),
      .cc_gnt_i     (cc_gnt),
      .cc_done_o    (cc_done),
      .snoop_i      (snoop),
      .snoop_ready_o(snoop_ready),
      .snoop_ack_o  (snoop_ack),
      .ca_flush_i       (1'b0),
      .ca_commit_valid_i('0),
      .ca_commit_id_i   ('0),
      .ca_trap_i        (1'b0),
      .ca_status_o      ()
  );

  // ------------------
  // Memory and golden model
  // ------------------
  logic [7:0] mem[logic [63:0]];  // backing store, bytes; written when B is sent
  logic [63:0] watch_line = '1;  // +watch=<hex addr>: log every event on that line

  function automatic bit watched(input logic [63:0] a);
    return a[63:OFF_W] == watch_line[63:OFF_W];
  endfunction

  logic [31:0] hist[logic [63:0]][$];  // per 32b word: every value it ever held, in order
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

  function automatic void hist_init(input logic [63:0] wa);
    if (!hist.exists(wa)) hist[wa].push_back(mem_rd_word(wa));
  endfunction

  function automatic logic [31:0] gold(input logic [63:0] wa);
    hist_init(wa);
    return hist[wa][$];
  endfunction

  function automatic void gold_write(input logic [63:0] wa, input logic [31:0] d,
                                     input logic [3:0] be);
    logic [31:0] v;
    v = gold(wa);
    for (int b = 0; b < 4; b++) if (be[b]) v[b*8+:8] = d[b*8+:8];
    hist[wa].push_back(v);
    if (watched(wa)) $display("[%0t] WATCH gold %h <= %h", $time, wa, v);
  endfunction

  function automatic void error(input string msg);
    n_errors++;
    $display("[%0t] ERROR: %s", $time, msg);
    if (n_errors > 20) $fatal(1, "too many errors");
  endfunction

  // memory must hold the latest value of every tracked word of a line
  function automatic void check_mem_line(input logic [63:0] line, input string ctx);
    for (int w = 0; w < LINE_BYTES / 4; w++) begin
      logic [63:0] wa;
      wa = line + 4 * w;
      if (hist.exists(wa) && mem_rd_word(wa) !== hist[wa][$])
        error($sformatf("%s: memory stale at %h: mem=%h gold=%h", ctx, wa, mem_rd_word(wa),
                        hist[wa][$]));
    end
  endfunction

  // ------------------
  // AXI memory (two ports: 0 = refill/write-back, 1 = bypass)
  // ------------------
  axi_req_t axi_req[2];
  axi_resp_t axi_rsp[2];
  assign axi_req[0] = axi_data_req;
  assign axi_req[1] = axi_bypass_req;
  assign axi_data_rsp = axi_rsp[0];
  assign axi_bypass_rsp = axi_rsp[1];

  int unsigned axi_stall_pct = 30;  // probability (%) of deasserting a ready/valid
  int unsigned n_axi_writes[2];
  int unsigned n_axi_reads[2];

  for (genvar p = 0; p < 2; p++) begin : gen_axi_mem
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
      // every process has its own generator, seed this one from +seed too
      void'($urandom(seed * 7 + p + 1));
      axi_rsp[p] = '0;
      forever begin
        @(negedge clk);
        // drive
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
        // observe this cycle's handshakes
        #1;
        if (axi_req[p].aw_valid && axi_rsp[p].aw_ready) begin
          if (axi_req[p].aw.atop != '0) error("unexpected AXI atomic");
          aw_q.push_back(axi_req[p].aw);
        end
        if (axi_req[p].w_valid && axi_rsp[p].w_ready) w_q.push_back(axi_req[p].w);
        if ($test$plusargs("axidebug")) begin
          if (axi_req[p].aw_valid && axi_rsp[p].aw_ready)
            $display("[%0t] axi%0d AW addr=%h len=%0d", $time, p, axi_req[p].aw.addr, axi_req[p].aw.len);
          if (axi_req[p].w_valid && axi_rsp[p].w_ready)
            $display("[%0t] axi%0d W data=%h last=%b", $time, p, axi_req[p].w.data, axi_req[p].w.last);
        end
        if (axi_req[p].ar_valid && axi_rsp[p].ar_ready) begin
          automatic rd_t r;
          if (axi_req[p].ar.burst != axi_pkg::BURST_INCR && axi_req[p].ar.len != 0)
            error("only INCR read bursts are modelled");
          r.ar = axi_req[p].ar;
          r.beat = 0;
          if (watched(r.ar.addr)) $display("[%0t] WATCH axi%0d read %h", $time, p, r.ar.addr);
          r_q.push_back(r);
          n_axi_reads[p]++;
        end
        if (axi_rsp[p].r_valid && axi_req[p].r_ready) begin
          if (r_q[0].beat == r_q[0].ar.len) void'(r_q.pop_front());
          else r_q[0].beat++;
        end
        // the write takes effect when its response is sent
        if (axi_rsp[p].b_valid && axi_req[p].b_ready) begin
          automatic wr_t wr = b_q.pop_front();
          for (int i = 0; i < wr.w.size(); i++) begin
            automatic logic [63:0] a;
            a = (wr.aw.addr & ~64'(CVA6Cfg.AxiDataWidth / 8 - 1)) + i * (CVA6Cfg.AxiDataWidth / 8);
            for (int b = 0; b < CVA6Cfg.AxiDataWidth / 8; b++)
            if (wr.w[i].strb[b]) mem[a+b] = wr.w[i].data[b*8+:8];
          end
          n_axi_writes[p]++;
          if (watched(wr.aw.addr))
            $display("[%0t] WATCH axi%0d write applied %h: %h %h", $time, p, wr.aw.addr,
                     wr.w[0].data, wr.w.size() > 1 ? wr.w[1].data : '0);
        end
        // a write is complete once its address and last data beat arrived
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
  // Coherence bus stub
  // ------------------
  // The cache is granted unless the remote agent holds the bus or grants are
  // held back on purpose. Tenure bookkeeping checks the cache's side of the
  // protocol.
  logic grant_en = 1'b1;
  logic remote_holds = 1'b0;
  logic snoop_outstanding = 1'b0;
  logic cache_tenure = 1'b0;
  int unsigned n_gets, n_getm, n_putm;

  assign cc_gnt = cc_req.valid && grant_en && !remote_holds;

  initial begin
    forever begin
      @(negedge clk);
      #1;
      if (!rst_n) continue;
      if (cc_done && !cache_tenure) error("cc_done outside of a tenure");
      if (cc_req.valid && cache_tenure) error("cc_req during own tenure");
      if (cc_gnt && cc_done) error("cc_gnt and cc_done in the same cycle");
      if (cache_tenure && snoop.valid && snoop_ready) error("snoop accepted during own tenure");
      if (snoop_ack && !snoop_outstanding) error("snoop_ack without a snoop");
      if (cc_gnt) begin
        cache_tenure = 1'b1;
        case (cc_req.req_type)
          CC_GETS: n_gets++;
          CC_GETM: n_getm++;
          default: n_putm++;
        endcase
        if (cc_req.addr[OFF_W-1:0] != '0) error("cc_req address not line aligned");
      end
      if (cc_done) cache_tenure = 1'b0;
    end
  end

  // per-cycle trace with +debug
  initial begin
    if ($test$plusargs("debug")) begin
      forever begin
        @(negedge clk);
        #1;
        $display("[%0t] mh=%0d ld=%0d st=%0d cc_req=%b/%0d gnt=%b done=%b snp=%b rdy=%b ack=%b ar=%b/%b r=%b/%b aw=%b w=%b b=%b/%b",
                 $time, dut.i_miss_handler.state_q,
                 dut.master_ports[LdPort].i_cache_ctrl.state_q,
                 dut.master_ports[StPort].i_cache_ctrl.state_q, cc_req.valid, cc_req.req_type,
                 cc_gnt, cc_done, snoop.valid, snoop_ready, snoop_ack, axi_data_req.ar_valid,
                 axi_data_rsp.ar_ready, axi_data_rsp.r_valid, axi_data_req.r_ready,
                 axi_data_req.aw_valid, axi_data_req.w_valid, axi_data_rsp.b_valid,
                 axi_data_req.b_ready);
      end
    end
  end

  // ------------------
  // Line state peek
  // ------------------
  logic [CVA6Cfg.DCACHE_INDEX_WIDTH-CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] peek_set;
  logic [TAG_W-1:0] peek_tag[WAYS];
  logic [63:0] peek_vd;
  for (genvar w = 0; w < WAYS; w++) begin : gen_peek
    assign peek_tag[w] =
        dut.sram_block[w].tag_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[peek_set][TAG_W-1:0];
  end
  assign peek_vd = dut.valid_dirty_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[peek_set];

  task automatic get_state(input logic [63:0] addr, output msi_e st, output logic dirty);
    int hits;
    hits = 0;
    st = ST_I;
    dirty = 1'b0;
    peek_set = addr[IDX_W-1:OFF_W];
    #1;
    for (int w = 0; w < WAYS; w++) begin
      logic v, d, o;
      d = peek_vd[8*w];
      v = peek_vd[8*w+1];
      o = peek_vd[8*w+2];
      if (v && peek_tag[w] == addr[IDX_W+TAG_W-1:IDX_W]) begin
        hits++;
        st = o ? ST_M : ST_S;
        dirty = d;
        if (d && !o) error($sformatf("line %h dirty but not owned", addr));
      end
    end
    if (hits > 1) error($sformatf("line %h present in %0d ways", addr, hits));
  endtask

  task automatic expect_state(input logic [63:0] addr, input msi_e exp, input string ctx);
    msi_e st;
    logic d;
    int unsigned t;
    t = 0;
    // a load returns its critical word before the line is written, wait for
    // the miss handler to finish
    while (int'(dut.i_miss_handler.state_q) != MH_IDLE || cache_tenure) begin
      @(negedge clk);
      #1;
      wait_timeout(t, "miss handler idle");
    end
    get_state(addr, st, d);
    if (st != exp) error($sformatf("%s: line %h is %s, expected %s", ctx, addr, st.name(), exp.name()));
  endtask

  // ------------------
  // Port drivers
  // ------------------
  task automatic wait_timeout(inout int unsigned t, input string what);
    t++;
    if (t > OP_TIMEOUT) $fatal(1, "[%0t] liveness: %s did not complete in %0d cycles", $time, what, OP_TIMEOUT);
  endtask

  task automatic do_load(input logic [63:0] addr, input logic check = 1'b1,
                         output logic [31:0] data);
    int unsigned t;
    int unsigned ver_lo;
    logic [63:0] wa;
    t = 0;
    wa = {addr[63:2], 2'b00};
    @(negedge clk);
    req_ports_i[LdPort] = '0;
    req_ports_i[LdPort].data_req = 1'b1;
    req_ports_i[LdPort].address_index = addr[IDX_W-1:0];
    req_ports_i[LdPort].data_be = '1;
    req_ports_i[LdPort].data_size = 2'b10;
    #1;
    while (!req_ports_o[LdPort].data_gnt) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("load gnt %h", addr));
    end
    hist_init(wa);
    ver_lo = hist[wa].size() - 1;
    @(negedge clk);
    req_ports_i[LdPort].data_req = 1'b0;
    req_ports_i[LdPort].tag_valid = 1'b1;
    req_ports_i[LdPort].address_tag = addr[IDX_W+TAG_W-1:IDX_W];
    #1;
    while (!req_ports_o[LdPort].data_rvalid) begin
      @(negedge clk);
      req_ports_i[LdPort].tag_valid = 1'b0;
      #1;
      wait_timeout(t, $sformatf("load rvalid %h", addr));
    end
    data = req_ports_o[LdPort].data_rdata;
    if (watched(addr)) $display("[%0t] WATCH load %h -> %h (gnt ver %0d)", $time, addr, data, ver_lo);
    if (check) begin
      logic ok;
      ok = 1'b0;
      for (int i = ver_lo; i < hist[wa].size(); i++) if (hist[wa][i] === data) ok = 1'b1;
      if (!ok)
        error($sformatf("load %h returned %h, expected %h (or a later value)", addr, data,
                        hist[wa][ver_lo]));
    end
    @(negedge clk);
    req_ports_i[LdPort].tag_valid = 1'b0;
  endtask

  task automatic do_store(input logic [63:0] addr, input logic [31:0] data);
    int unsigned t;
    t = 0;
    @(negedge clk);
    req_ports_i[StPort] = '0;
    req_ports_i[StPort].data_req = 1'b1;
    req_ports_i[StPort].data_we = 1'b1;
    req_ports_i[StPort].address_index = addr[IDX_W-1:0];
    req_ports_i[StPort].address_tag = addr[IDX_W+TAG_W-1:IDX_W];
    req_ports_i[StPort].data_wdata = data;
    req_ports_i[StPort].data_be = '1;
    req_ports_i[StPort].data_size = 2'b10;
    #1;
    while (!req_ports_o[StPort].data_gnt) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("store gnt %h", addr));
    end
    // the store is performed in the granted cycle
    gold_write({addr[63:2], 2'b00}, data, 4'hf);
    @(negedge clk);
    req_ports_i[StPort] = '0;
  endtask

  int unsigned n_snoop_in_bus_req, n_snoop_in_flush;

  task automatic do_snoop(input cc_req_type_e kind, input logic [63:0] addr);
    int unsigned t;
    t = 0;
    @(negedge clk);
    snoop.valid = 1'b1;
    snoop.req_type = kind;
    snoop.addr = {addr[55:OFF_W], {OFF_W{1'b0}}};
    #1;
    while (!snoop_ready) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("snoop accept %h", addr));
    end
    if (watched(addr))
      $display("[%0t] WATCH snoop %s accepted in mh state %0d", $time, kind.name(),
               dut.i_miss_handler.state_q);
    if (int'(dut.i_miss_handler.state_q) == MH_BUS_REQ) n_snoop_in_bus_req++;
    if (int'(dut.i_miss_handler.state_q) inside {MH_FLUSH_BUS_REQ, MH_FLUSH_REQ_STATUS})
      n_snoop_in_flush++;
    snoop_outstanding = 1'b1;
    @(negedge clk);
    snoop.valid = 1'b0;
    #1;
    while (!snoop_ack) begin
      @(negedge clk);
      #1;
      wait_timeout(t, $sformatf("snoop ack %h", addr));
    end
    snoop_outstanding = 1'b0;
    if (watched(addr)) $display("[%0t] WATCH snoop %s acked", $time, kind.name());
  endtask

  // The remote agent takes the bus only outside the cache's tenure, like the
  // real bus will.
  task automatic remote_acquire();
    int unsigned t;
    t = 0;
    forever begin
      @(negedge clk);
      #2;
      if (!cache_tenure && !cc_gnt) break;
      wait_timeout(t, "remote bus acquire");
    end
    remote_holds = 1'b1;
  endtask

  task automatic remote_release();
    @(negedge clk);
    remote_holds = 1'b0;
  endtask

  // remote core reads a line: GetS, memory must then be up to date
  task automatic remote_read(input logic [63:0] addr);
    remote_acquire();
    do_snoop(CC_GETS, addr);
    check_mem_line({addr[63:OFF_W], {OFF_W{1'b0}}}, "after GetS");
    remote_release();
  endtask

  // remote core writes a word: GetM, then the value lands in memory (as if it
  // wrote the line and evicted it before releasing the bus)
  task automatic remote_write(input logic [63:0] addr, input logic [31:0] data);
    logic [63:0] wa;
    wa = {addr[63:2], 2'b00};
    remote_acquire();
    do_snoop(CC_GETM, addr);
    check_mem_line({addr[63:OFF_W], {OFF_W{1'b0}}}, "after GetM");
    for (int b = 0; b < 4; b++) mem[wa+b] = data[b*8+:8];
    gold_write(wa, data, 4'hf);
    remote_release();
  endtask

  task automatic do_flush();
    int unsigned t;
    t = 0;
    @(negedge clk);
    flush = 1'b1;
    #1;
    while (!flush_ack) begin
      @(negedge clk);
      #1;
      wait_timeout(t, "flush");
    end
    @(negedge clk);
    flush = 1'b0;
  endtask

  // ------------------
  // Address helpers
  // ------------------
  // line `tag` of cache set `set`, word `word`
  function automatic logic [63:0] la(input int unsigned set, input int unsigned tag,
                                     input int unsigned word = 0);
    return BASE + (64'(tag) << IDX_W) + (64'(set) << OFF_W) + 64'(4 * word);
  endfunction

  // ------------------
  // Tests
  // ------------------
  task automatic test_basic_transitions();
    logic [31:0] d;
    logic [63:0] x, y;
    int unsigned wr0;
    $display("[%0t] T1: basic transitions", $time);
    x = la(1, 1);
    y = la(1, 2);

    // I -> S on a load miss
    do_load(x, 1'b1, d);
    expect_state(x, ST_S, "load miss");

    // S -> M on a store (upgrade through GetM)
    wr0 = n_getm;
    do_store(x, 32'h1111_0001);
    expect_state(x, ST_M, "store upgrade");
    if (n_getm != wr0 + 1) error("store to an S line did not obtain ownership with GetM");

    // stores and loads on an M line need no bus
    wr0 = n_gets + n_getm;
    do_store(x, 32'h1111_0011);
    do_load(x, 1'b1, d);
    if (n_gets + n_getm != wr0) error("hit on an M line used the bus");

    // M --GetS--> S with the dirty data written back before the ack
    wr0 = n_axi_writes[0];
    remote_read(x);
    expect_state(x, ST_S, "GetS on M");
    if (n_axi_writes[0] != wr0 + 1) error("GetS on dirty M did not write back exactly once");

    // S --GetM--> I without a write-back, then the remote value must be read
    wr0 = n_axi_writes[0];
    remote_write(x, 32'hbeef_0002);
    expect_state(x, ST_I, "GetM on S");
    if (n_axi_writes[0] != wr0) error("GetM on clean S wrote back");
    do_load(x, 1'b1, d);
    if (d != 32'hbeef_0002) error($sformatf("stale read after invalidation: %h", d));

    // I -> M on a store miss, M --GetM--> I with write-back
    do_store(y, 32'h2222_0003);
    expect_state(y, ST_M, "store miss");
    wr0 = n_axi_writes[0];
    remote_write(la(1, 2, 1), 32'hcafe_0004);
    expect_state(y, ST_I, "GetM on M");
    if (n_axi_writes[0] != wr0 + 1) error("GetM on dirty M did not write back exactly once");
    do_load(y, 1'b1, d);
    do_load(la(1, 2, 1), 1'b1, d);

    // snoops on an absent line change nothing
    wr0 = n_axi_writes[0];
    remote_read(la(2, 7));
    remote_write(la(2, 7), 32'h0bad_0005);
    expect_state(la(2, 7), ST_I, "snoop on I");
    if (n_axi_writes[0] != wr0) error("snoop on I wrote back");
  endtask

  // snoop while our miss to the same line waits for the bus
  task automatic test_snoop_vs_pending_miss();
    logic [31:0] d;
    logic [63:0] x, z;
    $display("[%0t] T2: snoop during an outstanding miss", $time);
    x = la(3, 1);
    z = la(3, 2);

    // load miss held at the bus, remote writes the same line meanwhile
    grant_en = 1'b0;
    fork
      do_load(x, 1'b1, d);
      begin
        repeat (5) @(negedge clk);
        remote_write(x, 32'h3333_0001);
        remote_write(z, 32'h3333_0002);  // same set, other line
        grant_en = 1'b1;
      end
    join
    if (d != 32'h3333_0001) error($sformatf("pending load returned %h, not the remote value", d));
    expect_state(x, ST_S, "pending load");

    // store upgrade (S -> M) held at the bus while the remote invalidates the S copy
    grant_en = 1'b0;
    fork
      do_store(x, 32'h4444_0003);
      begin
        repeat (5) @(negedge clk);
        remote_write(la(3, 1, 2), 32'h4444_0004);  // other word of the same line
        grant_en = 1'b1;
      end
    join
    expect_state(x, ST_M, "upgrade after invalidation");
    do_load(x, 1'b1, d);
    do_load(la(3, 1, 2), 1'b1, d);
    if (d != 32'h4444_0004) error($sformatf("remote word lost by upgrade: %h", d));
    remote_read(x);
  endtask

  // eviction of dirty lines writes them back; snoops wait for the tenure
  task automatic test_victim_writeback();
    logic [31:0] d;
    $display("[%0t] T3: victim write-back", $time);
    for (int t = 0; t < WAYS + 4; t++) do_store(la(5, 10 + t), 32'h5500_0000 + t);
    // the first lines were evicted, memory has their data
    for (int t = 0; t < WAYS + 4; t++) do_load(la(5, 10 + t), 1'b1, d);
    for (int t = 0; t < WAYS + 4; t++) remote_read(la(5, 10 + t));

    // a snoop raised during an eviction tenure is only taken after it
    for (int t = 0; t < WAYS; t++) do_store(la(6, 30 + t), 32'h6600_0000 + t);
    fork
      do_store(la(6, 30 + WAYS), 32'h6600_00ff);  // evicts a dirty line
      begin
        int unsigned t;
        t = 0;
        // wait for the eviction tenure, then hold a snoop against it
        while (!cache_tenure) begin
          @(negedge clk);
          #2;
          wait_timeout(t, "eviction tenure");
        end
        @(negedge clk);
        snoop.valid = 1'b1;
        snoop.req_type = CC_GETS;
        snoop.addr = la(6, 30);
        while (cache_tenure) begin
          #1;
          if (snoop_ready) error("snoop accepted inside an eviction tenure");
          @(negedge clk);
        end
        snoop.valid = 1'b0;
      end
    join
    for (int t = 0; t <= WAYS; t++) remote_read(la(6, 30 + t));
  endtask

  // flush writes everything back under per-line tenures, snoops interleave
  task automatic test_flush();
    logic [31:0] d;
    $display("[%0t] T4: flush with snoops", $time);
    for (int s = 8; s < 12; s++)
    for (int t = 0; t < 4; t++) do_store(la(s, 40 + t), 32'h7700_0000 + 16 * s + t);
    grant_en = 1'b0;
    fork
      do_flush();
      begin
        repeat (20) @(negedge clk);
        remote_write(la(8, 40), 32'h7777_0001);
        remote_read(la(9, 41));
        grant_en = 1'b1;
        repeat (30) @(negedge clk);
        remote_write(la(11, 43), 32'h7777_0002);
      end
    join
    for (int s = 8; s < 12; s++) begin
      for (int t = 0; t < 4; t++) begin
        expect_state(la(s, 40 + t), ST_I, "after flush");
        check_mem_line(la(s, 40 + t), "after flush");
      end
    end

    // remote reads race the flush write-backs: each must see memory updated
    // as soon as the flushing tenure for that line ends
    for (int round = 0; round < 4; round++) begin
      bit flushing;
      for (int s = 8; s < 12; s++)
      for (int t = 0; t < 4; t++) do_store(la(s, 40 + t), $urandom);
      flushing = 1;
      fork
        begin
          do_flush();
          flushing = 0;
        end
        while (flushing) remote_read(la(8 + $urandom_range(3), 40 + $urandom_range(3)));
      join
    end
  endtask

  // random mix of loads, stores, remote reads/writes, bus stalls
  task automatic test_random(input int unsigned n_ops);
    localparam int unsigned NSETS = 3;
    localparam int unsigned NTAGS = 12;  // > WAYS, forces evictions
    bit done_ld, done_st;
    $display("[%0t] T5: random (%0d ops per agent)", $time, n_ops);
    done_ld = 0;
    done_st = 0;
    fork
      begin
        logic [31:0] d;
        for (int i = 0; i < n_ops; i++)
        do_load(la(20 + $urandom_range(NSETS - 1), $urandom_range(NTAGS - 1), $urandom_range(3)),
                1'b1, d);
        done_ld = 1;
      end
      begin
        for (int i = 0; i < n_ops; i++)
        do_store(la(20 + $urandom_range(NSETS - 1), $urandom_range(NTAGS - 1), $urandom_range(3)),
                 $urandom);
        done_st = 1;
      end
      begin
        while (!(done_ld && done_st)) begin
          logic [63:0] a;
          repeat ($urandom_range(30)) @(negedge clk);
          a = la(20 + $urandom_range(NSETS - 1), $urandom_range(NTAGS - 1), $urandom_range(3));
          if ($urandom_range(1)) remote_write(a, $urandom);
          else remote_read(a);
        end
      end
      begin
        while (!(done_ld && done_st)) begin
          @(negedge clk);
          grant_en = ($urandom_range(99) < 60);
        end
        grant_en = 1'b1;
      end
      begin
        // occasional flushes concurrent with everything else
        while (!(done_ld && done_st)) begin
          repeat ($urandom_range(300, 1500)) @(negedge clk);
          if (!(done_ld && done_st)) do_flush();
        end
      end
    join
    do_flush();
    foreach (hist[wa]) if (mem_rd_word(wa) !== hist[wa][$])
      error($sformatf("final memory mismatch at %h: mem=%h gold=%h", wa, mem_rd_word(wa),
                      hist[wa][$]));
  endtask

  // ------------------
  // Main
  // ------------------
  initial begin
    int unsigned seed;
    int unsigned n_random;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("nrandom=%d", n_random)) n_random = 2000;
    void'($value$plusargs("watch=%h", watch_line));
    void'($urandom(seed));
    $display("std_nbdcache MSI testbench, seed=%0d", seed);

    flush = 1'b0;
    req_ports_i = '0;
    snoop = '0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    // wait for the status array initialisation
    while (int'(dut.i_miss_handler.state_q) != MH_IDLE) @(negedge clk);

    test_basic_transitions();
    test_snoop_vs_pending_miss();
    test_victim_writeback();
    test_flush();
    test_random(n_random);

    $display("coverage: tenures GetS=%0d GetM=%0d PutM=%0d, snoops in BUS_REQ=%0d, in flush=%0d",
             n_gets, n_getm, n_putm, n_snoop_in_bus_req, n_snoop_in_flush);
    $display("coverage: AXI line writes=%0d reads=%0d, bypass writes=%0d reads=%0d",
             n_axi_writes[0], n_axi_reads[0], n_axi_writes[1], n_axi_reads[1]);
    if (n_errors != 0) $fatal(1, "FAILED with %0d errors", n_errors);
    $display("PASSED");
    $finish;
  end

endmodule
