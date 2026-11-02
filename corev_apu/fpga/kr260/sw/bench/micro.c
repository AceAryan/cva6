// Cost of the conditional-access primitives on the KR260 CVA6, one hart, all
// accesses L1 hits after a warm-up. Each figure is cycles per iteration of a
// loop of N, minus the cost of the empty loop. Results go to mailbox words
// 16.. as: magic, then pairs (id, cycles x 100).

#include <stdint.h>

#define MAILBOX ((volatile uint32_t *)0xC0000000u)
#define N 2000

static inline uint32_t rdcycle(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, mcycle" : "=r"(v));
  return v;
}

static volatile uint32_t data[64] __attribute__((aligned(64)));

#define LOOP(body)                                    \
  ({                                                  \
    uint32_t c0 = rdcycle();                          \
    for (int i = 0; i < N; i++) {                     \
      body;                                           \
    }                                                 \
    rdcycle() - c0;                                   \
  })

int main(int hart) {
  if (hart) return 0;
  volatile uint32_t *p = &data[0];
  volatile uint32_t *q = &data[8];
  uint32_t sink = 0, v;
  for (int i = 0; i < 64; i++) data[i] = i;
  uint32_t res[16];
  int n = 0;
  __asm__ volatile(".insn i 0x2B, 1, x0, x0, 0" ::: "memory");  // untagAll

  uint32_t empty = LOOP(__asm__ volatile("" ::: "memory"));
  // 1 plain load
  res[n++] = LOOP(sink += *p);
  // 2 cread
  res[n++] = LOOP(__asm__ volatile(".insn i 0x0B, 0, %0, %1, 0" : "=r"(v) : "r"(p) : "memory"); sink += v);
  // 3 cread + CAFAIL check (csrr + andi)
  res[n++] = LOOP(__asm__ volatile(".insn i 0x0B, 0, %0, %1, 0\n csrr t0, 0xCC0\n andi t0, t0, 1\n add %0, %0, t0"
                                   : "=r"(v) : "r"(p) : "t0", "memory"); sink += v);
  // 4 csrr cafail alone
  res[n++] = LOOP(__asm__ volatile("csrr %0, 0xCC0" : "=r"(v)::"memory"); sink += v);
  // 5 untagOne
  res[n++] = LOOP(__asm__ volatile(".insn i 0x2B, 0, x0, %0, 0" ::"r"(q) : "memory"));
  // 6 untagAll
  res[n++] = LOOP(__asm__ volatile(".insn i 0x2B, 1, x0, x0, 0" ::: "memory"));
  // 7 plain store
  res[n++] = LOOP(*p = (uint32_t)i);
  // 8 cread + cwrite to a tagged, owned line (the try-lock pattern)
  res[n++] = LOOP(__asm__ volatile(".insn i 0x0B, 0, %0, %1, 0\n .insn s 0x0B, 1, %0, 0(%1)" : "=&r"(v) : "r"(p) : "memory"));
  // 9 amoswap (in-L1 AMO)
  res[n++] = LOOP(__asm__ volatile("amoswap.w %0, %0, (%1)" : "+r"(v) : "r"(p) : "memory"));
  // 10 lr/sc pair
  res[n++] = LOOP(__asm__ volatile("lr.w %0, (%1)\n sc.w %0, %0, (%1)" : "=&r"(v) : "r"(p) : "memory"));
  // 11 fence rw,rw (hazard-pointer publication cost)
  res[n++] = LOOP(__asm__ volatile("fence rw, rw" ::: "memory"));

  __asm__ volatile(".insn i 0x2B, 1, x0, x0, 0" ::: "memory");
  MAILBOX[16] = 0x51C20001u;
  for (int i = 0; i < n; i++) {
    MAILBOX[17 + 2 * i] = (uint32_t)(i + 1);
    MAILBOX[18 + 2 * i] = (uint32_t)((int32_t)(res[i] - empty) * 100 / N);
  }
  MAILBOX[17 + 2 * n] = sink;
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  return 1;
}
