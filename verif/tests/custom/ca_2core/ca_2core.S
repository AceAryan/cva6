# Conditional access (Singh, Brown, Spear) test for the CVA6_2CORE testharness,
# also runs on the single-core model (hart 1 then never shows up, so only the
# hart 0 part runs; see SINGLE below).
#
#   cread    rd, imm(rs1)   custom-0, funct3 000  tag the line, load if access not revoked
#   cwrite   rs2, imm(rs1)  custom-0, funct3 001  store if tagged and access not revoked
#   untagOne rs1            custom-1, funct3 000
#   untagAll                custom-1, funct3 001  clear tags, accessRevokedBit and CAFAIL
#   csr 0xCC0 (cafail): bit 0 CAFAIL, bit 1 accessRevokedBit
#
# Hart 0 writes tohost: 1 on success, (code << 1) | 1 on failure.

#define CREAD(rd, off, rs1)   .insn i 0x0B, 0, rd, rs1, off
#define CWRITE(rs2, off, rs1) .insn s 0x0B, 1, rs2, off(rs1)
#define UNTAG_ONE(rs1)        .insn i 0x2B, 0, x0, rs1, 0
#define UNTAG_ALL             .insn i 0x2B, 1, x0, x0, 0
/* CAFAIL is bit 0 of the cafail CSR; bit 1 (accessRevokedBit) can be set
   without any cread/cwrite having failed yet, so software tests bit 0 */
#define CAFAIL(rd)            csrr rd, 0xCC0; andi rd, rd, 1
#define CASTATUS(rd)          csrr rd, 0xCC0

#define FAIL_IF(code, ...) li a7, code; __VA_ARGS__, fail
/* busy-wait n iterations (uses t3): widens the race windows so that the same
   code without conditional access demonstrably breaks */
#define DELAY(n) li t3, n; 99: addi t3, t3, -1; bnez t3, 99b

#define GOOD   0x600d
#define POISON 0xdead
#define R      300     /* reclamation rounds */
#define NLOCK  100     /* lock acquisitions per hart */

  .section .text.init, "ax", @progbits
  .globl _start
_start:
  la    t0, trap_handler
  csrw  mtvec, t0
  csrr  s0, mhartid
  bnez  s0, hart1_wait

  # ======================= hart 0 alone ===============================
  la    s1, X
  la    s2, Y
  li    t0, 5
  sw    t0, 0(s1)

  # untagAll leaves a clean state
  UNTAG_ALL
  CASTATUS(t0)
  FAIL_IF(10, bnez t0)

  # cread loads and tags
  CREAD(a0, 0, s1)
  CAFAIL(t0)
  FAIL_IF(11, bnez t0)
  li    t1, 5
  FAIL_IF(12, bne a0, t1)

  # cwrite to the tagged line stores
  li    t1, 7
  CWRITE(t1, 0, s1)
  CAFAIL(t0)
  FAIL_IF(13, bnez t0)
  lw    t2, 0(s1)
  FAIL_IF(14, bne t2, t1)

  # cwrite to an untagged line fails and stores nothing; CAFAIL is sticky
  li    t1, 9
  CWRITE(t1, 0, s2)
  CAFAIL(t0)
  li    t1, 1
  FAIL_IF(15, bne t0, t1)
  lw    t2, 0(s2)
  FAIL_IF(16, bnez t2)
  CREAD(a0, 0, s1)             # access is not revoked: still loads
  li    t1, 7
  FAIL_IF(17, bne a0, t1)
  UNTAG_ALL
  CAFAIL(t0)
  FAIL_IF(18, bnez t0)

  # untagOne: the line is no longer tagged, cwrite fails
  CREAD(a0, 0, s1)
  UNTAG_ONE(s1)
  li    t1, 11
  CWRITE(t1, 0, s1)
  CAFAIL(t0)
  FAIL_IF(19, beqz t0)
  lw    t2, 0(s1)
  li    t1, 7
  FAIL_IF(20, bne t2, t1)
  UNTAG_ALL

  # cwrite with an immediate: bits [11:7] are imm[4:0], not a destination
  # register (imm 12 would have named a2)
  li    a2, 0x1234
  addi  s3, s1, -12
  CREAD(a0, 0, s1)
  li    t1, 13
  CWRITE(t1, 12, s3)
  CAFAIL(t0)
  FAIL_IF(21, bnez t0)
  li    t1, 0x1234
  FAIL_IF(22, bne a2, t1)
  lw    t2, 0(s1)
  li    t1, 13
  FAIL_IF(23, bne t2, t1)
  UNTAG_ALL

  # a trap with lines tagged revokes access, without tags it does not
  CREAD(a0, 0, s1)
  ecall
  CREAD(a0, 0, s1)
  CASTATUS(t0)
  li    t1, 3                  # CAFAIL and accessRevokedBit
  FAIL_IF(24, bne t0, t1)
  FAIL_IF(25, bnez a0)         # a failed cread returns 0
  UNTAG_ALL
  ecall
  CREAD(a0, 0, s1)
  CAFAIL(t0)
  FAIL_IF(26, bnez t0)
  UNTAG_ALL

  # the cafail CSR is read-only: a write traps (the handler counts it)
  la    t0, trap_count
  lw    t1, 0(t0)
  csrw  0xCC0, zero
  lw    t2, 0(t0)
  addi  t1, t1, 1
  FAIL_IF(27, bne t1, t2)

  # ======================= both harts =================================
  la    t0, go
  li    t1, 1
  sw    t1, 0(t0)
  # on the single-core model hart 1 never answers: stop after the hart 0 part
  li    t2, 20000
