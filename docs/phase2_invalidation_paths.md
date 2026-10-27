# OpenPiton WT L1D line-departure paths

Scope: the WT cache implementation selected for OpenPiton (`wt_cache_subsystem`
and, under `PITON_ARIANE`, `wt_l15_adapter`). The standard/write-back cache and
the icache invalidation path are excluded. This is a static RTL trace; external
OpenPiton behavior not represented in this checkout is identified as such.

## 1. Located RTL and types

| Item | Location | Notes |
|---|---|---|
| `wt_dcache_missunit` | `core/cache_subsystem/wt_dcache_missunit.sv:17` | Handles fills, remote invalidation returns, and the local flush scan. |
| `wt_dcache_mem` | `core/cache_subsystem/wt_dcache_mem.sv:26` | Tag/valid and data SRAM access. |
| `wt_dcache_ctrl` | `core/cache_subsystem/wt_dcache_ctrl.sv:16` | Load-side hit/miss controller; CA tag ownership is tracked separately by `wt_dcache_ca_tag_set`. |
| `wt_dcache_wbuffer` | `core/cache_subsystem/wt_dcache_wbuffer.sv:52` | Write-through store buffer and in-place cache-word update path. |
| `wt_dcache` | `core/cache_subsystem/wt_dcache.sv:16` | Wires missunit, controllers, write buffer, and memory. |
| OpenPiton L1.5 adapter | `core/cache_subsystem/wt_l15_adapter.sv:51` | Converts L15 responses to dcache return structs. |
| WT subsystem and local dcache structs | `core/cache_subsystem/wt_cache_subsystem.sv:22`, `:80-104` | `dcache_inval_t`, `dcache_req_t`, and `dcache_rtrn_t` are local typedefs here. |
| WT protocol enums | `core/include/wt_cache_pkg.sv:24-37` | Defines `dcache_in_t` including `DCACHE_INV_REQ`; it does **not** define `dcache_rtrn_t` or its `inv` struct. |
| L15 return pin struct | Adapter imports `l15_pkg` (`core/cache_subsystem/wt_l15_adapter.sv:54`); local dummy struct is `core/include/dummy_l15_pkg.sv:95-114` | The dummy struct includes `l15_inval_dcache_inval`, `l15_inval_address`, `l15_inval_way`, and `l15_inval_dcache_all_way` (the latter is commented “unused in openpiton” at line 106). The actual OpenPiton `l15_pkg` definition is NOT FOUND in this checkout. |
| SRAM wrappers | `common/local/util/sram_cache.sv:16-27`, `:34-76`, `:77-106`; `common/local/util/sram.sv:16-28`, `:65-81` | Generic cache SRAM wrapper and its one-port SRAM implementation. |

The OpenPiton selector is explicitly `ifdef PITON_ARIANE` around the
`wt_l15_adapter` instance (`core/cache_subsystem/wt_cache_subsystem.sv:185-207`).
The OpenPiton configuration selects `config_pkg::WT` and is 32 KiB, 8-way,
with 128-bit (16-byte) lines
(`core/include/cv64a6_imafdc_sv39_openpiton_config_pkg.sv:43-45`, `:72`); the
address index width includes the line-offset bits
(`core/include/ariane_pkg.sv:261-264`).

## 2. Invalidation return trace

1. **L15 pins to adapter input.** The wrapper takes packed `l15_rtrn_t` on
   `l15_rtrn_i` (`corev_apu/openpiton/ariane_verilog_wrap.sv:111-114`) and
   passes it through `noc_resp_i` (`corev_apu/openpiton/ariane_verilog_wrap.sv:217-230`,
   `:316-330`). The WT subsystem connects `noc_resp_i` to the adapter's
   `l15_rtrn_i` (`core/cache_subsystem/wt_cache_subsystem.sv:185-207`). The
   relevant packed fields are declared at
   `core/include/dummy_l15_pkg.sv:105-114`.
2. **Adapter FIFO and return decode.** A valid L15 response enters the return
   FIFO when `l15_req_o.l15_req_ack` is asserted; `rtrn_fifo_data` is its
   output (`core/cache_subsystem/wt_l15_adapter.sv:258-261`,
   `:343-360`). Adapter logic maps
   `l15_inval_dcache_inval -> inv.vld` and
   `l15_inval_dcache_all_way -> inv.all`
   (`core/cache_subsystem/wt_l15_adapter.sv:267-270`). On
   `L15_EVICT_REQ`, it sets `rtype = DCACHE_INV_REQ` and asserts dcache return
   valid iff `inv.vld | inv.all` (`core/cache_subsystem/wt_l15_adapter.sv:285-289`).
