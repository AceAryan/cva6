# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

CVA6 is a 6-stage, single-issue, in-order RISC-V CPU (RV64/RV32 IMAFDC, M/S/U privilege). The core is SystemVerilog and is configured at elaboration time by a `CVA6Cfg` struct built from the config packages in `core/include/*_config_pkg.sv` (selected by `TARGET`, e.g. `cv64a6_imafdc_sv39`).

Directory boundary rule (from README): `core/` must not depend on `corev_apu/` (the FPGA/SoC platform and testbenches). `common/` is shared by both; `vendor/` is third-party IP (do not edit in place); `verif/` holds the DV environment (`core-v-verif` is a submodule).

## Branch context: conditional access (CA) in the write-through D-cache

The `ca-snoop` branch adds "conditional access" to the WT D-cache (`core/cache_subsystem/wt_*`):

- `wt_cache_pkg::ca_op_t` (`core/include/wt_cache_pkg.sv`) defines CA ops: `CA_NONE`, `CA_CREAD`, `CA_CWRITE`, `CA_UNTAG_ONE`, `CA_UNTAG_ALL`. Ordinary accesses use `CA_NONE`.
- `wt_dcache_ca_tag_set` (instantiated in `wt_dcache.sv`) holds a small set of tagged line addresses plus a per-transaction-ID pending table. Ops are recorded at issue and take effect only at **commit** (`ca_commit_valid_i/ca_commit_id_i`, driven from `cva6.sv` per commit port using `trans_id`); `ca_flush_i` discards pending ops. Invalidations (from the miss unit / memory side) and snoop invalidations of a tagged line revoke access (`access_revoked_o`, `query_failed_o`).
- Snoop path: `snoop_valid_i/snoop_addr_i/snoop_ready_o/snoop_ack_o` on `wt_cache_subsystem` (line-aligned physical address). Currently tied off in `cva6.sv`.
- `wt_dcache_missunit` serializes tag metadata onto the memory port and backpressures load acks/invalidations until it returns to idle (`wr_cl_ready_o` low until `META_IDLE`), so adapter FIFO responses are not popped before the D-cache can accept them.
- `CA_TAG_SET_DEPTH` is a top-level parameter on `cva6` → `wt_cache_subsystem` → `wt_dcache`.
- When interfaces change, keep in sync: `cva6.sv`, `wt_cache_subsystem.sv`, `wt_dcache*.sv`, the standalone testbenches `corev_apu/tb/tb_wt_dcache/hdl/tb.sv` and `corev_apu/tb/tb_wt_axi_dcache/hdl/tb.sv`, and `core/Flist.cva6` (new files must be listed there, before their users).

## Branch context: MSI coherence on the write-back cache (cv32)

- **Target and plan.** The project builds a 2-core CVA6 with MSI coherence plus CA, with the KR260 as the final target. The phased plan is in `plan.md`. The 32-bit target is `cv32a6_imac_sv32_wb` (`std_nbdcache`).
- **Line state.** `std_nbdcache` has an `owned` bit per way in the status SRAM: I = !valid, S = valid & !owned, M = valid & owned.
- **`miss_handler` and the bus.** Every cacheable miss or flush write-back first gets a coherence tenure (`cc_req_o` / `cc_gnt_i` / `cc_done_o`).
- **Snoops.** They (`snoop_i` / `snoop_ready_o` / `snoop_ack_o`) are accepted only while no tenure is held. The ack comes after any dirty write-back's B response.
- **Rule for future changes.** A cache must be able to answer a snoop without needing the bus.
- **`cc_bus.sv`** is an atomic broadcast bus. Cacheable AMOs and LR/SC execute in the L1 under a GetM tenure. An LR keeps its tenure up to `LrHoldCycles` cycles waiting for its SC, which guarantees forward progress.
- **`cva6` parameter `CoherentL1`.** When 1, the cache uses the core's `cc_*`/`snoop_*` ports. When 0, it is tied off. `ariane.sv` always ties them off.
- **Two-core simulation.** Define `CVA6_2CORE` (`make verilate ... defines=CVA6_2CORE`). Without it, `ariane_soc_pkg` and `ariane_testharness` are unchanged.
- **Ground rules from `plan.md`.** Never commit or push, add no Co-authored-by trailers, and put all logs under `~/logs`.

## Commands

Only Verilator (`/usr/bin/verilator`, 5.032) is installed locally; there is no QuestaSim, so the Questa-based Makefiles under `corev_apu/tb/tb_wt_*dcache/` (`make simc`) will not run here.

### CA unit testbenches (`core/cache_subsystem/test/`)

Verified to build and pass with Verilator:

```sh
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style \
  --top-module wt_dcache_ca_tag_set_tb -Mdir /tmp/ca_obj \
  +incdir+core/include +incdir+vendor/pulp-platform/common_cells/include \
  core/include/config_pkg.sv core/include/cv64a6_imafdc_sv39_config_pkg.sv \
  core/include/riscv_pkg.sv core/include/ariane_pkg.sv core/include/wt_cache_pkg.sv \
  core/cache_subsystem/wt_dcache_ca_tag_set.sv \
  core/cache_subsystem/test/wt_dcache_ca_tag_set_tb.sv
/tmp/ca_obj/Vwt_dcache_ca_tag_set_tb   # prints "CA tag-set tests passed"
```

Swap the DUT/tb files and `--top-module` for `wt_dcache_ca_tag_cmp_tb`.

