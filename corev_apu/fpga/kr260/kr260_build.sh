#!/bin/bash
# Mirrors the KR260 sources to a Windows directory and runs the Vivado build
# there, detached from this shell (it survives the WSL session).
#   corev_apu/fpga/kr260/kr260_build.sh [synth|impl]
# Environment:
#   KR260_WIN_DIR  Windows build directory as a WSL path (default /mnt/d/cva6_kr260)
#   VIVADO_BAT     Windows path of vivado.bat (default D:\Vivado\2023.2\bin\vivado.bat)
# Progress: $KR260_WIN_DIR/build.log; the last line is BUILD_DONE or BUILD_FAILED.
set -e
STOP=${1:-impl}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
WIN=${KR260_WIN_DIR:-/mnt/d/cva6_kr260}
VIVADO_BAT=${VIVADO_BAT:-'D:\Vivado\2023.2\bin\vivado.bat'}

mkdir -p "$WIN/src" "$WIN/scripts"
cd "$ROOT"
corev_apu/fpga/kr260/scripts/gen_filelist.sh < /dev/null > "$WIN/src/filelist.f"
# sources at their repository-relative paths, plus the include directories
{
  cat "$WIN/src/filelist.f"
  find core/include vendor/pulp-platform/common_cells/include vendor/pulp-platform/common_cells/src \
       vendor/pulp-platform/axi/include common/local/util \
       core/cache_subsystem/hpdcache/rtl/include core/cache_subsystem/hpdcache/rtl/src/utils/ecc \
       -name '*.svh' -o -name '*.vh'
} | sort -u | while read -r f; do
  mkdir -p "$WIN/src/$(dirname "$f")"
  cp -u "$f" "$WIN/src/$f"
done
cp corev_apu/fpga/kr260/scripts/*.tcl "$WIN/scripts/"

WINDIR=$(wslpath -w "$WIN")
rm -f "$WIN/build.log"
powershell.exe -NoProfile -Command "Start-Process -WindowStyle Hidden -WorkingDirectory '$WINDIR' \
  -FilePath 'cmd.exe' -ArgumentList '/c','$VIVADO_BAT -mode batch -nojournal -log vivado.log \
  -source scripts\\build.tcl -tclargs $WINDIR\\src $WINDIR\\out $STOP > build.log 2>&1'"
echo "started: $STOP build in $WINDIR (log: $WIN/build.log)"
