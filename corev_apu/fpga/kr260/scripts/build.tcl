# Builds the two-core CVA6 bitstream for the KR260 (Vivado 2023.2, batch mode).
#   vivado -mode batch -source build.tcl -tclargs <src root> <out dir> [synth|impl]
# <src root> holds the RTL at its repository-relative paths plus filelist.f
# (written by kr260_build.sh). Reports go to <out dir>/reports.

set src  [file normalize [lindex $argv 0]]
set out  [file normalize [lindex $argv 1]]
set stop [expr {[llength $argv] > 2 ? [lindex $argv 2] : "impl"}]
set here [file dirname [file normalize [info script]]]

file mkdir $out/reports
create_project kr260_cva6 $out/proj -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]

# ---------------- RTL ----------------
set fh [open $src/filelist.f r]
set files {}
foreach f [split [read $fh] "\n"] {
  if {$f ne ""} { lappend files $src/$f }
}
close $fh
add_files -norecurse $files
set_property file_type SystemVerilog [get_files -filter {FILE_TYPE == Verilog}]
set_property include_dirs [list \
  $src/core/include \
  $src/vendor/pulp-platform/common_cells/include \
  $src/vendor/pulp-platform/common_cells/src \
  $src/vendor/pulp-platform/axi/include \
  $src/common/local/util \
  $src/core/cache_subsystem/hpdcache/rtl/include \
  $src/core/cache_subsystem/hpdcache/rtl/src/utils/ecc \
] [current_fileset]
set registers $src/vendor/pulp-platform/common_cells/include/common_cells/registers.svh
add_files -norecurse $registers
set_property -dict {file_type {Verilog Header} is_global_include 1} [get_files $registers]

# ---------------- block design ----------------
source $here/kr260_bd.tcl
generate_target all [get_files kr260_bd.bd]
add_files -norecurse [make_wrapper -files [get_files kr260_bd.bd] -top]

set_property top cva6_kr260_top [current_fileset]
update_compile_order -fileset sources_1

# ---------------- synthesis ----------------
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  puts "BUILD_FAILED synth"
  exit 1
}
open_run synth_1
report_utilization                -file $out/reports/synth_utilization.rpt
report_utilization -hierarchical  -file $out/reports/synth_utilization_hier.rpt
close_design
if {$stop eq "synth"} {
  puts "BUILD_DONE synth"
  exit 0
}

# ---------------- implementation ----------------
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  puts "BUILD_FAILED impl"
  exit 1
}
open_run impl_1
report_utilization                -file $out/reports/impl_utilization.rpt
report_utilization -hierarchical  -file $out/reports/impl_utilization_hier.rpt
report_timing_summary -max_paths 20 -file $out/reports/impl_timing_summary.rpt
file copy -force [get_property DIRECTORY [get_runs impl_1]]/cva6_kr260_top.bit $out/cva6_kr260.bit
write_hw_platform -fixed -include_bit -force $out/cva6_kr260.xsa
puts "BUILD_DONE impl WNS=[get_property SLACK [get_timing_paths -max_paths 1 -setup]]"
exit 0