3. **Index and way slices.** The adapter assigns
   `inv.idx = {l15_inval_address[15:4], 4'b0000}` and
   `inv.way = l15_inval_way` (`core/cache_subsystem/wt_l15_adapter.sv:333-338`).
   The destination `idx` is only `DCACHE_INDEX_WIDTH` bits
   (`core/cache_subsystem/wt_cache_subsystem.sv:80-85`); for OpenPiton this
   width is 12 bits from `$clog2(L1D_size / associativity)` in
   `core/include/ariane_pkg.sv:261-264`. Consequently the 16-bit concatenation
   is truncated to the low 12 bits: `inv.idx[11:4]` contains
   `l15_inval_address[11:4]`, and `inv.idx[3:0]` is zero. The line offset is
   4 bits for this 16-byte line configuration
   (`core/include/cv64a6_imafdc_sv39_openpiton_config_pkg.sv:45`).
   The adapter preserves the way field without slicing; missunit one-hot
   decodes `inv.way` (`core/cache_subsystem/wt_dcache_missunit.sv:427-430`).
4. **Adapter return to missunit.** `wt_cache_subsystem` wires
   `adapter_dcache_rtrn_vld` and `adapter_dcache` to the dcache return inputs
   (`core/cache_subsystem/wt_cache_subsystem.sv:157-176`, `:200-206`);
   `wt_dcache` forwards those to `i_wt_dcache_missunit`
   (`core/cache_subsystem/wt_dcache.sv:174-186`).
5. **Return decode to clear request.** In `DCACHE_INV_REQ`, missunit sets
   `inv_vld = inv.vld | inv.all` and captures `inv.all`
   (`core/cache_subsystem/wt_dcache_missunit.sv:403-405`). It drives
   `wr_cl_we_o` to the selected way for `inv.vld`, or all ways for `inv.all`,
   and drives `wr_vld_bits_o = 0` for an invalidation
   (`core/cache_subsystem/wt_dcache_missunit.sv:425-435`). The write index is
   taken from `inv.idx[DCACHE_INDEX_WIDTH-1:DCACHE_OFFSET_WIDTH]`
   (`core/cache_subsystem/wt_dcache_missunit.sv:437-439`).
6. **Clear request to tag/valid SRAM.** `wt_dcache` wires missunit's
   `wr_cl_vld`, `wr_cl_we`, `wr_cl_idx`, and `wr_vld_bits` into `wt_dcache_mem`
   (`core/cache_subsystem/wt_dcache.sv:174-183`, `:356-383`). Memory uses
   `wr_cl_we_i` as per-way `vld_req`, `wr_cl_vld_i` as `vld_we`, and
   `wr_vld_bits_i` as `vld_wdata` (`core/cache_subsystem/wt_dcache_mem.sv:156-161`,
   `:189-190`). Each way's tag SRAM receives those as request, write enable,
   and `{valid, tag}` write data (`core/cache_subsystem/wt_dcache_mem.sv:330-352`).

**Does any tag/address bit beyond the index reach L1D on invalidation? NO.**
The only adapter address expression is the 16-bit `[15:4]`-plus-zero
concatenation (`wt_l15_adapter.sv:337`); the dcache field is only
`DCACHE_INDEX_WIDTH` bits (`wt_cache_subsystem.sv:83`), and missunit uses only
the index slice excluding offset (`wt_dcache_missunit.sv:437-439`). With the
OpenPiton 12-bit index width (`ariane_pkg.sv:263`), address bits above bit 11
(including the physical tag) are discarded before missunit. The way is
available separately through `inv.way`; this is not a tag comparison.

`inv.all` means all ways at the supplied set index, not a whole-cache flush:
the missunit sets all way write-enables, but still selects the index from
`inv.idx` (`wt_dcache_missunit.sv:427-439`). The OpenPiton L15 package marks
`l15_inval_dcache_all_way` as unused (`dummy_l15_pkg.sv:106`), so the RTL path
exists but actual OpenPiton generation of this return is not established here.

## 3. Valid/tag storage and replacement

