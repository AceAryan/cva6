#!/bin/bash
# Runs bare-metal programs on the KR260 two-core CVA6 over JTAG (xsdb).
#   corev_apu/fpga/kr260/kr260_run.sh <program.elf> [timeout_s] [seed]
# The first run after power-up (or with KR260_PROGRAM=1) programs the PL and
# initialises the PS; later runs only reload the program.
# Environment:
#   KR260_WIN_DIR  build directory as a WSL path (default /mnt/d/cva6_kr260)
#   XSDB_BAT       Windows path of xsdb.bat (default D:\Vivado\2023.2\bin\xsdb.bat)
set -e
ELF=$1
TIMEOUT=${2:-30}
SEED=${3:-0}
WIN=${KR260_WIN_DIR:-/mnt/d/cva6_kr260}
XSDB_BAT=${XSDB_BAT:-'D:\Vivado\2023.2\bin\xsdb.bat'}
OBJCOPY=${OBJCOPY:-riscv64-unknown-elf-objcopy}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)

mkdir -p "$WIN/run"
# psu_init.tcl from the exported hardware platform
if [ ! -f "$WIN/run/psu_init.tcl" ] || [ "$WIN/out/cva6_kr260.xsa" -nt "$WIN/run/psu_init.tcl" ]; then
  python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract('psu_init.tcl', sys.argv[2])" \
    "$WIN/out/cva6_kr260.xsa" "$WIN/run"
fi
cp "$ROOT/corev_apu/fpga/kr260/scripts/run_test.tcl" "$WIN/run/"
NAME=$(basename "$ELF" .elf)
# image from 0x8000_0000 (core view), loaded at PS DDR 0x4000_0000
"$OBJCOPY" -O binary -R .tohost "$ELF" "$WIN/run/$NAME.bin"

SKIP=1
[ "${KR260_PROGRAM:-0}" = 1 ] && SKIP=0
[ -f "$WIN/run/.programmed" ] && [ "$WIN/run/.programmed" -nt "$WIN/out/cva6_kr260.bit" ] || SKIP=0

cd "$WIN/run"
cmd.exe /c "$XSDB_BAT run_test.tcl ..\\out\\cva6_kr260.bit psu_init.tcl $NAME.bin $TIMEOUT $SKIP $SEED" 2>&1 \
  | tr -d '\r' > "$WIN/run/xsdb.log" || true
grep -a -E '^(RESULT|LOADED|MBOX)|rror' "$WIN/run/xsdb.log" || true
[ "$SKIP" = 0 ] && touch "$WIN/run/.programmed"
