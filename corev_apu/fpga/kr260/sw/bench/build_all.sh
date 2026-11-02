#!/bin/bash
# Builds every benchmark configuration for the KR260:
#   <out>/bench_<ds>_<scheme>_u<upd>_t<threads>.elf
# usage: build_all.sh <out dir> [NOPS]
set -e
OUT=$1
NOPS=${2:-3000}
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-riscv64-unknown-elf-gcc}
CFLAGS="-march=rv32ima_zicsr -mabi=ilp32 -mcmodel=medany -O2 -ffreestanding -fno-builtin \
  -fno-tree-loop-distribute-patterns -fno-strict-aliasing -nostdlib -nostartfiles -Wall -Wextra -Wno-unused-function \
  -DSTACK_SIZE=16384 -T $HERE/../link_kr260.ld"
mkdir -p "$OUT"
DSN=(x list bst stack hash)
SCN=(none ca hp qsbr)
for ds in 1 2 3 4; do
  for sc in 0 1 2 3; do
    for upd in 0 10 100; do
      for nt in 1 2; do
        "$CC" $CFLAGS -DDS=$ds -DSCHEME=$sc -DUPD=$upd -DNTHREADS=$nt -DNOPS=$NOPS \
          "$HERE/crt.S" "$HERE/bench.c" -o "$OUT/bench_${DSN[$ds]}_${SCN[$sc]}_u${upd}_t${nt}.elf"
      done
    done
  done
done
echo "built $(ls "$OUT"/*.elf | wc -l) configurations in $OUT"