- **Valid bits are SRAM bits, not the operational flop array.** The tag read
  result is packed as `[valid | address tag]`; the high bit drives
  `rd_vld_bits_o` (`core/cache_subsystem/wt_dcache_mem.sv:304-305`,
  `:330-334`). Each way has a `sram_cache` of `DCACHE_TAG_WIDTH + 1` bits and
  `DCACHE_NUM_WORDS` entries (`wt_dcache_mem.sv:336-352`). The comments naming
  `vld_req`/`vld_we` as “valid regs” are not the storage implementation
  (`wt_dcache_mem.sv:114-116`). `vld_mirror` is a flop mirror only in the
  verification block (`wt_dcache_mem.sv:389-423`).
- **Write/read port and enables.** Each way's tag SRAM has one request/write
  port: `req_i=vld_req[i]`, `we_i=vld_we`, `addr_i=vld_addr`,
  `wdata_i={vld_wdata[i],wr_cl_tag_i}`, and full-byte enable
  (`wt_dcache_mem.sv:336-352`). `sram_cache` forwards one `req/we/addr/data`
  interface to a single-port `tc_sram_wrapper` (`common/local/util/sram_cache.sv:34-76`);
  the generic `sram` path likewise generates a one-port macro
  (`common/local/util/sram.sv:65-81`). A CA bit stored adjacent to tag/valid
  therefore requires widening each way entry and its write-data/read-data
  buses, but no additional SRAM port.
- **Victim choice and fill.** The missunit selects an invalid way from the
  miss lookup's valid vector, otherwise a pseudo-random way
  (`wt_dcache_missunit.sv:191-211`). It saves both the missed address and
  `repl_way` in the MSHR on allocation (`wt_dcache_missunit.sv:213-219`).
  A cacheable load return writes that saved way and sets its valid bit
  (`wt_dcache_missunit.sv:425-448`). Thus a full-set fill overwrites the
  prior way's tag/line; a fill choosing an invalid way is not a valid-line
  departure.
- **CA-bit placement and global query cost.** The lowest-port-change placement
  is a CA bit in the existing per-way tag/valid SRAM word, updated in the same
  `vld_req/vld_we/vld_addr` transaction as the tag and valid bit
  (`wt_dcache_mem.sv:330-352`). It would not be a flop “alongside valid,”
  because operational valid is in SRAM (`wt_dcache_mem.sv:330-352`). A
  per-line CA flop array would permit a combinational global OR, but the OR
  reduction spans `DCACHE_NUM_WORDS * DCACHE_SET_ASSOC` bits. If CA is in the
  tag SRAM instead, its full-cache OR cannot be read combinationally from the
  SRAM output port; it would need a scan, another read capability, or a
  separately maintained summary bit. The existing SRAM interface exposes one
  address/read result per way (`sram_cache.sv:16-27`; `wt_dcache_mem.sv:336-352`).

## 4. Departure-cause table

“Invalidation-signalled” means the L1D receives the L15 return as
`DCACHE_INV_REQ`; “silent” means the line is displaced/cleared by another
local operation. `NOT FOUND` means no matching mechanism was found in the
examined WT/L15 RTL.