### MSI write-back cache testbench (`std_nbdcache_msi_tb`, target `cv32a6_imac_sv32_wb`)

The file list is at `~/logs/phase1/std_nbdcache_msi_tb.f`, with paths relative to the repo root.

```sh
verilator --binary --timing -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT \
  --top-module std_nbdcache_msi_tb -Mdir /tmp/msi_obj -f ~/logs/phase1/std_nbdcache_msi_tb.f
/tmp/msi_obj/Vstd_nbdcache_msi_tb +seed=1 +nrandom=4000   # prints PASSED
```

Optional plusargs:
- `+debug`: per-cycle FSM trace
- `+axidebug`: AXI beats
- `+watch=<hex addr>`: every event on one line

Two-cache MSI testbench: the file list is at `~/logs/phase2/std_nbdcache_2core_tb.f`, top module `std_nbdcache_2core_tb`. Run it with `+seed=N +nrandom=1500 [+hot]`.

Full-core Verilator models. Spike is in `tools/spike`, and the rv32 riscv-tests are built in `verif/tests/riscv-tests/isa`.

```sh
export RISCV=/home/ace/tools/riscv SPIKE_INSTALL_DIR=$PWD/tools/spike \
  VERILATOR_INSTALL_DIR=$PWD/tmp/verilator-v5.008 PATH=$PWD/tmp/verilator-v5.008/bin:$PATH
make verilate target=cv32a6_imac_sv32_wb                      # -> work-ver/
make verilate target=cv32a6_imac_sv32_wb defines=CVA6_2CORE ver-library=work-ver-2core
LD_LIBRARY_PATH=tools/spike/lib work-ver/Variane_testharness verif/tests/riscv-tests/isa/rv32ua-p-lrsc
```

- Building a model takes several minutes. Run long jobs with `setsid nohup`, because sessions can end mid-command.
- `rv32mi-p-breakpoint` fails on cv32 configs; upstream also disables it.

Full-core lint of a config:

```sh
CVA6_REPO_DIR=$PWD TARGET_CFG=<cfg> HPDCACHE_DIR=$PWD/core/cache_subsystem/hpdcache \
  verilator --lint-only -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
  --top-module cva6 -f core/Flist.cva6
```

### Full-core simulation (Verilator testharness + Spike)

Requires `RISCV` (toolchain path) and the custom Spike/Verilator installed by the regress scripts.

```sh
export RISCV=/path/to/toolchain
export DV_SIMULATORS=veri-testharness,spike
bash verif/regress/smoke-tests.sh            # installs tools/test suites, runs a smoke set
```

Run a single test (from `verif/sim/`, after `source verif/sim/setup-env.sh`):

```sh
cd verif/sim
python3 cva6.py --testlist=../tests/testlist_riscv-tests-cv64a6_imafdc_sv39-p.yaml \
  --test rv64ui-p-add --iss_yaml cva6.yaml --target cv64a6_imafdc_sv39 \
  --iss=veri-testharness,spike
python3 cva6.py --c_tests ../tests/custom/hello_world/hello_world.c --iss_yaml cva6.yaml \
  --target cv64a6_imafdc_sv39 --iss=veri-testharness,spike \
  --gcc_opts="..." --linker=../../config/gen_from_riscv_config/linker/link.ld
```

See `verif/regress/smoke-tests-cv64a6_imafdc_sv39.sh` for the exact `--gcc_opts`. Other suites are in `verif/regress/*.sh`. `NUM_JOBS` sets make parallelism. Clean with `make -C ../.. clean && make clean_all` from `verif/sim`.

The default `cv64a6_imafdc_sv39` target uses the WT cache (`DCacheType = WT`); `*_hpdcache*`, `*_wb*` and `cv32a65x` targets use other D-caches and do not exercise the CA logic.

### Lint / formatting (CI-enforced)

- Verible formatting on every `core/**/*.sv` except `core/include/*_config_pkg.sv` (`.github/workflows/verible.yml`, version `v0.0-4084-gf3e4d98b`, fails on any suggestion): `verible-verilog-format --inplace <file>`.
- `util/sanitize/systemverilog/xlen_misuse.sh` checks for misuse of `CVA6Cfg.XLEN`.

## Architecture notes

- Top: `core/cva6.sv` wires frontend → id_stage → issue_stage (scoreboard, read operands) → ex_stage (ALU, branch, CSR, mult, LSU, FPU, CVXIF) → commit_stage, plus `csr_regfile` and `controller` (flush generation). `trans_id` is the scoreboard index that follows an instruction from issue to commit.
- Cache subsystem is selected by `CVA6Cfg.DCacheType`: `wt_cache_subsystem` (write-through dcache + `cva6_icache`, to memory via `wt_axi_adapter` or `wt_l15_adapter` for OpenPiton), `std_cache_subsystem` (write-back `std_nbdcache`), or `cva6_hpdcache_subsystem` (vendored HPDcache).
- WT dcache internals (`wt_dcache.sv`): N read ports via `wt_dcache_ctrl` (load unit, PTW, AMO/etc.), one write port via `wt_dcache_wbuffer`, `wt_dcache_missunit` for refills/AMOs/invalidations from memory, `wt_dcache_mem` for tag/data banks with port arbitration.
- File lists: `core/Flist.cva6` (core), `Flist.ariane` / `Bender.yml` / `src_files.yml` for other flows.
