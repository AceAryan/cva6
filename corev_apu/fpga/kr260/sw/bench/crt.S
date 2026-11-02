# Startup for the KR260 benchmarks: every hart gets its own stack and calls
# main(hartid). Hart 0 writes main's return value to tohost; other harts park.

  .section .text.init, "ax", @progbits
  .globl _start
_start:
  la    t0, trap
  csrw  mtvec, t0
  csrr  a0, mhartid
  la    sp, stacks
  li    t0, STACK_SIZE
  addi  t1, a0, 1
  mul   t0, t0, t1
  add   sp, sp, t0
  call  main
  csrr  t0, mhartid
  bnez  t0, park
  la    t0, tohost
  sw    a0, 0(t0)
park:
  wfi
  j     park

  # no trap is expected: report mcause as failure code 100 + mcause
  .align 2
trap:
  csrr  t1, mcause
  addi  t1, t1, 100
  slli  t1, t1, 1
  ori   t1, t1, 1
  la    t0, tohost
  sw    t1, 0(t0)
1:
  j     1b

  .bss
  .align 4
stacks:
  .space STACK_SIZE * 2

  .section .tohost, "aw", @nobits
  .align 6
  .globl tohost
tohost: .space 64