| # | Cause | Signalled/silent | File:line hook | Signals to probe in waves | Open question |
|---:|---|---|---|---|---|
| 1 | Remote-write invalidation (`inv.vld=1`, `inv.all=0`) | Invalidation-signalled; L15 `L15_EVICT_REQ` becomes `DCACHE_INV_REQ` (`wt_l15_adapter.sv:285-289`). | `wt_dcache_missunit.p_rtrn_logic` -> `wr_cl_we_o`, `wr_vld_bits_o`; valid clear is `wr_vld_bits_o=0` (`wt_dcache_missunit.sv:403-405`, `:425-439`). | `l15_rtrn_i.l15_inval_dcache_inval`, `rtrn_fifo_data`, `dcache_rtrn_o.inv.vld/idx/way`, `mem_rtrn_vld_i`, `mem_rtrn_i.rtype`, `inv_vld`, `wr_cl_vld_o`, `wr_cl_we_o`, `wr_cl_idx_o`, `wr_vld_bits_o`, `vld_req`, `vld_we`. | No RTL question; sender's choice of way/index is external. |
| 2 | All-way invalidation (`inv.all=1`) | Invalidation-signalled; all ways at one set, not a whole-cache sweep (`wt_dcache_missunit.sv:427-439`). | Same missunit write path; `inv_vld_all` makes `wr_cl_we_o='1`, while `wr_vld_bits_o='0` (`wt_dcache_missunit.sv:404-405`, `:427-439`). | `l15_inval_dcache_all_way`, `inv.all`, `inv_vld_all`, `wr_cl_we_o`, `wr_cl_idx_o`, `wr_vld_bits_o`. | OpenPiton package calls this dcache pin unused (`dummy_l15_pkg.sv:106`); whether real L15 emits it is NOT FOUND. |
| 3 | Own-core replacement on cacheable fill | Silent replacement; only a departure if the chosen way was valid. | Victim is `rnd_way` iff all ways valid, otherwise invalid way; MSHR retains `repl_way`; fill writes its tag/valid (`wt_dcache_missunit.sv:191-219`, `:425-448`; `wt_dcache_mem.sv:330-352`). | `miss_vld_bits_i`, `all_ways_valid`, `inv_way`, `rnd_way`, `repl_way`, `mshr_q.repl_way`, `cl_write_en`, `wr_cl_we_o`, `wr_cl_idx_o`, `wr_cl_tag_o`, `wr_vld_bits_o`. | None for the static departure path. |
| 4 | L1.5-driven eviction | Invalidation-signalled only: the adapter maps `L15_EVICT_REQ` plus dcache inval flags to `DCACHE_INV_REQ` (`wt_l15_adapter.sv:285-289`). No separate L1D eviction-return path was found. | Rows 1-2 are the L1D hooks (`wt_l15_adapter.sv:285-289`; `wt_dcache_missunit.sv:403-439`). | `l15_returntype`, dcache inval flags, `dcache_rtrn_o.rtype`, `dcache_rtrn_vld_o`, `mem_rtrn_i.rtype`, `inv_vld`. | Actual L15 emission/ordering is outside this repo. |
| 5 | Local flush / `fence.i` | Local control signal, not a remote invalidation. In this OpenPiton config `DcacheFlushOnFence=0` and `DcacheFlushOnFenceI=0` (`cv64a6_imafdc_sv39_openpiton_config_pkg.sv:47-49`), so neither fence setting requests this scan by default. | Missunit `FLUSH`: `flush_en=1`; each cycle writes `wr_vld_bits_o='0` at `cnt_q` for all ways; it increments through `DCACHE_NUM_WORDS` (`wt_dcache_missunit.sv:164-165`, `:433-439`, `:563-570`). Fence control can assert `flush_dcache` when configured (`core/controller.sv:123-156`, `:160-174`). | `dcache_flush_i`, `flush_i`, `state_q`, `flush_en`, `cnt_q`, `flush_done`, `wr_cl_idx_o`, `wr_cl_we_o`, `wr_vld_bits_o`, `flush_ack_o`. | None for the scan; verify the chosen build config if fence flush options are overridden. |
| 6 | AMO or non-cacheable access to a currently cached address | No direct valid clear found; these are not line-departure events by themselves. AMO requests are marked NC (`wt_dcache_missunit.sv:324-325`); non-cacheable load returns do not set `cl_write_en` (`:448`). | `cl_write_en = load_ack & ~mshr_q.nc`; only invalidation or flush branches clear valid (`wt_dcache_missunit.sv:427-448`). AMO uses `AMO`/`AMO_WAIT` states (`:572-592`). | `amo_sel`, `mem_data_o.nc`, `mshr_q.nc`, `load_ack`, `cl_write_en`, `wr_vld_bits_o`, `mem_rtrn_i.rtype`. | Any resulting remote L15 invalidation is row 1/2; whether L15 sends one is external. |
| 7 | Own store / write-buffer return | Store updates the resident cache word in place, not a tag/valid departure. Adapter maps store ACK to `DCACHE_STORE_ACK` (`wt_l15_adapter.sv:278-280`); missunit's store-ACK branch does not process `inv` (`wt_dcache_missunit.sv:380-403`). | On a checked buffer hit, `wr_req_o=hit_oh`; `wt_dcache_mem` accepts this as the single-word data write port, separate from tag/valid (`wt_dcache_wbuffer.sv:327-335`, `:391-401`; `wt_dcache_mem.sv:67-69`, `:213-220`). L15 `tid` is copied to return but no self-invalidation/TID filter is present in the invalidation decode (`wt_l15_adapter.sv:330-338`; `wt_dcache_missunit.sv:403-405`). | `wr_req_o`, `wr_ack_i`, `wr_idx_o`, `wr_off_o`, `wr_data_be_o`, `bank_we`, `vld_we`, `l15_rtrn_i.l15_threadid`, `l15_returntype`, `inv.vld`, `mem_rtrn_i.tid`. | Whether the real L15 echoes an invalidation for the issuing core's own store is NOT FOUND. |
| 8 | Invalidation while an index has an outstanding MSHR miss | No invalidation-to-MSHR cancel/match check found. An invalidation return does not clear `mshr_vld_q`; a later cacheable load return can therefore install its saved fill after the invalidation. A single return cannot be both `DCACHE_INV_REQ` and `DCACHE_LOAD_ACK`: missunit decodes mutually exclusive `rtype` cases (`wt_dcache_missunit.sv:373-405`). | MSHR address/way saved independently (`wt_dcache_missunit.sv:213-222`); invalidation clears valid at its selected index/way (`wt_dcache_missunit.sv:425-439`); later load ACK enables fill and clears MSHR (`wt_dcache_missunit.sv:375-378`, `:425-448`). | `mshr_vld_q`, `mshr_q.paddr`, `mshr_q.repl_way`, `mem_rtrn_i.rtype`, `load_ack`, `inv_vld`, `wr_cl_vld_o`, `wr_cl_idx_o`, `wr_cl_we_o`, `wr_vld_bits_o`, `mshr_vld_d`. | Whether the real L15 can return an invalidation between request acceptance and the matching load response needs directed simulation. |
| 9 | Reset/startup | Reset itself does not synchronously clear SRAM entries in `wt_dcache_mem`; it starts the missunit in `FLUSH`, which then performs the all-index local clear (row 5). | `state_q <= FLUSH`, `cnt_q <= 0` on reset (`wt_dcache_missunit.sv:611-626`); scan outputs clear valid (`:433-439`, `:563-570`). SRAM tag/valid is written via its normal port (`wt_dcache_mem.sv:336-352`). | `rst_ni`, `state_q`, `flush_en`, `cnt_q`, `wr_cl_idx_o`, `wr_vld_bits_o`, `vld_we`. | None for the programmed scan; macro power-up contents before scan completion are not guaranteed by this RTL. |
| 10 | Cache disable / re-enable | Disable alone is not a line clear: `enable_q` is gated off and misses become NC; re-enable from disabled requests the local full flush. | `enable_d=enable_q & enable_i`, `cache_en_o=enable_q`; IDLE starts `FLUSH` on `enable_i && !enable_q` (`wt_dcache_missunit.sv:163`, `:465-480`). Non-cacheable classification is in `wt_dcache_ctrl.sv:123-129`. | `enable_i`, `enable_q`, `cache_en_o`, `miss_nc_o`, `state_q`, `flush_en`, `wr_vld_bits_o`. | No direct clear on disable found. |
| 11 | Write-buffer hit forwarding / store-return writeback | Not a line departure; read data is overlaid from buffer and a clean returned store word may update data SRAM. | Forwarding mux (`wt_dcache_mem.sv:249-271`); single-word store write is separate and does not access tag SRAM (`:67-69`, `:213-220`). Wbuffer invalidation/refill tracking clears only its `checked` metadata, not L1D valid (`wt_dcache_wbuffer.sv:431-439`, `:535-539`). | `wbuffer_hit_oh`, `wbuffer_be`, `wr_req_i`, `wr_ack_o`, `bank_we`, `vld_we`, `inval_hit`. | None for L1D valid/tag path. |
| 12 | ECC/parity-triggered eviction | No ECC/parity departure hook found in this OpenPiton WT path. The OpenPiton configuration disables D-cache ECC (`cv64a6_imafdc_sv39_openpiton_config_pkg.sv:173-174`); outgoing L15 `l15_invalidate_cacheline` is tied low (`wt_l15_adapter.sv:128-130`). | `NOT FOUND` for an ECC/parity valid-clear path. | `l15_invalidate_cacheline`, `wr_vld_bits_o`, `wr_cl_we_o`. | None for this config; ECC-enabled configurations are outside scope. |

