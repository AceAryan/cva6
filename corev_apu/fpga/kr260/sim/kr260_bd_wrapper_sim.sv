// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License.
//
// Description: Behavioral stand-in for the KR260 block design, to simulate
//              cva6_kr260_top with Verilator before going to the board.
//              Provides the PL clock and reset, raises cores_run once the
//              program is loaded, and serves S_AXI_CORE from a sparse PS DDR
//              (preloaded from +bin=<file> at PS 0x4000_0000) and the mailbox
//              at 0xC000_0000. Ends the simulation when the cores write
//              tohost (mailbox word 0): 1 = pass, else (code << 1) | 1.

module kr260_bd_wrapper (
    output logic        pl_clk,
    output logic        pl_resetn,
    output logic [ 0:0] cores_run,
    input  logic [ 4:0] S_AXI_CORE_awid,
    input  logic [31:0] S_AXI_CORE_awaddr,
    input  logic [ 7:0] S_AXI_CORE_awlen,
    input  logic [ 2:0] S_AXI_CORE_awsize,
    input  logic [ 1:0] S_AXI_CORE_awburst,
    input  logic [ 0:0] S_AXI_CORE_awlock,
    input  logic [ 3:0] S_AXI_CORE_awcache,
    input  logic [ 2:0] S_AXI_CORE_awprot,
    input  logic [ 3:0] S_AXI_CORE_awqos,
    input  logic        S_AXI_CORE_awvalid,
    output logic        S_AXI_CORE_awready,
    input  logic [63:0] S_AXI_CORE_wdata,
    input  logic [ 7:0] S_AXI_CORE_wstrb,
    input  logic        S_AXI_CORE_wlast,
    input  logic        S_AXI_CORE_wvalid,
    output logic        S_AXI_CORE_wready,
    output logic [ 4:0] S_AXI_CORE_bid,
    output logic [ 1:0] S_AXI_CORE_bresp,
    output logic        S_AXI_CORE_bvalid,
    input  logic        S_AXI_CORE_bready,
    input  logic [ 4:0] S_AXI_CORE_arid,
    input  logic [31:0] S_AXI_CORE_araddr,
    input  logic [ 7:0] S_AXI_CORE_arlen,
    input  logic [ 2:0] S_AXI_CORE_arsize,
    input  logic [ 1:0] S_AXI_CORE_arburst,
    input  logic [ 0:0] S_AXI_CORE_arlock,
    input  logic [ 3:0] S_AXI_CORE_arcache,
    input  logic [ 2:0] S_AXI_CORE_arprot,
    input  logic [ 3:0] S_AXI_CORE_arqos,
    input  logic        S_AXI_CORE_arvalid,
    output logic        S_AXI_CORE_arready,
    output logic [ 4:0] S_AXI_CORE_rid,
    output logic [63:0] S_AXI_CORE_rdata,
    output logic [ 1:0] S_AXI_CORE_rresp,
    output logic        S_AXI_CORE_rlast,
    output logic        S_AXI_CORE_rvalid,
    input  logic        S_AXI_CORE_rready
);

  localparam logic [31:0] DdrLoad = 32'h4000_0000;
  localparam logic [31:0] Mailbox = 32'hC000_0000;
  localparam longint unsigned MaxCycles = 20_000_000;

  logic [7:0] mem[logic [31:0]];

  initial pl_clk = 1'b0;
  always #10 pl_clk = ~pl_clk;  // 50 MHz

  // ---------------- program load and run ----------------
  initial begin
    string bin;
    int fd, n;
    logic [7:0] b;
    pl_resetn = 1'b0;
    cores_run = 1'b0;
    if (!$value$plusargs("bin=%s", bin)) $fatal(1, "+bin=<program.bin> missing");
    fd = $fopen(bin, "rb");
    if (fd == 0) $fatal(1, "cannot open %s", bin);
    n = 0;
    while ($fread(b, fd) == 1) begin
      mem[DdrLoad+n] = b;
      n++;
    end
    $fclose(fd);
    $display("loaded %0d bytes at PS 0x%h", n, DdrLoad);
    repeat (10) @(posedge pl_clk);
    pl_resetn = 1'b1;
    repeat (10) @(posedge pl_clk);
    cores_run = 1'b1;
  end

  // ---------------- AXI slave: one write and one read at a time ----------------
  // writes
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} w_state_e;
  w_state_e w_state;
  logic [31:0] w_addr;
  logic [4:0] w_id;
  logic [2:0] w_size;

  assign S_AXI_CORE_awready = (w_state == W_IDLE);
  assign S_AXI_CORE_wready = (w_state == W_DATA);
  assign S_AXI_CORE_bvalid = (w_state == W_RESP);
  assign S_AXI_CORE_bid = w_id;
  assign S_AXI_CORE_bresp = 2'b00;

  always_ff @(posedge pl_clk or negedge pl_resetn) begin
    if (!pl_resetn) begin
      w_state <= W_IDLE;
    end else begin
      case (w_state)
        W_IDLE:
        if (S_AXI_CORE_awvalid) begin
          if (S_AXI_CORE_awlock != 0) $fatal(1, "exclusive write");
          w_addr  <= S_AXI_CORE_awaddr;
          w_id    <= S_AXI_CORE_awid;
          w_size  <= S_AXI_CORE_awsize;
          w_state <= W_DATA;
        end
        W_DATA:
        if (S_AXI_CORE_wvalid) begin
          for (int i = 0; i < 8; i++)
          if (S_AXI_CORE_wstrb[i]) mem[{w_addr[31:3], 3'b000}+i] = S_AXI_CORE_wdata[8*i+:8];
          if (w_addr == Mailbox && S_AXI_CORE_wstrb[3:0] != 0) begin
            automatic logic [31:0] v = S_AXI_CORE_wdata[31:0];
            if (v != 0) begin
              if (v == 1) $display("RESULT PASS at %0t", $time);
              else $display("RESULT FAIL code %0d at %0t", v >> 1, $time);
              // benchmark results (mailbox words 16..79)
              for (int w = 16; w < 80; w++) begin
                automatic logic [31:0] a = Mailbox + 4 * w;
                $display("MBOX %0d %h", w, {mem.exists(a+3) ? mem[a+3] : 8'h0, mem.exists(a+2) ? mem[a+2] : 8'h0,
                                            mem.exists(a+1) ? mem[a+1] : 8'h0, mem.exists(a) ? mem[a] : 8'h0});
              end
              $finish;
            end
          end
          w_addr <= w_addr + (32'd1 << w_size);
          if (S_AXI_CORE_wlast) w_state <= W_RESP;
        end
        default: if (S_AXI_CORE_bready) w_state <= W_IDLE;
      endcase
    end
  end

  // reads
  logic r_busy;
  logic [31:0] r_addr;
  logic [7:0] r_left;
  logic [4:0] r_id;
  logic [2:0] r_size;

  assign S_AXI_CORE_arready = !r_busy;
  assign S_AXI_CORE_rvalid = r_busy;
  assign S_AXI_CORE_rid = r_id;
  assign S_AXI_CORE_rresp = 2'b00;
  assign S_AXI_CORE_rlast = (r_left == 0);
  always_comb
    for (int i = 0; i < 8; i++) begin
      automatic logic [31:0] a = {r_addr[31:3], 3'b000} + i;
      S_AXI_CORE_rdata[8*i+:8] = mem.exists(a) ? mem[a] : 8'h00;
    end

  always_ff @(posedge pl_clk or negedge pl_resetn) begin
    if (!pl_resetn) begin
      r_busy <= 1'b0;
    end else if (!r_busy) begin
      if (S_AXI_CORE_arvalid) begin
        if (S_AXI_CORE_arlock != 0) $fatal(1, "exclusive read");
        r_busy <= 1'b1;
        r_addr <= S_AXI_CORE_araddr;
        r_left <= S_AXI_CORE_arlen;
        r_id   <= S_AXI_CORE_arid;
        r_size <= S_AXI_CORE_arsize;
      end
    end else if (S_AXI_CORE_rready) begin
      r_addr <= r_addr + (32'd1 << r_size);
      if (r_left == 0) r_busy <= 1'b0;
      else r_left <= r_left - 1;
    end
  end

  // anything outside DDR and the mailbox is a bug in the top-level remap
  always_ff @(posedge pl_clk) begin
    if (S_AXI_CORE_awvalid && S_AXI_CORE_awready &&
        !(S_AXI_CORE_awaddr < 32'h8000_0000 || S_AXI_CORE_awaddr[31:13] == Mailbox[31:13]))
      $fatal(1, "write outside DDR/mailbox: %h", S_AXI_CORE_awaddr);
    if (S_AXI_CORE_arvalid && S_AXI_CORE_arready &&
        !(S_AXI_CORE_araddr < 32'h8000_0000 || S_AXI_CORE_araddr[31:13] == Mailbox[31:13]))
      $fatal(1, "read outside DDR/mailbox: %h", S_AXI_CORE_araddr);
  end

  longint unsigned cycles = 0;
  always_ff @(posedge pl_clk) begin
    cycles <= cycles + 1;
    if (cycles == MaxCycles) begin
      $display("RESULT TIMEOUT after %0d cycles", cycles);
      $finish;
    end
  end

endmodule
