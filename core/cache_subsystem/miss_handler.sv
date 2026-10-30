// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 12.11.2017
// Description: Handles cache misses.

// --------------
// MISS Handler
// --------------

module miss_handler
  import ariane_pkg::*;
  import std_cache_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg      = config_pkg::cva6_cfg_empty,
    parameter int unsigned           NR_PORTS     = 4,
    parameter type                   axi_req_t    = logic,
    parameter type                   axi_rsp_t    = logic,
    parameter type                   cache_line_t = logic,
    parameter type                   cl_be_t      = logic,
    // cycles an LR keeps its tenure waiting for the matching SC
    parameter int unsigned           LrHoldCycles = 64
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,  // flush request
    output logic flush_ack_o,  // acknowledge successful flush
    output logic miss_o,
    input logic busy_i,  // dcache is busy with something
    // Bypass or miss
    input logic [NR_PORTS-1:0][$bits(miss_req_t)-1:0] miss_req_i,
    // Bypass handling
    output logic [NR_PORTS-1:0] bypass_gnt_o,
    output logic [NR_PORTS-1:0] bypass_valid_o,
    output logic [NR_PORTS-1:0][63:0] bypass_data_o,

    // AXI port
    output axi_req_t axi_bypass_o,
    input  axi_rsp_t axi_bypass_i,

    // Miss handling (~> cacheline refill)
    output logic [NR_PORTS-1:0] miss_gnt_o,
    output logic [NR_PORTS-1:0] active_serving_o,

    output logic     [63:0] critical_word_o,
    output logic            critical_word_valid_o,
    output axi_req_t        axi_data_o,
    input  axi_rsp_t        axi_data_i,

    input logic [NR_PORTS-1:0][55:0] mshr_addr_i,
    output logic [NR_PORTS-1:0] mshr_addr_matches_o,
    output logic [NR_PORTS-1:0] mshr_index_matches_o,
    // AMO
    input amo_req_t amo_req_i,
    output amo_resp_t amo_resp_o,
    // Port to SRAMs, for refill and eviction
    output logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] req_o,
    output logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] addr_o,  // address into cache array
    output cache_line_t data_o,
    output cl_be_t be_o,
    input cache_line_t [CVA6Cfg.DCACHE_SET_ASSOC-1:0] data_i,
    output logic we_o,
    // Coherence bus: request a tenure before touching memory for a cacheable line
    output cc_req_t cc_req_o,
    input logic cc_gnt_i,  // single-cycle, only while cc_req_o.valid
    output logic cc_done_o,  // single-cycle, ends the tenure
    // Snoops from the coherence bus
    input cc_snoop_t snoop_i,  // held until snoop_ready_o
    output logic snoop_ready_o,
    output logic snoop_ack_o,  // single-cycle, line state updated and write-back complete
    // Conditional access: lines leaving this cache, and cwrite at commit
    output logic ca_inval_valid_o,  // local eviction/flush of a line
    output logic ca_inval_all_o,
    output logic [55:0] ca_inval_addr_o,
    output logic ca_snoop_inval_valid_o,  // another core takes a line we hold
    output logic [55:0] ca_snoop_inval_addr_o,
    output logic [55:0] ca_cwrite_addr_o,
    input logic ca_cwrite_allowed_i,
    output logic ca_cwrite_fail_o
);

  // Three MSHR ports + AMO port
  parameter NR_BYPASS_PORTS = NR_PORTS + 1;

  // convert one hot to bin for -> needed for cache replacement
  function automatic logic [CVA6Cfg.DCACHE_SET_ASSOC_WIDTH-1:0] one_hot_to_bin(
      input logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] in);
    for (int unsigned i = 0; i < CVA6Cfg.DCACHE_SET_ASSOC; i++) begin
      if (in[i]) return i;
    end
  endfunction
  // get the first bit set, returns one hot value
  function automatic logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] get_victim_cl(
      input logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] valid_dirty);
    // one-hot return vector
    logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] oh = '0;
    for (int unsigned i = 0; i < CVA6Cfg.DCACHE_SET_ASSOC; i++) begin
      if (valid_dirty[i]) begin
        oh[i] = 1'b1;
        return oh;
      end
    end
  endfunction

  // FSM states
  typedef enum logic [4:0] {
    IDLE,                // 0
    FLUSHING,            // 1
    FLUSH,               // 2
    WB_CACHELINE_FLUSH,  // 3
    FLUSH_REQ_STATUS,    // 4
    WB_CACHELINE_MISS,   // 5
    WAIT_GNT_SRAM,       // 6
    MISS,                // 7
    REQ_CACHELINE,       // 8
    MISS_REPL,           // 9
    SAVE_CACHELINE,      // A
    INIT,                // B
    AMO_REQ,             // C
    AMO_WAIT_RESP,       // D
    BUS_REQ,             // E  wait for a coherence tenure before serving the MSHR
    FLUSH_BUS_REQ,       // F  wait for a tenure before writing back a dirty line on flush
    FLUSH_WB_WAIT,       // 10 wait for the flush write-back response, then end the tenure
    SNOOP_REQ,           // 11 read the snooped set
    SNOOP_CHECK,         // 12 look up the snooped line
    SNOOP_WB,            // 13 write back a dirty owned line
    SNOOP_WB_WAIT,       // 14 wait for the snoop write-back response
    SNOOP_UPDATE,        // 15 downgrade/invalidate the line and acknowledge
    AMO_BUS_REQ,         // 16 wait for a GetM tenure for a cacheable AMO
    AMO_LOOKUP,          // 17 read the AMO set
    AMO_EXEC,            // 18 read-modify-write the M line, or fetch it first
    LR_HOLD              // 19 keep the LR tenure for the SC (forward progress)
  } state_e;
  state_e state_d, state_q;

  // Coherence
  logic bus_held_d, bus_held_q;  // we own a coherence tenure
  cc_snoop_t snoop_d, snoop_q;
  state_e snoop_ret_d, snoop_ret_q;  // where to resume after serving a snoop
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] snoop_way_d, snoop_way_q;
  logic snoop_accept;
  logic snoop_busy;

  // AMOs on cacheable addresses execute in the cache, on a line held in M
  logic amo_cacheable;
  logic amo_mshr_d, amo_mshr_q;  // the MSHR serves an AMO, not a port
  logic resv_valid_d, resv_valid_q;  // LR reservation
  logic [55:CVA6Cfg.DCACHE_OFFSET_WIDTH] resv_addr_d, resv_addr_q;
  logic [$clog2(LrHoldCycles+1)-1:0] lr_hold_d, lr_hold_q;
  logic any_miss_req;
  logic [63:0] amo_old, amo_operand_a_ext, amo_operand_b_ext, amo_new, amo_ret;
  logic [CVA6Cfg.DCACHE_LINE_WIDTH-1:0] amo_line;
  logic [$clog2(CVA6Cfg.DCACHE_LINE_WIDTH)-1:0] amo_bit_off;  // offset of the 64b word

  // Registers
  mshr_t mshr_d, mshr_q;
  logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] cnt_d, cnt_q;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] evict_way_d, evict_way_q;
  // cache line to evict
  cache_line_t evict_cl_d, evict_cl_q;

  logic serve_amo_d, serve_amo_q;
  // Request from one FSM
  logic                [                          NR_PORTS-1:0]       miss_req_valid;
  logic                [                          NR_PORTS-1:0]       miss_req_bypass;
  logic                [                          NR_PORTS-1:0][63:0] miss_req_addr;
  logic                [                          NR_PORTS-1:0][63:0] miss_req_wdata;
  logic                [                          NR_PORTS-1:0]       miss_req_we;
  logic                [                          NR_PORTS-1:0][ 7:0] miss_req_be;
  logic                [                          NR_PORTS-1:0][ 1:0] miss_req_size;

  // Bypass AMO port
  bypass_req_t                                                        amo_bypass_req;
  bypass_rsp_t                                                        amo_bypass_rsp;

  // Bypass ports <-> Arbiter
  bypass_req_t         [                   NR_BYPASS_PORTS-1:0]       bypass_ports_req;
  bypass_rsp_t         [                   NR_BYPASS_PORTS-1:0]       bypass_ports_rsp;

  // Arbiter <-> Bypass AXI adapter
  bypass_req_t                                                        bypass_adapter_req;
  bypass_rsp_t                                                        bypass_adapter_rsp;

  // Cache Line Refill <-> AXI
  logic                                                               req_fsm_miss_valid;
  logic                [                                  63:0]       req_fsm_miss_addr;
  logic                [         CVA6Cfg.DCACHE_LINE_WIDTH-1:0]       req_fsm_miss_wdata;
  logic                                                               req_fsm_miss_we;
  logic                [     (CVA6Cfg.DCACHE_LINE_WIDTH/8)-1:0]       req_fsm_miss_be;
  ariane_pkg::ad_req_t                                                req_fsm_miss_req;
  logic                [                                   1:0]       req_fsm_miss_size;

  logic                                                               gnt_miss_fsm;
  logic                                                               valid_miss_fsm;
  logic                [    (CVA6Cfg.DCACHE_LINE_WIDTH/64)-1:0][63:0] data_miss_fsm;

  // Cache Management <-> LFSR
  logic                                                               lfsr_enable;
  logic                [          CVA6Cfg.DCACHE_SET_ASSOC-1:0]       lfsr_oh;
  logic                [$clog2(CVA6Cfg.DCACHE_SET_ASSOC-1)-1:0]       lfsr_bin;
  // AMOs
  ariane_pkg::amo_t                                                   amo_op;
  logic                [                                  63:0]       amo_operand_b;

  // 32b request
  logic                [                                  31:0]       halfword;
  logic                [ $clog2(CVA6Cfg.DCACHE_LINE_WIDTH)-1:0]       cl_offset;

  // ------------------------------
  // Cache Management
  // ------------------------------
  // Snoops are only taken in states where the cache holds no tenure and no
  // half-done line operation. All of them are either idle or waiting for the
  // bus, so a snoop can always make progress while we wait (no deadlock).
  assign snoop_ready_o = !bus_held_q &&
      (state_q inside {IDLE, BUS_REQ, FLUSH_BUS_REQ, FLUSH_REQ_STATUS, AMO_BUS_REQ});
  assign snoop_accept = snoop_i.valid && snoop_ready_o;
  assign snoop_busy = snoop_accept ||
      (state_q inside {SNOOP_REQ, SNOOP_CHECK, SNOOP_WB, SNOOP_WB_WAIT, SNOOP_UPDATE});

  always_comb begin : cache_management
    automatic logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] evict_way, valid_way, present_way, snoop_hit_way;
    automatic logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] owned_way;
    automatic logic sc_ok;

    for (int unsigned i = 0; i < CVA6Cfg.DCACHE_SET_ASSOC; i++) begin
      evict_way[i] = data_i[i].valid & data_i[i].dirty;
      valid_way[i] = data_i[i].valid;
      // the MSHR line is already present, e.g. a store upgrading an S line
      present_way[i] = data_i[i].valid &&
          data_i[i].tag == mshr_q.addr[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
      owned_way[i] = data_i[i].owned;
      snoop_hit_way[i] = data_i[i].valid &&
          data_i[i].tag == snoop_q.addr[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
    end
    // ----------------------
    // Default Assignments
    // ----------------------
    // memory array
    req_o                       = '0;
    addr_o                      = '0;
    data_o                      = '0;
    be_o                        = '0;
    we_o                        = '0;
    // Cache controller
    miss_gnt_o                  = '0;
    active_serving_o            = '0;
    // LFSR replacement unit
    lfsr_enable                 = 1'b0;
    // to AXI refill
    req_fsm_miss_valid          = 1'b0;
    req_fsm_miss_addr           = '0;
    req_fsm_miss_wdata          = '0;
    req_fsm_miss_we             = 1'b0;
    req_fsm_miss_be             = '0;
    req_fsm_miss_req            = ariane_pkg::CACHE_LINE_REQ;
    req_fsm_miss_size           = 2'b11;
    // to AXI bypass
    amo_bypass_req.req          = 1'b0;
    amo_bypass_req.reqtype      = ariane_pkg::SINGLE_REQ;
    amo_bypass_req.amo          = ariane_pkg::AMO_NONE;
    amo_bypass_req.addr         = '0;
    amo_bypass_req.we           = 1'b0;
    amo_bypass_req.wdata        = '0;
    amo_bypass_req.be           = '0;
    amo_bypass_req.size         = 2'b11;
    amo_bypass_req.id           = 4'b1000 | 4'(NR_PORTS);  // map AMO id to the first non-MSHR id
    // core
    flush_ack_o                 = 1'b0;
    miss_o                      = 1'b0;  // to performance counter
    serve_amo_d                 = serve_amo_q;
    // --------------------------------
    // Flush and Miss operation
    // --------------------------------
    state_d                     = state_q;
    cnt_d                       = cnt_q;
    evict_way_d                 = evict_way_q;
    evict_cl_d                  = evict_cl_q;
    mshr_d                      = mshr_q;
    // communicate to the requester which unit we are currently serving
    active_serving_o[mshr_q.id] = mshr_q.valid && !amo_mshr_q;
    // AMOs
    amo_resp_o.ack              = 1'b0;
    amo_resp_o.result           = '0;
    amo_operand_b               = '0;

    halfword                    = '0;
    cl_offset                   = '0;
    // coherence
    cc_req_o                    = '0;
    cc_done_o                   = 1'b0;
    snoop_ack_o                 = 1'b0;
    bus_held_d                  = bus_held_q;
    snoop_d                     = snoop_q;
    snoop_ret_d                 = snoop_ret_q;
    snoop_way_d                 = snoop_way_q;
    amo_mshr_d                  = amo_mshr_q;
    resv_valid_d                = resv_valid_q;
    resv_addr_d                 = resv_addr_q;
    lr_hold_d                   = lr_hold_q;
    any_miss_req                = |(miss_req_valid & ~miss_req_bypass);
    sc_ok = resv_valid_q && resv_addr_q == mshr_q.addr[55:CVA6Cfg.DCACHE_OFFSET_WIDTH];
    ca_inval_valid_o            = 1'b0;
    ca_inval_all_o              = 1'b0;
    ca_inval_addr_o             = '0;
    ca_snoop_inval_valid_o      = 1'b0;
    ca_snoop_inval_addr_o       = snoop_q.addr;
    ca_cwrite_fail_o            = 1'b0;

    case (state_q)

      IDLE: begin
        // lowest priority are AMOs, wait until everything else is served before going for the AMOs
        if (amo_req_i.req && !busy_i) begin
          if (amo_req_i.amo_op == AMO_CWRITE && (!ca_cwrite_allowed_i || !amo_cacheable)) begin
            // not tagged, access revoked, or not cacheable (tags live in the
            // L1): fail without touching the bus
            amo_resp_o.ack    = 1'b1;
            amo_resp_o.result = 64'd1;
            ca_cwrite_fail_o  = 1'b1;
          end else if (amo_cacheable) begin
            // execute in the cache once the line is held in M; the MSHR holds
            // off the ports from the line meanwhile
            state_d      = AMO_BUS_REQ;
            mshr_d.valid = 1'b1;
            mshr_d.we    = 1'b1;
            mshr_d.id    = '0;
            mshr_d.addr  = amo_req_i.operand_a[55:0];
            mshr_d.wdata = '0;
            mshr_d.be    = '0;
            amo_mshr_d   = 1'b1;
          end else begin
            // 1. Flush the cache
            state_d = FLUSH_REQ_STATUS;
            serve_amo_d = 1'b1;
            cnt_d = '0;
          end
        end
        // check if we want to flush and can flush e.g.: we are not busy anymore
        // TODO: Check that the busy flag is indeed needed
        if (flush_i && !busy_i) begin
          state_d    = FLUSH_REQ_STATUS;
          cnt_d      = '0;
          mshr_d     = mshr_q;
          amo_mshr_d = 1'b0;
        end

        // check if one of the state machines missed
        for (int unsigned i = 0; i < NR_PORTS; i++) begin
          // here comes the refill portion of code
          if (miss_req_valid[i] && !miss_req_bypass[i]) begin
            // we are taking another request so don't take the AMO
            serve_amo_d = 1'b0;
            // save to MSHR, the line is served once we own a coherence tenure
            state_d = BUS_REQ;
            amo_mshr_d = 1'b0;
            mshr_d.valid = 1'b1;
            mshr_d.we = miss_req_we[i];
            mshr_d.id = i;
            mshr_d.addr = miss_req_addr[i][CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
            mshr_d.wdata = miss_req_wdata[i];
            mshr_d.be = miss_req_be[i];
            break;
          end
        end

        // snoops take priority over anything started from here; whatever was
        // picked above is picked again once the snoop is served
        if (snoop_accept) begin
          state_d     = SNOOP_REQ;
          snoop_ret_d = IDLE;
          serve_amo_d = serve_amo_q;
          cnt_d       = cnt_q;
          mshr_d      = mshr_q;
          amo_mshr_d  = amo_mshr_q;
        end
      end

      // ~> wait for the coherence tenure of the MSHR line
      BUS_REQ: begin
        cc_req_o.valid = 1'b1;
        cc_req_o.req_type = mshr_q.we ? CC_GETM : CC_GETS;
        cc_req_o.addr = {
          mshr_q.addr[55:CVA6Cfg.DCACHE_OFFSET_WIDTH], {{CVA6Cfg.DCACHE_OFFSET_WIDTH} {1'b0}}
        };
        if (cc_gnt_i) begin
          bus_held_d = 1'b1;
          state_d    = MISS;
        end else if (snoop_accept) begin
          // the line state is read again in MISS, after the snoop
          state_d     = SNOOP_REQ;
          snoop_ret_d = BUS_REQ;
        end
      end

      //  ~> we missed on the cache
      MISS: begin
        // 1. Check if there is an empty cache-line
        // 2. If not -> evict one
        req_o   = '1;
        addr_o  = mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
        state_d = MISS_REPL;
        miss_o  = 1'b1;
      end

      // ~> second miss cycle
      MISS_REPL: begin
        // the line is already here (S, upgrading to M): refill it in place so
        // the set never holds the same tag twice
        if (|present_way) begin
          evict_way_d = present_way;
          if (data_i[one_hot_to_bin(present_way)].dirty) begin
            state_d = WB_CACHELINE_MISS;
            evict_cl_d.tag = data_i[one_hot_to_bin(present_way)].tag;
            evict_cl_d.data = data_i[one_hot_to_bin(present_way)].data;
            cnt_d = mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
          end else state_d = REQ_CACHELINE;
          // if all are valid we need to evict one, pseudo random from LFSR
        end else if (&valid_way) begin
          lfsr_enable = 1'b1;
          evict_way_d = lfsr_oh;
          // losing the reserved line loses the reservation
          if ({data_i[lfsr_bin].tag, mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]} ==
              resv_addr_q)
            resv_valid_d = 1'b0;
          // an evicted tagged line revokes conditional access
          ca_inval_valid_o = 1'b1;
          ca_inval_addr_o = {
            data_i[lfsr_bin].tag,
            mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH],
            {{CVA6Cfg.DCACHE_OFFSET_WIDTH} {1'b0}}
          };
          // do we need to write back the cache line?
          if (data_i[lfsr_bin].dirty) begin
            state_d = WB_CACHELINE_MISS;
            evict_cl_d.tag = data_i[lfsr_bin].tag;
            evict_cl_d.data = data_i[lfsr_bin].data;
            cnt_d = mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
            // no - we can request a cache line now
          end else state_d = REQ_CACHELINE;
          // we have at least one free way
        end else begin
          // get victim cache-line by looking for the first non-valid bit
          evict_way_d = get_victim_cl(~valid_way);
          state_d = REQ_CACHELINE;
        end
      end

      // ~> we can just load the cache-line, the way is store in evict_way_q
      REQ_CACHELINE: begin
        req_fsm_miss_valid = 1'b1;
        req_fsm_miss_addr  = mshr_q.addr;

        if (gnt_miss_fsm) begin
          state_d = SAVE_CACHELINE;
          miss_gnt_o[mshr_q.id] = !amo_mshr_q;
        end
      end

      // ~> replace the cacheline
      SAVE_CACHELINE: begin
        // calculate cacheline offset
        cl_offset = mshr_q.addr[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3] << 6;
        // we've got a valid response from refill unit
        if (valid_miss_fsm) begin

          addr_o = mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
          req_o = evict_way_q;
          we_o = 1'b1;
          be_o = '1;
          be_o.vldrty = evict_way_q;
          data_o.tag   = mshr_q.addr[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
          data_o.data = data_miss_fsm;
          data_o.valid = 1'b1;
          data_o.dirty = 1'b0;
          // a GetM fill is M, a GetS fill is S
          data_o.owned = mshr_q.we;

          // is this a write?
          if (mshr_q.we) begin
            // Yes, so safe the updated data now
            for (int i = 0; i < 8; i++) begin
              // check if we really want to write the corresponding byte
              if (mshr_q.be[i]) data_o.data[(cl_offset+i*8)+:8] = mshr_q.wdata[i];
            end
            // its immediately dirty if we write (an AMO fetch writes nothing yet)
            data_o.dirty = |mshr_q.be;
          end
          if (amo_mshr_q) begin
            // the AMO line is now M, execute under the same tenure
            state_d = AMO_LOOKUP;
          end else begin
            // reset MSHR
            mshr_d.valid = 1'b0;
            // the read completed after any victim write-back, end the tenure
            cc_done_o = 1'b1;
            bus_held_d = 1'b0;
            // go back to idle
            state_d = IDLE;
          end
        end
      end

      // ------------------------------
      // Write Back Operation
      // ------------------------------
      // ~> evict a cache line from way saved in evict_way_q
      WB_CACHELINE_FLUSH, WB_CACHELINE_MISS: begin

        req_fsm_miss_valid = 1'b1;
        req_fsm_miss_addr = {
          evict_cl_q.tag,
          cnt_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH],
          {{CVA6Cfg.DCACHE_OFFSET_WIDTH} {1'b0}}
        };
        req_fsm_miss_be = '1;
        req_fsm_miss_we = 1'b1;
        req_fsm_miss_wdata = evict_cl_q.data;

        // we've got a grant --> this is timing critical, think about it
        if (gnt_miss_fsm) begin
          // write status array
          addr_o       = cnt_q;
          req_o        = 1'b1;
          we_o         = 1'b1;
          data_o.valid = INVALIDATE_ON_FLUSH ? 1'b0 : 1'b1;
          if (INVALIDATE_ON_FLUSH && state_q == WB_CACHELINE_FLUSH) begin
            ca_inval_valid_o = 1'b1;
            ca_inval_all_o   = 1'b1;
          end
          // invalidate
          be_o.vldrty  = evict_way_q;
          // go back to handling the miss or flushing, depending on where we came from
          state_d      = (state_q == WB_CACHELINE_MISS) ? MISS : FLUSH_WB_WAIT;
        end
      end

      // ~> the flushed line must be in memory before anybody else may read it
      FLUSH_WB_WAIT: begin
        if (valid_miss_fsm) begin
          cc_done_o  = 1'b1;
          bus_held_d = 1'b0;
          state_d    = FLUSH_REQ_STATUS;
        end
      end

      // ~> wait for a tenure, then look at the set again as a snoop may have
      //    cleaned the line meanwhile
      FLUSH_BUS_REQ: begin
        cc_req_o.valid = 1'b1;
        cc_req_o.req_type = CC_PUTM;
        cc_req_o.addr = {
          evict_cl_q.tag,
          cnt_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH],
          {{CVA6Cfg.DCACHE_OFFSET_WIDTH} {1'b0}}
        };
        if (cc_gnt_i) begin
          bus_held_d = 1'b1;
          state_d    = FLUSH_REQ_STATUS;
        end else if (snoop_accept) begin
          state_d     = SNOOP_REQ;
          snoop_ret_d = FLUSH_REQ_STATUS;
        end
      end

      // ------------------------------
      // Flushing & Initialization
      // ------------------------------
      // ~> make another request to check the same cache-line if there are still some valid entries
      FLUSH_REQ_STATUS: begin
        req_o   = '1;
        addr_o  = cnt_q;
        // the set is about to be written back and invalidated
        if (cnt_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] ==
            resv_addr_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH])
          resv_valid_d = 1'b0;
        state_d = FLUSHING;
        if (snoop_accept) begin
          req_o       = '0;
          state_d     = SNOOP_REQ;
          snoop_ret_d = FLUSH_REQ_STATUS;
        end
      end

      FLUSHING: begin
        // this has priority
        // at least one of the cache lines is dirty
        if (|evict_way) begin
          // evict cache line, look for the first cache-line which is dirty
          evict_way_d = get_victim_cl(evict_way);
          evict_cl_d  = data_i[one_hot_to_bin(evict_way)];
          state_d     = bus_held_q ? WB_CACHELINE_FLUSH : FLUSH_BUS_REQ;
          // not dirty ~> increment and continue
        end else begin
          // a snoop cleaned the line while we waited for the tenure
          if (bus_held_q) begin
            cc_done_o  = 1'b1;
            bus_held_d = 1'b0;
          end
          // increment and re-request
          cnt_d       = cnt_q + (1'b1 << CVA6Cfg.DCACHE_OFFSET_WIDTH);
          state_d     = FLUSH_REQ_STATUS;
          addr_o      = cnt_q;
          req_o       = 1'b1;
          be_o.vldrty = INVALIDATE_ON_FLUSH ? '1 : '0;
          we_o        = 1'b1;
          ca_inval_valid_o = INVALIDATE_ON_FLUSH;
          ca_inval_all_o   = INVALIDATE_ON_FLUSH;
          // finished with flushing operation, go back to idle
          if (cnt_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] == CVA6Cfg.DCACHE_NUM_WORDS - 1) begin
            // only acknowledge if the flush wasn't triggered by an atomic
            flush_ack_o = ~serve_amo_q;
            // if we are flushing because of an AMO go to serve it
            if (serve_amo_q) begin
              state_d = AMO_REQ;
              serve_amo_d = 1'b0;
            end else begin
              state_d = IDLE;
            end
          end
        end
      end

      // ~> only called after reset
      INIT: begin
        // initialize status array
        addr_o      = cnt_q;
        req_o       = 1'b1;
        we_o        = 1'b1;
        // only write the dirty array
        be_o.vldrty = '1;
        cnt_d       = cnt_q + (1'b1 << CVA6Cfg.DCACHE_OFFSET_WIDTH);
        // finished initialization
        if (cnt_q[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] == CVA6Cfg.DCACHE_NUM_WORDS - 1)
          state_d = IDLE;
      end
      // ----------------------
      // AMOs
      // ----------------------
      // ~> we are here because we need to do the AMO, the cache is clean at this point
      AMO_REQ: begin
        amo_bypass_req.req     = 1'b1;
        amo_bypass_req.reqtype = ariane_pkg::SINGLE_REQ;
        amo_bypass_req.amo     = amo_req_i.amo_op;
        // address is in operand a
        amo_bypass_req.addr    = amo_req_i.operand_a;
        if (amo_req_i.amo_op != AMO_LR) begin
          amo_bypass_req.we = 1'b1;
        end
        amo_bypass_req.size = amo_req_i.size;
        // AXI implements CLR op instead of AND, negate operand
        if (amo_req_i.amo_op == AMO_AND) begin
          amo_operand_b = ~amo_req_i.operand_b;
        end else begin
          amo_operand_b = amo_req_i.operand_b;
        end
        // align data and byte-enable to correct byte lanes
        amo_bypass_req.wdata = amo_operand_b;
        if (amo_req_i.size == 2'b11) begin
          // 64b transfer
          amo_bypass_req.be = 8'b11111111;
        end else begin
          // 32b transfer
          if (amo_req_i.operand_a[2:0] == '0) begin
            // 64b aligned -> activate lower 4 byte lanes
            amo_bypass_req.be = 8'b00001111;
          end else begin
            // 64b unaligned -> activate upper 4 byte lanes
            amo_bypass_req.be = 8'b11110000;
            amo_bypass_req.wdata = amo_operand_b[31:0] << 32;
          end
        end

        // when request is accepted, wait for response
        if (amo_bypass_rsp.gnt) begin
          if (amo_bypass_rsp.valid) begin
            state_d = IDLE;
            amo_resp_o.ack = 1'b1;
            amo_resp_o.result = amo_bypass_rsp.rdata;
          end else begin
            state_d = AMO_WAIT_RESP;
          end
        end
      end
      AMO_WAIT_RESP: begin
        if (amo_bypass_rsp.valid) begin
          state_d = IDLE;
          amo_resp_o.ack = 1'b1;
          // Request is assumed to be still valid (ack not granted yet)
          if (amo_req_i.size == 2'b10) begin
            if (amo_req_i.operand_a[2:0] == '0) begin
              // 64b aligned -> activate lower 4 byte lanes
              halfword = amo_bypass_rsp.rdata[31:0];
            end else begin
              // 64b unaligned -> activate upper 4 byte lanes
              halfword = amo_bypass_rsp.rdata[63:32];
            end
            // Sign-extend 32b requests as per RISC-V spec
            amo_resp_o.result = {{32{halfword[31]}}, halfword};
          end else begin
            // 64b request
            amo_resp_o.result = amo_bypass_rsp.rdata;
          end
        end
      end

      // ----------------------
      // Snoops
      // ----------------------
      // ~> read the snooped set
      SNOOP_REQ: begin
        req_o   = '1;
        addr_o  = snoop_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
        state_d = SNOOP_CHECK;
      end

      SNOOP_CHECK: begin
        snoop_way_d = snoop_hit_way;
        evict_cl_d  = data_i[one_hot_to_bin(snoop_hit_way)];
        if (!(|snoop_hit_way)) begin
          // I: nothing to do
          snoop_ack_o = 1'b1;
          state_d     = snoop_ret_q;
        end else if (data_i[one_hot_to_bin(snoop_hit_way)].dirty) begin
          state_d = SNOOP_WB;
        end else begin
          state_d = SNOOP_UPDATE;
        end
      end

      // ~> M and dirty: memory must be up to date before the requester reads it
      SNOOP_WB: begin
        req_fsm_miss_valid = 1'b1;
        req_fsm_miss_addr  = snoop_q.addr;
        req_fsm_miss_be    = '1;
        req_fsm_miss_we    = 1'b1;
        req_fsm_miss_wdata = evict_cl_q.data;
        if (gnt_miss_fsm) state_d = SNOOP_WB_WAIT;
      end

      SNOOP_WB_WAIT: begin
        if (valid_miss_fsm) state_d = SNOOP_UPDATE;
      end

      // ~> GetS: M/S -> S, GetM: M/S -> I
      SNOOP_UPDATE: begin
        addr_o       = snoop_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
        req_o        = snoop_way_q;
        we_o         = 1'b1;
        be_o.vldrty  = snoop_way_q;
        data_o.valid = (snoop_q.req_type == CC_GETS);
        snoop_ack_o  = 1'b1;
        // another core writes a line we hold: a tagged one revokes access
        ca_snoop_inval_valid_o = (snoop_q.req_type == CC_GETM);
        state_d      = snoop_ret_q;
        // another core writes the reserved line
        if (snoop_q.req_type == CC_GETM && snoop_q.addr[55:CVA6Cfg.DCACHE_OFFSET_WIDTH] == resv_addr_q)
          resv_valid_d = 1'b0;
      end

      // ----------------------
      // AMOs in the cache
      // ----------------------
      AMO_BUS_REQ: begin
        cc_req_o.valid = 1'b1;
        cc_req_o.req_type = CC_GETM;
        cc_req_o.addr = {
          mshr_q.addr[55:CVA6Cfg.DCACHE_OFFSET_WIDTH], {{CVA6Cfg.DCACHE_OFFSET_WIDTH} {1'b0}}
        };
        if (cc_gnt_i) begin
          bus_held_d = 1'b1;
          state_d    = AMO_LOOKUP;
        end else if (snoop_accept) begin
          state_d     = SNOOP_REQ;
          snoop_ret_d = AMO_BUS_REQ;
        end
      end

      AMO_LOOKUP: begin
        req_o   = '1;
        addr_o  = mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
        state_d = AMO_EXEC;
      end

      // ~> no snoop can come in while we hold the tenure, so the look-up and
      //    the write below are atomic
      AMO_EXEC: begin
        if (amo_req_i.amo_op == AMO_CWRITE && !ca_cwrite_allowed_i) begin
          // revoked while we waited for the tenure: fail without writing
          amo_resp_o.ack    = 1'b1;
          amo_resp_o.result = 64'd1;
          ca_cwrite_fail_o  = 1'b1;
          mshr_d.valid      = 1'b0;
          amo_mshr_d        = 1'b0;
          cc_done_o         = 1'b1;
          bus_held_d        = 1'b0;
          state_d           = IDLE;
        end else if (amo_req_i.amo_op == AMO_SC && !sc_ok) begin
          // reservation lost (or never taken): fail without writing
          amo_resp_o.ack    = 1'b1;
          amo_resp_o.result = 64'd1;
          resv_valid_d      = 1'b0;
          mshr_d.valid      = 1'b0;
          amo_mshr_d        = 1'b0;
          cc_done_o         = 1'b1;
          bus_held_d        = 1'b0;
          state_d           = IDLE;
        end else if (|(present_way & owned_way)) begin
          if (amo_req_i.amo_op != AMO_LR) begin
            req_o       = present_way;
            addr_o      = mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
            we_o        = 1'b1;
            be_o.vldrty = present_way;
            if (amo_req_i.size == 2'b10) begin
              be_o.data[(amo_bit_off>>3)+:8] = mshr_q.addr[2] ? 8'hf0 : 8'h0f;
              data_o.data[amo_bit_off+:64] = {amo_new[31:0], amo_new[31:0]};
            end else begin
              be_o.data[(amo_bit_off>>3)+:8] = 8'hff;
              data_o.data[amo_bit_off+:64] = amo_new;
            end
            data_o.valid = 1'b1;
            data_o.dirty = 1'b1;
            data_o.owned = 1'b1;
          end
          if (amo_req_i.amo_op == AMO_LR) begin
            resv_valid_d = 1'b1;
            resv_addr_d  = mshr_q.addr[55:CVA6Cfg.DCACHE_OFFSET_WIDTH];
          end else if (amo_req_i.amo_op == AMO_SC) begin
            resv_valid_d = 1'b0;
          end
          amo_resp_o.ack    = 1'b1;
          amo_resp_o.result = (amo_req_i.amo_op inside {AMO_SC, AMO_CWRITE}) ? 64'd0 : amo_ret;
          mshr_d.valid      = 1'b0;
          amo_mshr_d        = 1'b0;
          if (amo_req_i.amo_op == AMO_LR) begin
            // Two cores running LR/SC loops on one line would otherwise kill
            // each other's reservations forever. Keep the tenure (no snoop
            // can reach the line) for a bounded time so the SC succeeds.
            state_d   = LR_HOLD;
            lr_hold_d = LrHoldCycles[$bits(lr_hold_d)-1:0];
          end else begin
            cc_done_o  = 1'b1;
            bus_held_d = 1'b0;
            state_d    = IDLE;
          end
        end else begin
          // absent or S: fetch it in M under this tenure, then come back
          state_d = MISS;
        end
      end

      // ~> only the SC to the reserved line runs under the LR tenure; the
      //    tenure covers that line only, and anything else (including another
      //    LR, e.g. a spin loop) must not keep the other cores out
      LR_HOLD: begin
        if (amo_req_i.req && !busy_i && amo_req_i.amo_op == AMO_SC &&
            amo_req_i.operand_a[55:CVA6Cfg.DCACHE_OFFSET_WIDTH] == resv_addr_q) begin
          state_d      = AMO_LOOKUP;
          mshr_d.valid = 1'b1;
          mshr_d.we    = 1'b1;
          mshr_d.id    = '0;
          mshr_d.addr  = amo_req_i.operand_a[55:0];
          mshr_d.wdata = '0;
          mshr_d.be    = '0;
          amo_mshr_d   = 1'b1;
        end else if (amo_req_i.req || flush_i || any_miss_req || lr_hold_q == '0) begin
          cc_done_o  = 1'b1;
          bus_held_d = 1'b0;
          state_d    = IDLE;
        end else begin
          lr_hold_d = lr_hold_q - 1'b1;
        end
      end

      default: ;
    endcase

    if (snoop_accept) snoop_d = snoop_i;
  end

  // ----------------------
  // AMO data path
  // ----------------------
  assign amo_cacheable = config_pkg::is_inside_cacheable_regions(
      CVA6Cfg, {{{64 - CVA6Cfg.PLEN} {1'b0}}, amo_req_i.operand_a[CVA6Cfg.PLEN-1:0]}
  );

  always_comb begin : amo_operands
    automatic logic [31:0] old_word;
    automatic logic unsigned_op;
    amo_line = '0;
    for (int unsigned i = 0; i < CVA6Cfg.DCACHE_SET_ASSOC; i++)
    if (data_i[i].valid && data_i[i].tag ==
        mshr_q.addr[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH])
      amo_line = data_i[i].data;
    amo_bit_off = mshr_q.addr[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3] << 6;
    amo_old = amo_line[amo_bit_off+:64];
    old_word = mshr_q.addr[2] ? amo_old[63:32] : amo_old[31:0];
    unsigned_op = amo_req_i.amo_op inside {AMO_MAXU, AMO_MINU};
    if (amo_req_i.size == 2'b10) begin
      // 32b operations compare as 32b values
      amo_operand_a_ext = unsigned_op ? {32'b0, old_word} : {{32{old_word[31]}}, old_word};
      amo_operand_b_ext = unsigned_op ? {32'b0, amo_req_i.operand_b[31:0]} :
          {{32{amo_req_i.operand_b[31]}}, amo_req_i.operand_b[31:0]};
      amo_ret = {{32{old_word[31]}}, old_word};
    end else begin
      amo_operand_a_ext = amo_old;
      amo_operand_b_ext = amo_req_i.operand_b;
      amo_ret = amo_old;
    end
  end

  logic [63:0] amo_alu_result;
  amo_alu #(
      .CVA6Cfg(CVA6Cfg)
  ) i_amo_alu (
      .amo_op_i       (amo_req_i.amo_op),
      .amo_operand_a_i(amo_operand_a_ext),
      .amo_operand_b_i(amo_operand_b_ext),
      .amo_result_o   (amo_alu_result)
  );
  // a cwrite stores its operand
  assign amo_new = (amo_req_i.amo_op == AMO_CWRITE) ? amo_operand_b_ext : amo_alu_result;
  assign ca_cwrite_addr_o = amo_req_i.operand_a[55:0];

  // check MSHR for aliasing
  logic [55:0] snoop_set_addr;
  assign snoop_set_addr = snoop_accept ? snoop_i.addr : snoop_q.addr;

  always_comb begin

    mshr_addr_matches_o  = 'b0;
    mshr_index_matches_o = 'b0;

    for (int i = 0; i < NR_PORTS; i++) begin
      // check mshr for potential matching of other units, exclude the unit currently being served
      if (mshr_q.valid && mshr_addr_i[i][55:CVA6Cfg.DCACHE_OFFSET_WIDTH] == mshr_q.addr[55:CVA6Cfg.DCACHE_OFFSET_WIDTH]) begin
        mshr_addr_matches_o[i] = 1'b1;
      end

      // same as previous, but checking only the index
      if (mshr_q.valid && mshr_addr_i[i][CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] == mshr_q.addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) begin
        mshr_index_matches_o[i] = 1'b1;
      end

      // a snoop on the set holds off stores, they are non-atomic (look-up,
      // then write) and must not write a line the snoop just took away
      if (snoop_busy && mshr_addr_i[i][CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] ==
          snoop_set_addr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) begin
        mshr_index_matches_o[i] = 1'b1;
      end
    end
  end
  // --------------------
  // Sequential Process
  // --------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mshr_q      <= '0;
      state_q     <= INIT;
      cnt_q       <= '0;
      evict_way_q <= '0;
      evict_cl_q  <= '0;
      serve_amo_q <= 1'b0;
      bus_held_q  <= 1'b0;
      snoop_q     <= '0;
      snoop_ret_q <= IDLE;
      snoop_way_q <= '0;
      amo_mshr_q  <= 1'b0;
      resv_valid_q <= 1'b0;
      resv_addr_q <= '0;
      lr_hold_q   <= '0;
    end else begin
      mshr_q      <= mshr_d;
      state_q     <= state_d;
      cnt_q       <= cnt_d;
      evict_way_q <= evict_way_d;
      evict_cl_q  <= evict_cl_d;
      serve_amo_q <= serve_amo_d;
      bus_held_q  <= bus_held_d;
      snoop_q     <= snoop_d;
      snoop_ret_q <= snoop_ret_d;
      snoop_way_q <= snoop_way_d;
      amo_mshr_q  <= amo_mshr_d;
      resv_valid_q <= resv_valid_d;
      resv_addr_q <= resv_addr_d;
      lr_hold_q   <= lr_hold_d;
    end
  end

  //pragma translate_off
`ifndef VERILATOR
  // assert that cache only hits on one way
  assert property (@(posedge clk_i) $onehot0(evict_way_q))
  else $warning("Evict-way should be one-hot encoded");
`endif
  //pragma translate_on

  // ----------------------
  // Pack bypass ports
  // ----------------------
  always_comb begin
    logic [$clog2(NR_BYPASS_PORTS)-1:0] id;

    // Pack MHSR ports first
    for (id = 0; id < NR_PORTS; id++) begin
      bypass_ports_req[id].req     = miss_req_valid[id] & miss_req_bypass[id];
      bypass_ports_req[id].reqtype = ariane_pkg::SINGLE_REQ;
      bypass_ports_req[id].amo     = AMO_NONE;
      bypass_ports_req[id].id      = 4'b1000 | 4'(id);
      bypass_ports_req[id].addr    = miss_req_addr[id];
      bypass_ports_req[id].wdata   = miss_req_wdata[id];
      bypass_ports_req[id].we      = miss_req_we[id];
      bypass_ports_req[id].be      = miss_req_be[id];
      bypass_ports_req[id].size    = miss_req_size[id];

      bypass_gnt_o[id]             = bypass_ports_rsp[id].gnt;
      bypass_valid_o[id]           = bypass_ports_rsp[id].valid;
      bypass_data_o[id]            = bypass_ports_rsp[id].rdata;
    end

    // AMO port has lowest priority
    bypass_ports_req[id] = amo_bypass_req;
    amo_bypass_rsp       = bypass_ports_rsp[id];
  end

  // ----------------------
  // Arbitrate bypass ports
  // ----------------------
  axi_adapter_arbiter #(
      .NR_PORTS           (NR_BYPASS_PORTS),
      .MAX_OUTSTANDING_REQ(CVA6Cfg.MaxOutstandingStores),
      .req_t              (bypass_req_t),
      .rsp_t              (bypass_rsp_t)
  ) i_bypass_arbiter (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      // Master Side
      .req_i (bypass_ports_req),
      .rsp_o (bypass_ports_rsp),
      // Slave Side
      .req_o (bypass_adapter_req),
      .rsp_i (bypass_adapter_rsp)
  );

  // ----------------------
  // Bypass AXI Interface
  // ----------------------
  // Cast bypass_adapter_req.addr to axi_adapter port size
  logic [CVA6Cfg.XLEN-1:0] bypass_addr;
  assign bypass_addr = bypass_adapter_req.addr;

  axi_adapter #(
      .CVA6Cfg              (CVA6Cfg),
      .DATA_WIDTH           (64),
      .CACHELINE_BYTE_OFFSET(CVA6Cfg.DCACHE_OFFSET_WIDTH),
      .axi_req_t            (axi_req_t),
      .axi_rsp_t            (axi_rsp_t)
  ) i_bypass_axi_adapter (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .req_i(bypass_adapter_req.req),
      .type_i(bypass_adapter_req.reqtype),
      .amo_i(bypass_adapter_req.amo),
      .id_i(({{CVA6Cfg.AxiIdWidth - 4{1'b0}}, bypass_adapter_req.id})),
      .addr_i(bypass_addr),
      .wdata_i(bypass_adapter_req.wdata),
      .we_i(bypass_adapter_req.we),
      .be_i(bypass_adapter_req.be),
      .size_i(bypass_adapter_req.size),
      .gnt_o(bypass_adapter_rsp.gnt),
      .valid_o(bypass_adapter_rsp.valid),
      .rdata_o(bypass_adapter_rsp.rdata),
      .id_o(),  // not used, single outstanding request in arbiter
      .critical_word_o(),  // not used for single requests
      .critical_word_valid_o(),  // not used for single requests
      .axi_req_o(axi_bypass_o),
      .axi_resp_i(axi_bypass_i)
  );

  // ----------------------
  // Cache Line AXI Refill
  // ----------------------
  // Cast req_fsm_miss_addr to axi_adapter port size
  logic [CVA6Cfg.XLEN-1:0] miss_addr;
  assign miss_addr = req_fsm_miss_addr;

  axi_adapter #(
      .CVA6Cfg              (CVA6Cfg),
      .DATA_WIDTH           (CVA6Cfg.DCACHE_LINE_WIDTH),
      .CACHELINE_BYTE_OFFSET(CVA6Cfg.DCACHE_OFFSET_WIDTH),
      .axi_req_t            (axi_req_t),
      .axi_rsp_t            (axi_rsp_t)
  ) i_miss_axi_adapter (
      .clk_i,
      .rst_ni,
      .req_i                (req_fsm_miss_valid),
      .type_i               (req_fsm_miss_req),
      .amo_i                (AMO_NONE),
      .gnt_o                (gnt_miss_fsm),
      .addr_i               (miss_addr),
      .we_i                 (req_fsm_miss_we),
      .wdata_i              (req_fsm_miss_wdata),
      .be_i                 (req_fsm_miss_be),
      .size_i               (req_fsm_miss_size),
      .id_i                 ({{CVA6Cfg.AxiIdWidth - 4{1'b0}}, 4'b0111}),
      .valid_o              (valid_miss_fsm),
      .rdata_o              (data_miss_fsm),
      .id_o                 (),
      .critical_word_o      (critical_word_o),
      .critical_word_valid_o(critical_word_valid_o),
      .axi_req_o            (axi_data_o),
      .axi_resp_i           (axi_data_i)
  );

  // -----------------
  // Replacement LFSR
  // -----------------
  lfsr_8bit #(
      .WIDTH(CVA6Cfg.DCACHE_SET_ASSOC)
  ) i_lfsr (
      .en_i          (lfsr_enable),
      .refill_way_oh (lfsr_oh),
      .refill_way_bin(lfsr_bin),
      .*
  );

  // -----------------
  // Struct Split
  // -----------------
  // Hack as system verilog support in modelsim seems to be buggy here
  always_comb begin
    automatic miss_req_t miss_req;

    for (int unsigned i = 0; i < NR_PORTS; i++) begin
      miss_req           = miss_req_t'(miss_req_i[i]);
      miss_req_valid[i]  = miss_req.valid;
      miss_req_bypass[i] = miss_req.bypass;
      miss_req_addr[i]   = miss_req.addr;
      miss_req_wdata[i]  = miss_req.wdata;
      miss_req_we[i]     = miss_req.we;
      miss_req_be[i]     = miss_req.be;
      miss_req_size[i]   = miss_req.size;
    end
  end
endmodule

// --------------
// AXI Arbiter
// --------------
//
// Description: Arbitrates access to AXI refill/bypass
//
module axi_adapter_arbiter #(
    parameter NR_PORTS = 4,
    parameter MAX_OUTSTANDING_REQ = 0,
    parameter type req_t = std_cache_pkg::bypass_req_t,
    parameter type rsp_t = std_cache_pkg::bypass_rsp_t
) (
    input  logic                clk_i,   // Clock
    input  logic                rst_ni,  // Asynchronous reset active low
    // Master ports
    input  req_t [NR_PORTS-1:0] req_i,
    output rsp_t [NR_PORTS-1:0] rsp_o,
    // Slave port
    output req_t                req_o,
    input  rsp_t                rsp_i
);

  localparam MAX_OUTSTANDING_CNT_WIDTH = $clog2(
      MAX_OUTSTANDING_REQ + 1
  ) > 0 ? $clog2(
      MAX_OUTSTANDING_REQ + 1
  ) : 1;

  typedef logic [MAX_OUTSTANDING_CNT_WIDTH-1:0] outstanding_cnt_t;

  enum logic {
    IDLE,
    SERVING
  }
      state_d, state_q;

  req_t req_d, req_q;
  logic [NR_PORTS-1:0] sel_d, sel_q;
  outstanding_cnt_t outstanding_cnt_d, outstanding_cnt_q;

  logic [NR_PORTS-1:0] req_flat;
  logic any_unselected_port_valid;

  for (genvar i = 0; i < NR_PORTS; i++) begin : gen_req_flat
    assign req_flat[i] = req_i[i].req;
  end
  assign any_unselected_port_valid = |(req_flat & ~(1 << sel_q));


  always_comb begin
    sel_d = sel_q;
    outstanding_cnt_d = outstanding_cnt_q;

    state_d = state_q;
    req_d = req_q;

    req_o = req_q;

    rsp_o = '0;
    rsp_o[sel_q].rdata = rsp_i.rdata;

    case (state_q)

      IDLE: begin
        // wait for incoming requests
        for (int unsigned i = 0; i < NR_PORTS; i++) begin
          if (req_i[i].req == 1'b1) begin
            sel_d   = i[$bits(sel_d)-1:0];
            state_d = SERVING;
            break;
          end
        end

        req_d = req_i[sel_d];
        req_o = req_i[sel_d];
        rsp_o[sel_d].gnt = req_i[sel_d].req;

        // Count outstanding transactions, i.e. requests which have been
        // granted but response hasn't arrived yet
        if (req_o.req && rsp_i.gnt) begin
          req_d.req = 1'b0;
          outstanding_cnt_d += 1;
        end
      end

      SERVING: begin
        // We can accept multiple outstanding transactions from same port.
        // To ensure fairness, we allow this only if all other ports are idle
        if ((!req_o.req) && !any_unselected_port_valid &&
          (outstanding_cnt_q != (MAX_OUTSTANDING_REQ - 1))) begin
          if (req_i[sel_q].req) begin
            req_d = req_i[sel_q];
            req_o = req_i[sel_q];
            rsp_o[sel_q].gnt = 1'b1;
            state_d = SERVING;
          end
        end

        // Count outstanding transactions, i.e. requests which have been
        // granted but response hasn't arrived yet
        if (req_o.req && rsp_i.gnt) begin
          req_d.req = 1'b0;
          outstanding_cnt_d += 1;
        end
        if (rsp_i.valid) begin
          outstanding_cnt_d -= 1;
          rsp_o[sel_q].valid = 1'b1;

          if ((outstanding_cnt_d == 0) && (!req_o.req || rsp_i.gnt)) state_d = IDLE;
        end
      end

      default:  /* default */;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q           <= IDLE;
      sel_q             <= '0;
      req_q             <= '0;
      outstanding_cnt_q <= '0;
    end else begin
      state_q           <= state_d;
      sel_q             <= sel_d;
      req_q             <= req_d;
      outstanding_cnt_q <= outstanding_cnt_d;
    end
  end
  // ------------
  // Assertions
  // ------------

  //pragma translate_off
`ifndef VERILATOR
  // make sure that we eventually get an rvalid after we received a grant
  assert property (@(posedge clk_i) rsp_i.gnt |-> ##[1:$] rsp_i.valid)
  else begin
    $error("There was a grant without a rvalid");
    $stop();
  end
  // assert that there is no grant without a request or outstanding transactions
  assert property (@(negedge clk_i) rsp_i.gnt |-> req_o.req)
  else begin
    $error("There was a grant without a request.");
    $stop();
  end
  // assert that the address does not contain X when request is sent
  assert property (@(posedge clk_i) (req_o.req) |-> (!$isunknown(req_o.addr)))
  else begin
    $error("address contains X when request is set");
    $stop();
  end

`endif
  //pragma translate_on
endmodule