## 5. Needs simulation

These are the cases where the repository shows the receiving logic, but cannot
establish the external L15 stimulus or the timing that the proposed CA update
must meet.

1. **Does OpenPiton actually emit dcache `inv.all`?** The adapter implements
   it, but the L15 pin is marked unused (`dummy_l15_pkg.sv:106`). **Test:**
   inject an `L15_EVICT_REQ` with only `l15_inval_dcache_all_way=1` and a known
   address. Probe `dcache_rtrn_o.inv.{all,idx}`, `dcache_rtrn_vld_o`,
   `wr_cl_we_o`, and `wr_vld_bits_o`. If accepted, expect `inv.all=1`, all
   way enables, and zero valid write-data at the selected index; if rejected
   or never generated by the real endpoint, expect no such return/clear.
2. **Does L15 echo an invalidation for this core's own store?** The adapter
   does no self-TID filtering, but the L15 sender's policy is not in the
   repository. **Test:** issue a store whose line is resident, observe its
   `L15_STORE_RQ`/`l15_threadid`, then capture all returned L15 packets.
   Probe `l15_returntype`, `l15_threadid`, dcache inval flags, adapter
   `dcache_rtrn_o.rtype`, and missunit `inv_vld/wr_vld_bits_o`. Hypothesis A:
   no own-store invalidation packet, so only the data-word write occurs.
   Hypothesis B: L15 returns `L15_EVICT_REQ` with a dcache flag, which reaches
   the normal invalidation clear regardless of matching `tid`. Also inject a
   dcache inval flag on `L15_ST_ACK`: adapter/missunit should treat the return
   as store ACK, not `DCACHE_INV_REQ`.
