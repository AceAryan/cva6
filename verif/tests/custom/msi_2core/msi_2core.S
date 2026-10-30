# Two-hart MSI coherence test for the CVA6_2CORE testharness.
# Both harts start here (the boot ROM jumps every hart to 0x80000000) and run
# the same sequence on shared data. Hart 0 checks the results and writes
# tohost: 1 on success, (code << 1) | 1 on failure.

#define N 200          /* iterations per hart for every sub-test */
#define ARR_WORDS 64   /* shared array, interleaved between the harts */

  .section .text.init, "ax", @progbits
  .globl _start
_start:
  csrr  s0, mhartid           # s0 = hart id (0 or 1)

  # --- 1. amoadd on one counter -----------------------------------------
  la    a0, amo_ctr
  li    s2, N
  li    t1, 1
1:
  amoadd.w zero, t1, (a0)
  addi  s2, s2, -1
  bnez  s2, 1b

  # --- 2. LR/SC increments on another counter ---------------------------
  la    a0, lrsc_ctr
  li    s2, N
2:
  lr.w  t1, (a0)
  addi  t1, t1, 1
  sc.w  t2, t1, (a0)
  bnez  t2, 2b
  addi  s2, s2, -1
  bnez  s2, 2b

  # --- 3. false sharing: hart h writes arr[2*i+h] = (h << 16) | i -------
  la    a0, arr
  slli  t0, s0, 2              # byte offset of this hart's first word
  add   a0, a0, t0
  slli  t3, s0, 16
  li    s2, 0
3:
  or    t1, t3, s2
  sw    t1, 0(a0)
  addi  a0, a0, 8
  addi  s2, s2, 1
  li    t2, ARR_WORDS/2
  bne   s2, t2, 3b

  # --- 4. ping-pong: turn-taking increments with plain loads/stores ----
  la    a0, turn
  la    a1, pingpong
  li    s2, N
4:
  lw    t1, 0(a0)              # wait for our turn
  bne   t1, s0, 4b
  fence rw, rw
  lw    t1, 0(a1)
  addi  t1, t1, 1
  sw    t1, 0(a1)
  fence rw, rw
  xori  t1, s0, 1              # hand over to the other hart
  sw    t1, 0(a0)
  addi  s2, s2, -1
  bnez  s2, 4b

  # --- 5. message passing: hart 1 publishes, hart 0 consumes ------------
  la    a0, msg_data
  la    a1, msg_flag
  bnez  s0, 5f
6:
  lw    t1, 0(a1)              # hart 0: wait for the flag
  beqz  t1, 6b
  fence r, r
  lw    t1, 0(a0)
  li    t2, 0x600dcafe
  li    a7, 2                  # failure code 2: stale message data
  bne   t1, t2, fail
  j     7f
5:
  li    t1, 0x600dcafe         # hart 1: data, then flag
  sw    t1, 0(a0)
  fence w, w
  li    t1, 1
  sw    t1, 0(a1)
7:

  # --- done: hart 1 parks, hart 0 waits for it and checks ---------------
  la    a0, done
  li    t1, 1
  amoadd.w zero, t1, (a0)
  beqz  s0, check
park:
  wfi
  j     park

check:
  la    a0, done
8:
  lw    t1, 0(a0)
  li    t2, 2
  bne   t1, t2, 8b
  fence rw, rw

  la    a0, amo_ctr
  lw    t1, 0(a0)
  li    t2, 2*N
  li    a7, 3                  # failure code 3: AMO counter
  bne   t1, t2, fail

  la    a0, lrsc_ctr
  lw    t1, 0(a0)
  li    a7, 4                  # failure code 4: LR/SC counter
  bne   t1, t2, fail

  la    a0, pingpong
  lw    t1, 0(a0)
  li    a7, 5                  # failure code 5: ping-pong counter
  bne   t1, t2, fail

  # arr[2*i+h] == (h << 16) | i
  la    a0, arr
  li    s2, 0
9:
  lw    t1, 0(a0)
  mv    t3, s2
  li    a7, 6                  # failure code 6: hart 0 word of the array
  bne   t1, t3, fail
  lw    t1, 4(a0)
  li    t3, 0x10000
  or    t3, t3, s2
  li    a7, 7                  # failure code 7: hart 1 word of the array
  bne   t1, t3, fail
  addi  a0, a0, 8
  addi  s2, s2, 1
  li    t2, ARR_WORDS/2
  bne   s2, t2, 9b

pass:
  li    t1, 1
  la    a0, tohost
  sw    t1, 0(a0)
  j     pass

fail:
  slli  t1, a7, 1
  ori   t1, t1, 1
  la    a0, tohost
  sw    t1, 0(a0)
  j     fail

  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0

  # every shared variable in its own cache line
  .data
  .align 6
amo_ctr:  .word 0
  .align 6
lrsc_ctr: .word 0
  .align 6
turn:     .word 0
  .align 6
pingpong: .word 0
  .align 6
msg_data: .word 0
  .align 6
msg_flag: .word 0
  .align 6
done:     .word 0
  .align 6
arr:      .fill ARR_WORDS, 4, 0
