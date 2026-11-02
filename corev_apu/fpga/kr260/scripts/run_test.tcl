# Runs one bare-metal program on the KR260 two-core CVA6 (xsdb).
#   xsdb run_test.tcl <bitstream> <psu_init.tcl> <program.bin> [timeout_s] [skip_fpga]
# The program is linked at 0x8000_0000 (core view) = PS DDR 0x4000_0000 and
# writes tohost (1 = pass, (code << 1) | 1 = fail) to the mailbox, which the PS
# sees at 0xA000_0000. The cores run while the GPIO at 0xA001_0000 holds 1.

set bit      [lindex $argv 0]
set psu_init [lindex $argv 1]
set bin      [lindex $argv 2]
set timeout  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 30}]
set skip     [expr {[llength $argv] > 4 ? [lindex $argv 4] : 0}]
set seed     [expr {[llength $argv] > 5 ? [lindex $argv 5] : 0}]

set MAILBOX 0xA0000000
set RUN     0xA0010000
set DDR     0x40000000

connect
targets -set -nocase -filter {name =~ "PSU"}
if {!$skip} {
  rst -system
  after 1000
  targets -set -nocase -filter {name =~ "PL"}
  fpga -file $bit
  targets -set -nocase -filter {name =~ "PSU"}
  source $psu_init
  psu_init
  after 200
  psu_ps_pl_isolation_removal
  after 200
  psu_ps_pl_reset_config
  after 200
}
targets -set -nocase -filter {name =~ "PSU"}
# the mailbox BRAM and the run GPIO live in the PL, which xsdb does not map by default
memmap -addr $MAILBOX -size 0x20000 -flags 3

# hold the cores, clear the mailbox, load the program
mwr $RUN 0
for {set i 0} {$i < 96} {incr i} { mwr [expr {$MAILBOX + 4 * $i}] 0 }
# word 2: seed for programs that use one
mwr [expr {$MAILBOX + 8}] $seed
dow -data $bin $DDR
puts "LOADED [file size $bin] bytes"

# run, then wait for tohost
set t0 [clock milliseconds]
mwr $RUN 1
set result 0
while {[clock milliseconds] - $t0 < $timeout * 1000} {
  set result [mrd -value $MAILBOX]
  if {$result != 0} break
  after 10
}
set ms [expr {[clock milliseconds] - $t0}]
mwr $RUN 0
if {$result == 0} {
  puts "RESULT TIMEOUT after ${ms} ms"
} elseif {$result == 1} {
  puts "RESULT PASS after ${ms} ms"
} else {
  puts "RESULT FAIL code [expr {$result >> 1}] (tohost=$result) after ${ms} ms"
}
# words 16.. hold benchmark results
set words [mrd -value [expr {$MAILBOX + 64}] 64]
puts "MBOX [join $words { }]"
