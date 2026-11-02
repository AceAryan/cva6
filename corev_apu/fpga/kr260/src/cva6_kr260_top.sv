// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.
//
// Description: Two CVA6 cores (cv32a6_imac_sv32_wb) with coherent write-back
//              L1s (MSI over cc_bus) and conditional access, for the AMD KR260.
//
//              The block design `kr260_bd` (scripts/kr260_bd.tcl) holds the
//              Zynq UltraScale+ PS and gives the cores:
//                - DDR through the PS S_AXI_HP0_FPD port
//                - an 8 KiB mailbox BRAM, shared with the PS
//                - the PL clock, and a run bit driven by the PS (AXI GPIO)
//
//              Core address map (physical):
//                0x8000_0000 - 0xBFFF_FFFF  DDR, cacheable; remapped here to PS
//                                           DDR 0x4000_0000 - 0x7FFF_FFFF
//                0xC000_0000 - 0xC000_1FFF  mailbox, uncached (tohost lives here
//                                           so the PS sees it without a flush)
//              The PS sees the mailbox at 0xA000_0000 and the run bit at
//              0xA001_0000. Both cores start at 0x8000_0000 once the PS sets
//              the run bit; software tells them apart through mhartid.

`include "axi/typedef.svh"

module cva6_kr260_top;

  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  localparam int unsigned NrCores = 2;

  // DDR window seen by the cores, and where it lands in PS DDR
  localparam logic [63:0] DdrCoreBase = 64'h8000_0000;
  localparam logic [63:0] DdrCoreEnd = 64'hC000_0000;
  localparam logic [63:0] DdrPsOffset = 64'h4000_0000;  // subtracted

  // ------------------
  // AXI types: core ports and the muxed port towards the block design
  // ------------------
  localparam int unsigned IdWidth = CVA6Cfg.AxiIdWidth;
  localparam int unsigned MstIdWidth = IdWidth + $clog2(NrCores);
  typedef logic [CVA6Cfg.AxiAddrWidth-1:0] addr_t;
  typedef logic [CVA6Cfg.AxiDataWidth-1:0] data_t;
  typedef logic [CVA6Cfg.AxiDataWidth/8-1:0] strb_t;
  typedef logic [CVA6Cfg.AxiUserWidth-1:0] user_t;
  typedef logic [IdWidth-1:0] id_t;
  typedef logic [MstIdWidth-1:0] mst_id_t;
  `AXI_TYPEDEF_ALL(core, addr_t, id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(mst, addr_t, mst_id_t, data_t, strb_t, user_t)

  // ------------------
  // Block design: PS, DDR port, mailbox, clock, run bit
  // ------------------
  logic clk, pl_rst_n, run;
  mst_req_t mst_req;
  mst_resp_t mst_resp;

  logic [31:0] bd_awaddr, bd_araddr;
  // block-design outputs; Vivado does not drive a struct partly from ports
  logic bd_awready, bd_wready, bd_bvalid, bd_arready, bd_rlast, bd_rvalid;
  logic [MstIdWidth-1:0] bd_bid, bd_rid;
  logic [1:0] bd_bresp, bd_rresp;
  logic [CVA6Cfg.AxiDataWidth-1:0] bd_rdata;

  kr260_bd_wrapper i_bd (
      .pl_clk          (clk),
      .pl_resetn       (pl_rst_n),
      .cores_run       (run),
      // AXI4 from the cores
      .S_AXI_CORE_awid   (mst_req.aw.id),
      .S_AXI_CORE_awaddr (bd_awaddr),
      .S_AXI_CORE_awlen  (mst_req.aw.len),
      .S_AXI_CORE_awsize (mst_req.aw.size),
      .S_AXI_CORE_awburst(mst_req.aw.burst),
      .S_AXI_CORE_awlock (mst_req.aw.lock),
      .S_AXI_CORE_awcache(mst_req.aw.cache),
      .S_AXI_CORE_awprot (mst_req.aw.prot),
      .S_AXI_CORE_awqos  (mst_req.aw.qos),
      .S_AXI_CORE_awvalid(mst_req.aw_valid),
      .S_AXI_CORE_awready(bd_awready),
      .S_AXI_CORE_wdata  (mst_req.w.data),
      .S_AXI_CORE_wstrb  (mst_req.w.strb),
      .S_AXI_CORE_wlast  (mst_req.w.last),
      .S_AXI_CORE_wvalid (mst_req.w_valid),
      .S_AXI_CORE_wready (bd_wready),
      .S_AXI_CORE_bid    (bd_bid),
      .S_AXI_CORE_bresp  (bd_bresp),
      .S_AXI_CORE_bvalid (bd_bvalid),
      .S_AXI_CORE_bready (mst_req.b_ready),
      .S_AXI_CORE_arid   (mst_req.ar.id),
      .S_AXI_CORE_araddr (bd_araddr),
      .S_AXI_CORE_arlen  (mst_req.ar.len),
      .S_AXI_CORE_arsize (mst_req.ar.size),
      .S_AXI_CORE_arburst(mst_req.ar.burst),
      .S_AXI_CORE_arlock (mst_req.ar.lock),
      .S_AXI_CORE_arcache(mst_req.ar.cache),
      .S_AXI_CORE_arprot (mst_req.ar.prot),
      .S_AXI_CORE_arqos  (mst_req.ar.qos),
      .S_AXI_CORE_arvalid(mst_req.ar_valid),
      .S_AXI_CORE_arready(bd_arready),
      .S_AXI_CORE_rid    (bd_rid),
      .S_AXI_CORE_rdata  (bd_rdata),
      .S_AXI_CORE_rresp  (bd_rresp),
      .S_AXI_CORE_rlast  (bd_rlast),
      .S_AXI_CORE_rvalid (bd_rvalid),
      .S_AXI_CORE_rready (mst_req.r_ready)
  );
  always_comb begin
    mst_resp          = '0;
    mst_resp.aw_ready = bd_awready;
    mst_resp.w_ready  = bd_wready;
    mst_resp.b_valid  = bd_bvalid;
    mst_resp.b.id     = bd_bid;
    mst_resp.b.resp   = bd_bresp;
    mst_resp.ar_ready = bd_arready;
    mst_resp.r_valid  = bd_rvalid;
    mst_resp.r.id     = bd_rid;
    mst_resp.r.data   = bd_rdata;
    mst_resp.r.resp   = bd_rresp;
    mst_resp.r.last   = bd_rlast;
  end

  // DDR window -> PS DDR, everything else unchanged
  function automatic logic [31:0] remap(input addr_t a);
    if (a >= DdrCoreBase && a < DdrCoreEnd) return 32'(a - DdrPsOffset);
    return a[31:0];
  endfunction
  assign bd_awaddr = remap(mst_req.aw.addr);
  assign bd_araddr = remap(mst_req.ar.addr);

  // cores, bus, and the mux are held in reset until the PS sets the run bit
  logic core_rst_n;
  always_ff @(posedge clk or negedge pl_rst_n) begin
    if (!pl_rst_n) core_rst_n <= 1'b0;
    else core_rst_n <= run;
  end

  // ------------------
  // Cores and coherence bus
  // ------------------
  core_req_t [NrCores-1:0] core_req, cut_req;
  core_resp_t [NrCores-1:0] core_resp, cut_resp;
  std_cache_pkg::cc_req_t [NrCores-1:0] cc_req;
  logic [NrCores-1:0] cc_gnt, cc_done, snoop_ready, snoop_ack;
  std_cache_pkg::cc_snoop_t [NrCores-1:0] cc_snoop;

  for (genvar c = 0; c < NrCores; c++) begin : gen_cores
    cva6 #(
        .CVA6Cfg      (CVA6Cfg),
        .CoherentL1   (1'b1),
        .axi_ar_chan_t(core_ar_chan_t),
        .axi_aw_chan_t(core_aw_chan_t),
        .axi_w_chan_t (core_w_chan_t),
        .b_chan_t     (core_b_chan_t),
        .r_chan_t     (core_r_chan_t),
        .noc_req_t    (core_req_t),
        .noc_resp_t   (core_resp_t)
    ) i_cva6 (
        .clk_i        (clk),
        .rst_ni       (core_rst_n),
        .boot_addr_i  (CVA6Cfg.VLEN'(DdrCoreBase)),
        .hart_id_i    (CVA6Cfg.XLEN'(c)),
        .irq_i        (2'b00),
        .ipi_i        (1'b0),
        .time_irq_i   (1'b0),
        .debug_req_i  (1'b0),
        .rvfi_probes_o(),
        .cvxif_req_o  (),
        .cvxif_resp_i ('0),
        .noc_req_o    (core_req[c]),
        .noc_resp_i   (core_resp[c]),
        .cc_req_o     (cc_req[c]),
        .cc_gnt_i     (cc_gnt[c]),
        .cc_done_o    (cc_done[c]),
        .snoop_i      (cc_snoop[c]),
        .snoop_ready_o(snoop_ready[c]),
        .snoop_ack_o  (snoop_ack[c])
    );
  end

  cc_bus #(
      .NumCaches(NrCores)
  ) i_cc_bus (
      .clk_i        (clk),
      .rst_ni       (core_rst_n),
      .req_i        (cc_req),
      .gnt_o        (cc_gnt),
      .done_i       (cc_done),
      .snoop_o      (cc_snoop),
      .snoop_ready_i(snoop_ready),
      .snoop_ack_i  (snoop_ack),
      .busy_o       (),
      .owner_o      ()
  );

  // ------------------
  // A register slice per core: the cache subsystem's AXI arbiters make valid
  // depend on ready, and the mux arbiter makes one core's ready depend on the
  // other's valid; without the cut these close a combinational loop through
  // both cores.
  // ------------------
  for (genvar c = 0; c < NrCores; c++) begin : gen_cut
    axi_cut #(
        .Bypass   (1'b0),
        .aw_chan_t(core_aw_chan_t),
        .w_chan_t (core_w_chan_t),
        .b_chan_t (core_b_chan_t),
        .ar_chan_t(core_ar_chan_t),
        .r_chan_t (core_r_chan_t),
        .req_t    (core_req_t),
        .resp_t   (core_resp_t)
    ) i_axi_cut (
        .clk_i     (clk),
        .rst_ni    (core_rst_n),
        .slv_req_i (core_req[c]),
        .slv_resp_o(core_resp[c]),
        .mst_req_o (cut_req[c]),
        .mst_resp_i(cut_resp[c])
    );
  end

  // ------------------
  // Both cores onto one AXI port; the ID gains the core number
  // ------------------
  axi_mux #(
      .SlvAxiIDWidth(IdWidth),
      .slv_aw_chan_t(core_aw_chan_t),
      .mst_aw_chan_t(mst_aw_chan_t),
      .w_chan_t     (core_w_chan_t),
      .slv_b_chan_t (core_b_chan_t),
      .mst_b_chan_t (mst_b_chan_t),
      .slv_ar_chan_t(core_ar_chan_t),
      .mst_ar_chan_t(mst_ar_chan_t),
      .slv_r_chan_t (core_r_chan_t),
      .mst_r_chan_t (mst_r_chan_t),
      .slv_req_t    (core_req_t),
      .slv_resp_t   (core_resp_t),
      .mst_req_t    (mst_req_t),
      .mst_resp_t   (mst_resp_t),
      .NoSlvPorts   (NrCores),
      .MaxWTrans    (8),
      .FallThrough  (1'b0),
      .SpillAw      (1'b1),
      .SpillW       (1'b0),
      .SpillB       (1'b0),
      .SpillAr      (1'b1),
      .SpillR       (1'b0)
  ) i_axi_mux (
      .clk_i      (clk),
      .rst_ni     (core_rst_n),
      .test_i     (1'b0),
      .slv_reqs_i (cut_req),
      .slv_resps_o(cut_resp),
      .mst_req_o  (mst_req),
      .mst_resp_i (mst_resp)
  );

endmodule