1:
  la    t0, hart1_up
  lw    t1, 0(t0)
  bnez  t1, reclaim_reader
  addi  t2, t2, -1
  bnez  t2, 1b
  j     pass

  # --- reclamation: hart 0 traverses P -> node -> val with creads --------
reclaim_reader:
  li    s4, 0                  # successful reads
  li    s5, 0                  # reads that failed (access revoked)
  li    s6, R
2:
  UNTAG_ALL
  la    t0, P
  CREAD(a0, 0, t0)             # node pointer
  CAFAIL(t1)
  bnez  t1, 3f
  DELAY(40)                    # the reclaimer may unlink and reclaim meanwhile
  CREAD(a1, 0, a0)             # node value
  CAFAIL(t1)
  bnez  t1, 3f
  li    t2, POISON             # a successful cread never sees a reclaimed node
  FAIL_IF(30, beq a1, t2)
  addi  s4, s4, 1
  j     4f
3:
  addi  s5, s5, 1
4:
  addi  s6, s6, -1
  bnez  s6, 2b
  UNTAG_ALL
  FAIL_IF(31, beqz s4)         # some reads must succeed
  la    t0, reads_ok
  sw    s4, 0(t0)
  la    t0, reads_revoked
  sw    s5, 0(t0)

  # wait for the reclaimer, then both run the lock
  la    t0, phase
3:
  lw    t1, 0(t0)
  beqz  t1, 3b
  jal   ra, lock_loop

  # wait for hart 1, check the counter
  la    t0, done
5:
  lw    t1, 0(t0)
  beqz  t1, 5b
  fence rw, rw
  la    t0, counter
  lw    t1, 0(t0)
  li    t2, 2*NLOCK
  FAIL_IF(32, bne t1, t2)      # mutual exclusion from cread/cwrite
  j     pass

  # ======================= hart 1 =====================================
hart1_wait:
  la    t0, go
1:
  lw    t1, 0(t0)
  beqz  t1, 1b
  la    t0, hart1_up
  li    t1, 1
  sw    t1, 0(t0)

  # --- reclamation: hart 1 unlinks the current node, then reclaims it ----
  li    s6, R
  la    s7, N1
  la    s8, N2
2:
  la    t0, P
  sw    s8, 0(t0)              # unlink N1 (P -> N2)
  li    t1, POISON
  sw    t1, 0(s7)              # reclaim N1: reuse its memory
  fence rw, rw                 # make the reuse visible for a while
  DELAY(80)
  li    t1, GOOD
  sw    t1, 0(s7)              # N1 back as a fresh node
  mv    t2, s7                 # swap roles
  mv    s7, s8
  mv    s8, t2
  addi  s6, s6, -1
  bnez  s6, 2b
  la    t0, phase
  li    t1, 1
  sw    t1, 0(t0)
  jal   ra, lock_loop
  la    t0, done
  li    t1, 1
  sw    t1, 0(t0)
park:
  wfi
  j     park

  # --- try-lock from cread/cwrite (paper, Algorithm 2) guarding a counter -
lock_loop:
  li    s9, NLOCK
  la    s10, lock
  la    s11, counter
1:
  UNTAG_ALL
  CREAD(t1, 0, s10)
  CAFAIL(t2)
  bnez  t2, 1b                 # revoked: retry
  bnez  t1, 1b                 # held: retry
  DELAY(20)                    # the other hart may take the lock meanwhile
  li    t1, 1
  CWRITE(t1, 0, s10)           # take it only if nobody touched it since
  CAFAIL(t2)
  bnez  t2, 1b
  UNTAG_ALL
  fence rw, rw
  lw    t1, 0(s11)             # critical section with plain accesses
  DELAY(40)
  addi  t1, t1, 1
  sw    t1, 0(s11)
  fence rw, rw
  sw    zero, 0(s10)           # release
  addi  s9, s9, -1
  bnez  s9, 1b
  ret

  # ======================= common =====================================
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

  # ecall and illegal instructions: count and skip
  .align 2
trap_handler:
  csrrw sp, mscratch, sp       # no stack needed, keep t-regs intact
  la    sp, trap_count
  sw    t6, 4(sp)
  lw    t6, 0(sp)
  addi  t6, t6, 1
  sw    t6, 0(sp)
  csrr  t6, mepc
  addi  t6, t6, 4
  csrw  mepc, t6
  lw    t6, 4(sp)
  csrrw sp, mscratch, sp
  mret

  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0

  .data
  .align 6
X:        .word 0
  .align 6
Y:        .word 0
  .align 6
P:        .word N1
  .align 6
N1:       .word GOOD
  .align 6
N2:       .word GOOD
  .align 6
lock:     .word 0
  .align 6
counter:  .word 0
  .align 6
go:       .word 0
  .align 6
hart1_up: .word 0
  .align 6
phase:    .word 0
  .align 6
done:     .word 0
  .align 6
trap_count: .word 0, 0
  .align 6
reads_ok:      .word 0
reads_revoked: .word 0
