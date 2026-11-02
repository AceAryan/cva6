#!/bin/bash
# Prints the RTL source list (paths relative to the repo root) for the KR260
# two-core build of cv32a6_imac_sv32_wb, in compile order.
set -e
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT"
{
# core sources, with simulation-only SRAM models and tracers removed
CVA6_REPO_DIR=$ROOT TARGET_CFG=cv32a6_imac_sv32_wb HPDCACHE_DIR=$ROOT/core/cache_subsystem/hpdcache \
  python3 util/flist_flattener.py --print_newline core/Flist.cva6 \
  | sed "s|^$ROOT/||" \
  | grep -v -E '^\+incdir|tc_sram\.sv$|tc_sram_wrapper\.sv$|instr_tracer|hpdcache/rtl/src/common/macros/behav/'
# FPGA SRAMs (tc_sram_wrapper with Xilinx block-RAM inference)
echo vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx64.sv
echo vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx32.sv
echo vendor/pulp-platform/fpga-support/rtl/SyncSpRam.sv
echo common/local/util/tc_sram_fpga_wrapper.sv
# AXI mux of the two cores
echo vendor/pulp-platform/common_cells/src/spill_register_flushable.sv
echo vendor/pulp-platform/common_cells/src/spill_register.sv
echo vendor/pulp-platform/axi/src/axi_id_prepend.sv
echo vendor/pulp-platform/axi/src/axi_mux.sv
echo vendor/pulp-platform/axi/src/axi_cut.sv
echo corev_apu/fpga/kr260/src/cva6_kr260_top.sv
} | awk '!seen[$0]++'   # some FPGA RAMs already come with the core list