3. **MSHR/invalidation response ordering.** The static logic shows no
   invalidation cancellation path, so an invalidation received while an MSHR
   is pending is followed by a later fill install if that load returns
   cacheable (`wt_dcache_missunit.sv:213-222`, `:375-405`, `:425-448`). The
   scalar return interface and `rtype` case decode cannot accept an
   invalidation and load ACK as the same return
   (`wt_dcache_missunit.sv:365-405`). What remains unknown is whether OpenPiton
   can return the invalidation in the interval before the response. **Test:**
   allocate an MSHR for index X, deliver `DCACHE_INV_REQ` for X before the
   matching load response, then return the load response. Probe
   `mshr_vld_q`, `mem_rtrn_i.rtype`, `inv_vld`, `wr_cl_idx_o`, `wr_cl_we_o`,
   `wr_vld_bits_o`, `mshr_vld_d`, and tag/valid SRAM output. Under the RTL
   behavior, expect valid clear first and then cacheable fill valid in the
   saved replacement way; under a cancellation/drop hypothesis, expect the
   fill not to assert `wr_vld_bits_o` and the line to remain invalid. A CA
   implementation must show that the old CA bit is sampled before the
   subsequent clear or overwrite.

## 6. Conditional-access state and limits

The L15 invalidation carries an index and way but no physical tag: the adapter
forms `inv.idx` from address bits `[15:4]` plus four zero offset bits, the
destination struct is only index-width, and missunit consumes only the index
slice plus `inv.way` (`wt_l15_adapter.sv:337-338`;
wt_cache_subsystem.sv:80-85; wt_dcache_missunit.sv:427-439). A tag-set-register
comparison keyed only by the invalidation address therefore cannot match the
full physical line tag from this event. The explicit tag set is core-local and
stores committed physical cache-line addresses; it compares exact lines for
addressed invalidations and conservatively invalidates all entries for a WT
return that lacks a complete address. CREAD reservations remain pending by
transaction ID until commit, so a flushed speculative CREAD does not leave a
tag. A matching invalidation during that pending window is remembered and
reported as failure to that CREAD before commit; if it later commits, the
sticky revocation state is set as well. A full set causes revocation when the
CREAD commits; entries are not silently evicted.

This design does not provide cross-core coherence or atomic CWRITE. CWRITE is
accepted only when its physical line is tagged and the sticky revocation state
is clear; it still passes through the existing write buffer, so an invalidation
can race with the memory write after that check. A custom cache protocol can
feed complete line invalidations into the tag-set interface; protocols without
a complete address must conservatively invalidate all local tags. Software
must issue `UNTAG_ALL` during a context switch; traps and context changes do not
clear the set automatically. Each hardware core has an independent local set.
