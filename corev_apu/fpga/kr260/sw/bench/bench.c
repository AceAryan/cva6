// Conditional access (Singh, Brown, Spear) benchmarks for the KR260 two-core
// CVA6: lazy list, external BST, Treiber stack and a hash table of lazy lists,
// each with a reclamation scheme:
//   none  leaky, nodes are never freed
//   ca    conditional access: cread/cwrite, nodes freed right after unlink
//   hp    hazard pointers, scan after every 30 removals
//   qsbr  quiescent-state-based reclamation, epoch advanced every 150 allocs
// Configuration (compile time): DS, SCHEME, UPD (% updates), NTHREADS, NOPS.
// Results are written to the uncached mailbox (see struct result).

#include <stdint.h>

#define DS_LIST 1
#define DS_BST 2
#define DS_STACK 3
#define DS_HASH 4
#define SCH_NONE 0
#define SCH_CA 1
#define SCH_HP 2
#define SCH_QSBR 3

#ifndef DS
#define DS DS_LIST
#endif
#ifndef SCHEME
#define SCHEME SCH_CA
#endif
#ifndef UPD
#define UPD 10
#endif
#ifndef NTHREADS
#define NTHREADS 2
#endif
#ifndef NOPS
#define NOPS 3000
#endif

#if DS == DS_BST
#define KEY_RANGE 10000
#else
#define KEY_RANGE 1024
#endif
#define NBUCKETS 128
#define MAXT 2
#define POOL 32768  // nodes per thread
#define HP_PER_T 3
#define RETIRE_MAX 4096
#define HP_SCAN_EVERY 30
#define QSBR_ADVANCE_EVERY 150
#define SAMPLE_EVERY 1000

#define MAILBOX ((volatile uint32_t *)0xC0000000u)
#define MB_SEED 2
#define MB_RESULT 16

#define KEY_MIN (-0x7fffffff)
#define KEY_MAX 0x7fffffff

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------
static inline uint32_t cread(volatile void *p) {
  uint32_t v;
  __asm__ volatile(".insn i 0x0B, 0, %0, %1, 0" : "=r"(v) : "r"(p) : "memory");
  return v;
}
static inline void cwrite(volatile void *p, uint32_t v) {
  __asm__ volatile(".insn s 0x0B, 1, %0, 0(%1)" ::"r"(v), "r"(p) : "memory");
}
static inline void untag_one(volatile void *p) {
  __asm__ volatile(".insn i 0x2B, 0, x0, %0, 0" ::"r"(p) : "memory");
}
static inline void untag_all(void) { __asm__ volatile(".insn i 0x2B, 1, x0, x0, 0" ::: "memory"); }
static inline uint32_t cafail(void) {  // CAFAIL is bit 0 of csr 0xCC0
  uint32_t v;
  __asm__ volatile("csrr %0, 0xCC0" : "=r"(v)::"memory");
  return v & 1;
}
static inline uint32_t rdcycle(void) {
  uint32_t v;
  __asm__ volatile("csrr %0, mcycle" : "=r"(v));
  return v;
}
static inline void fence(void) { __atomic_thread_fence(__ATOMIC_SEQ_CST); }

void *memset(void *d, int c, unsigned n) {
  uint8_t *p = d;
  while (n--) *p++ = (uint8_t)c;
  return d;
}
void *memcpy(void *d, const void *s, unsigned n) {
  uint8_t *p = d;
  const uint8_t *q = s;
  while (n--) *p++ = *q++;
  return d;
}

// ---------------------------------------------------------------------------
// nodes, one 16-byte cache line each
// ---------------------------------------------------------------------------
typedef struct node {
  volatile int32_t key;
  struct node *volatile next;  // list/stack: next; BST: left
  union {
    volatile uint32_t lock;      // list: lock
    struct node *volatile right;  // BST: right child
  };
  volatile uint32_t mark;      // list: mark; BST: flags
} __attribute__((aligned(16))) node_t;

// BST view of the same line
#define B_LEFT(n) ((n)->next)
#define B_RIGHT(n) ((n)->right)
#define B_FLAGS(n) ((n)->mark)
#define F_LOCK 1u
#define F_MARK 2u
#define F_LEAF 4u

// ---------------------------------------------------------------------------
// per-thread state, each in its own lines
// ---------------------------------------------------------------------------
typedef struct {
  node_t *free_list;
  uint32_t bump;
  uint32_t ops, ins_ok, del_ok, found;
  uint32_t retries;    // CA: failed attempts (revoked or try-lock lost)
  uint32_t allocs, frees, removed;
  uint32_t cycles;
  uint32_t max_unreclaimed;
  uint32_t nretired;
  uint32_t alloc_since_adv;
  uint32_t rnd;
} __attribute__((aligned(64))) tstate_t;

static node_t pool[MAXT][POOL];
static tstate_t ts[MAXT];
// hazard pointers, one line per thread
static node_t *volatile hp[MAXT][4] __attribute__((aligned(16)));
static struct {
  node_t *n;
  uint32_t epoch;
} retired[MAXT][RETIRE_MAX];
// qsbr
static volatile uint32_t g_epoch __attribute__((aligned(16)));
static volatile uint32_t q_epoch[MAXT][4] __attribute__((aligned(16)));
// start/stop
// in .data: .bss is not part of the loaded image, and hart 1 reads these
// before hart 0 initialises anything
#define LOADED __attribute__((section(".data"), aligned(16)))
static volatile uint32_t sync_start LOADED = 0;
static volatile uint32_t sync_arrive LOADED = 0;
static volatile uint32_t sync_done LOADED = 0;
static volatile uint32_t fatal_code LOADED = 0;

static inline uint32_t rnd(tstate_t *t) {
  uint32_t x = t->rnd;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  return t->rnd = x;
}

static node_t *alloc_node(int tid) {
  tstate_t *t = &ts[tid];
  node_t *n = t->free_list;
  if (n) t->free_list = n->next;
  else if (t->bump < POOL) n = &pool[tid][t->bump++];
  else {
    fatal_code = 50;  // pool exhausted
    for (;;);
  }
  t->allocs++;
  t->alloc_since_adv++;
  return n;
}

static void free_node(int tid, node_t *n) {
  n->key = KEY_MIN;  // reused memory: any stale reader sees garbage
  n->next = ts[tid].free_list;
  ts[tid].free_list = n;
  ts[tid].frees++;
}

static uint32_t unreclaimed(void) {
  uint32_t r = 0, f = 0;
  for (int i = 0; i < NTHREADS; i++) {
    r += ts[i].removed;
    f += ts[i].frees;
  }
  return r - f;
}

// ----- hazard pointers -----
static void hp_scan(int tid) {
  tstate_t *t = &ts[tid];
  node_t *prot[MAXT * HP_PER_T];
  int np = 0;
  fence();
  for (int i = 0; i < NTHREADS; i++)
    for (int j = 0; j < HP_PER_T; j++) prot[np++] = hp[i][j];
  uint32_t keep = 0;
  for (uint32_t k = 0; k < t->nretired; k++) {
    node_t *n = retired[tid][k].n;
    int hit = 0;
    for (int j = 0; j < np; j++) hit |= (prot[j] == n);
    if (hit) retired[tid][keep++] = retired[tid][k];
    else free_node(tid, n);
  }
  t->nretired = keep;
}

// ----- qsbr -----
static void qsbr_quiescent(int tid) { q_epoch[tid][0] = g_epoch; }

static void qsbr_reclaim(int tid) {
  tstate_t *t = &ts[tid];
  if (t->alloc_since_adv >= QSBR_ADVANCE_EVERY) {
    t->alloc_since_adv = 0;
    uint32_t e = g_epoch;
    int all = 1;
    for (int i = 0; i < NTHREADS; i++) all &= (q_epoch[i][0] == e);
    if (all) __atomic_compare_exchange_n(&g_epoch, &e, e + 1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
  }
  uint32_t minq = q_epoch[0][0];
  for (int i = 1; i < NTHREADS; i++)
    if ((int32_t)(q_epoch[i][0] - minq) < 0) minq = q_epoch[i][0];
  uint32_t keep = 0;
  for (uint32_t k = 0; k < t->nretired; k++) {
    // freed once every thread passed a quiescent state after the retire
    if ((int32_t)(minq - retired[tid][k].epoch) > 0) free_node(tid, retired[tid][k].n);
    else retired[tid][keep++] = retired[tid][k];
  }
  t->nretired = keep;
}

// a node was unlinked by thread tid
static void retire(int tid, node_t *n) {
  tstate_t *t = &ts[tid];
  t->removed++;
#if SCHEME == SCH_CA
  free_node(tid, n);  // immediate: CA makes stale readers fail
#elif SCHEME == SCH_HP
  if (t->nretired == RETIRE_MAX) hp_scan(tid);
  retired[tid][t->nretired++].n = n;
  if (t->removed % HP_SCAN_EVERY == 0) hp_scan(tid);
#elif SCHEME == SCH_QSBR
  if (t->nretired == RETIRE_MAX) qsbr_reclaim(tid);
  retired[tid][t->nretired].n = n;
  retired[tid][t->nretired++].epoch = g_epoch;
  if (t->removed % HP_SCAN_EVERY == 0) qsbr_reclaim(tid);
#else
  (void)n;  // none: leak
#endif
}

// ----- locks for the non-CA schemes -----
static inline void spin_lock(volatile uint32_t *l) {
  while (__atomic_exchange_n(l, 1u, __ATOMIC_ACQUIRE)) while (*l);
}
static inline void spin_unlock(volatile uint32_t *l) { __atomic_store_n(l, 0u, __ATOMIC_RELEASE); }
// BST flags carry the lock bit
static inline void flag_lock(volatile uint32_t *f) {
  while (__atomic_fetch_or(f, F_LOCK, __ATOMIC_ACQUIRE) & F_LOCK) while (*f & F_LOCK);
}
static inline void flag_unlock(volatile uint32_t *f) { __atomic_fetch_and(f, ~F_LOCK, __ATOMIC_RELEASE); }

// ----- CA try-lock (paper, Algorithm 2): the node must already be tagged -----
static inline int ca_trylock(volatile uint32_t *l) {
  uint32_t v = cread(l);
  if (cafail() || v) return 0;
  cwrite(l, 1);
  return !cafail();
}
static inline int ca_trylock_flags(volatile uint32_t *f) {
  uint32_t v = cread(f);
  if (cafail() || (v & (F_LOCK | F_MARK))) return 0;
  cwrite(f, v | F_LOCK);
  return !cafail();
}

// ===========================================================================
// lazy list (Heller et al.), CA version after the paper's Algorithm 3
// ===========================================================================
static node_t *list_new(int tid) {
  node_t *h = alloc_node(tid), *tl = alloc_node(tid);
  tl->key = KEY_MAX;
  tl->next = 0;
  tl->lock = 0;
  tl->mark = 0;
  h->key = KEY_MIN;
  h->next = tl;
  h->lock = 0;
  h->mark = 0;
  return h;
}

#if SCHEME == SCH_CA
// returns with pred and curr tagged; 0 when access was revoked (caller retries)
static int list_search(node_t *head, int32_t key, node_t **pp, node_t **cp, int32_t *ckp, int tid) {
  (void)tid;
  node_t *pred = head;
  node_t *curr = (node_t *)cread(&pred->next);
  if (cafail()) return 0;
  int32_t ck = (int32_t)cread(&curr->key);
  if (cafail()) return 0;
  while (ck < key) {
    untag_one(pred);  // keep only pred and curr tagged
    pred = curr;
    curr = (node_t *)cread(&pred->next);
    if (cafail()) return 0;
    ck = (int32_t)cread(&curr->key);
    if (cafail()) return 0;
  }
  *pp = pred;
  *cp = curr;
  *ckp = ck;
  return 1;
}

static int list_contains(node_t *head, int32_t key, int tid) {
  node_t *pred, *curr;
  int32_t ck;
  for (;;) {
    untag_all();
    if (list_search(head, key, &pred, &curr, &ck, tid)) {
      uint32_t m = cread(&curr->mark);
      if (!cafail()) {
        int r = (ck == key) && !m;  // values from creads only
        untag_all();
        return r;
      }
    }
    ts[tid].retries++;
  }
}

static int list_insert(node_t *head, int32_t key, int tid) {
  node_t *pred, *curr;
  int32_t ck;
  for (;;) {
    untag_all();
    if (list_search(head, key, &pred, &curr, &ck, tid) && ca_trylock(&pred->lock)) {
      if (ca_trylock(&curr->lock)) {
        // locked nodes cannot be freed: plain accesses from here on
        if (!pred->mark && !curr->mark && pred->next == curr) {
          int r = 0;
          if (curr->key != key) {
            node_t *n = alloc_node(tid);
            n->key = key;
            n->next = curr;
            n->lock = 0;
            n->mark = 0;
            fence();
            pred->next = n;
            r = 1;
          }
          fence();
          curr->lock = 0;
          pred->lock = 0;
          untag_all();
          return r;
        }
        curr->lock = 0;
      }
      pred->lock = 0;
    }
    ts[tid].retries++;
  }
}

static int list_delete(node_t *head, int32_t key, int tid) {
  node_t *pred, *curr;
  int32_t ck;
  for (;;) {
    untag_all();
    if (list_search(head, key, &pred, &curr, &ck, tid) && ca_trylock(&pred->lock)) {
      if (ca_trylock(&curr->lock)) {
        if (!pred->mark && !curr->mark && pred->next == curr) {
          if (curr->key != key) {
            curr->lock = 0;
            pred->lock = 0;
            untag_all();
            return 0;
          }
          curr->mark = 1;
          pred->next = curr->next;
          fence();
          pred->lock = 0;
          untag_all();
          retire(tid, curr);  // freed now
          return 1;
        }
        curr->lock = 0;
      }
      pred->lock = 0;
    }
    ts[tid].retries++;
  }
}

#else  // none / hp / qsbr: standard lazy list
static int list_search(node_t *head, int32_t key, node_t **pp, node_t **cp, int32_t *ckp, int tid) {
  node_t *pred = head;
  node_t *curr = pred->next;
#if SCHEME == SCH_HP
  hp[tid][0] = pred;
  hp[tid][1] = curr;
  fence();
  if (pred->next != curr) return 0;
#endif
  while (curr->key < key) {
    pred = curr;
#if SCHEME == SCH_HP
    hp[tid][0] = pred;  // still covered by hp[1] until here
#endif
    curr = pred->next;
#if SCHEME == SCH_HP
    hp[tid][1] = curr;
    fence();
    if (pred->mark || pred->next != curr) return 0;  // pred left the list
#endif
  }
  *pp = pred;
  *cp = curr;
  *ckp = curr->key;
  return 1;
}

static int list_contains(node_t *head, int32_t key, int tid) {
  node_t *pred, *curr;
  int32_t ck;
  while (!list_search(head, key, &pred, &curr, &ck, tid)) ts[tid].retries++;
  return ck == key && !curr->mark;
}

static int list_insert(node_t *head, int32_t key, int tid) {
  node_t *pred, *curr;
  int32_t ck;
  for (;;) {
    if (!list_search(head, key, &pred, &curr, &ck, tid)) {
      ts[tid].retries++;
      continue;
    }
    spin_lock(&pred->lock);
    spin_lock(&curr->lock);
    if (!pred->mark && !curr->mark && pred->next == curr) {
      int r = 0;
      if (curr->key != key) {
        node_t *n = alloc_node(tid);
        n->key = key;
        n->next = curr;
        n->lock = 0;
        n->mark = 0;
        fence();
        pred->next = n;
        r = 1;
      }
      spin_unlock(&curr->lock);
      spin_unlock(&pred->lock);
      return r;
    }
    spin_unlock(&curr->lock);
    spin_unlock(&pred->lock);
    ts[tid].retries++;
  }
}

static int list_delete(node_t *head, int32_t key, int tid) {
  node_t *pred, *curr;
  int32_t ck;
  for (;;) {
    if (!list_search(head, key, &pred, &curr, &ck, tid)) {
      ts[tid].retries++;
      continue;
    }
    spin_lock(&pred->lock);
    spin_lock(&curr->lock);
    if (!pred->mark && !curr->mark && pred->next == curr) {
      int r = 0;
      if (curr->key == key) {
        curr->mark = 1;
        pred->next = curr->next;
        r = 1;
      }
      spin_unlock(&curr->lock);
      spin_unlock(&pred->lock);
      if (r) retire(tid, curr);
      return r;
    }
    spin_unlock(&curr->lock);
    spin_unlock(&pred->lock);
    ts[tid].retries++;
  }
}
#endif

// ===========================================================================
// external BST: leaves hold the keys, internal nodes route; delete swings the
// grandparent's child to the sibling and frees parent and leaf
// ===========================================================================
static node_t *bst_root;

static node_t *bst_leaf(int tid, int32_t key) {
  node_t *l = alloc_node(tid);
  l->key = key;
  B_LEFT(l) = 0;
  B_RIGHT(l) = 0;
  B_FLAGS(l) = F_LEAF;
  return l;
}
static node_t *bst_internal(int tid, int32_t key, node_t *left, node_t *right) {
  node_t *n = alloc_node(tid);
  n->key = key;
  B_LEFT(n) = left;
  B_RIGHT(n) = right;
  B_FLAGS(n) = 0;
  return n;
}
static void bst_init(int tid) {
  bst_root = bst_internal(tid, KEY_MAX, bst_leaf(tid, KEY_MAX - 1), bst_leaf(tid, KEY_MAX));
}
#define B_CHILD(n, key) ((key) < (n)->key ? &B_LEFT(n) : &B_RIGHT(n))

#if SCHEME == SCH_CA
// gp, p and l stay tagged; 0 when revoked
static int bst_search(int32_t key, node_t **gpp, node_t **pp, node_t **lp, int32_t *lkp, int tid) {
  (void)tid;
  node_t *gp = 0, *p = bst_root;
  node_t *l = (node_t *)cread(&B_LEFT(p));
  if (cafail()) return 0;
  uint32_t lf = cread(&B_FLAGS(l));
  if (cafail()) return 0;
  while (!(lf & F_LEAF)) {
    int32_t lk = (int32_t)cread(&l->key);
    if (cafail()) return 0;
    if (gp) untag_one(gp);
    gp = p;
    p = l;
    l = (node_t *)cread(key < lk ? (volatile void *)&B_LEFT(l) : (volatile void *)&B_RIGHT(l));
    if (cafail()) return 0;
    lf = cread(&B_FLAGS(l));
    if (cafail()) return 0;
  }
  *lkp = (int32_t)cread(&l->key);
  if (cafail()) return 0;
  *gpp = gp;
  *pp = p;
  *lp = l;
  return 1;
}

static int bst_contains(int32_t key, int tid) {
  node_t *gp, *p, *l;
  int32_t lk;
  for (;;) {
    untag_all();
    if (bst_search(key, &gp, &p, &l, &lk, tid)) {
      int r = (lk == key);
      untag_all();
      return r;
    }
    ts[tid].retries++;
  }
}

static int bst_insert(int32_t key, int tid) {
  node_t *gp, *p, *l;
  int32_t lk;
  for (;;) {
    untag_all();
    if (bst_search(key, &gp, &p, &l, &lk, tid)) {
      if (lk == key) {
        untag_all();
        return 0;
      }
      if (ca_trylock_flags(&B_FLAGS(p))) {
        if (*B_CHILD(p, key) == l) {
          node_t *nl = bst_leaf(tid, key);
          node_t *ni = key < l->key ? bst_internal(tid, l->key, nl, l) : bst_internal(tid, key, l, nl);
          fence();
          *B_CHILD(p, key) = ni;
          fence();
          B_FLAGS(p) &= ~F_LOCK;
          untag_all();
          return 1;
        }
        B_FLAGS(p) &= ~F_LOCK;
      }
    }
    ts[tid].retries++;
  }
}

static int bst_delete(int32_t key, int tid) {
  node_t *gp, *p, *l;
  int32_t lk;
  for (;;) {
    untag_all();
    if (bst_search(key, &gp, &p, &l, &lk, tid)) {
      if (lk != key) {
        untag_all();
        return 0;
      }
      if (ca_trylock_flags(&B_FLAGS(gp))) {
        if (ca_trylock_flags(&B_FLAGS(p))) {
          if (*B_CHILD(gp, key) == p && *B_CHILD(p, key) == l) {
            node_t *s = (*B_CHILD(p, key) == B_LEFT(p)) ? B_RIGHT(p) : B_LEFT(p);
            *B_CHILD(gp, key) = s;
            B_FLAGS(p) |= F_MARK;
            fence();
            B_FLAGS(gp) &= ~F_LOCK;
            untag_all();
            retire(tid, p);
            retire(tid, l);
            return 1;
          }
          B_FLAGS(p) &= ~F_LOCK;
        }
        B_FLAGS(gp) &= ~F_LOCK;
      }
    }
    ts[tid].retries++;
  }
}

#else  // none / hp / qsbr
static int bst_search(int32_t key, node_t **gpp, node_t **pp, node_t **lp, int32_t *lkp, int tid) {
  node_t *gp = 0, *p = bst_root;
  node_t *l = B_LEFT(p);
#if SCHEME == SCH_HP
  int sgp = 0, sp = 1, sl = 2;  // hazard slots of gp, p, l
  hp[tid][sp] = p;
  hp[tid][sl] = l;
  fence();
  if (B_LEFT(p) != l) return 0;
#endif
  while (!(B_FLAGS(l) & F_LEAF)) {
    gp = p;
    p = l;
#if SCHEME == SCH_HP
    int t = sgp;  // old gp's slot gets the new l
    sgp = sp;
    sp = sl;
    sl = t;
#endif
    l = *B_CHILD(p, key);
#if SCHEME == SCH_HP
    hp[tid][sl] = l;
    fence();
    if ((B_FLAGS(p) & F_MARK) || *B_CHILD(p, key) != l) return 0;
#endif
  }
  *gpp = gp;
  *pp = p;
  *lp = l;
  *lkp = l->key;
  return 1;
}

static int bst_contains(int32_t key, int tid) {
  node_t *gp, *p, *l;
  int32_t lk;
  while (!bst_search(key, &gp, &p, &l, &lk, tid)) ts[tid].retries++;
  return lk == key;
}

static int bst_insert(int32_t key, int tid) {
  node_t *gp, *p, *l;
  int32_t lk;
  for (;;) {
    if (!bst_search(key, &gp, &p, &l, &lk, tid)) {
      ts[tid].retries++;
      continue;
    }
    if (lk == key) return 0;
    flag_lock(&B_FLAGS(p));
    if (!(B_FLAGS(p) & F_MARK) && *B_CHILD(p, key) == l) {
      node_t *nl = bst_leaf(tid, key);
      node_t *ni = key < l->key ? bst_internal(tid, l->key, nl, l) : bst_internal(tid, key, l, nl);
      fence();
      *B_CHILD(p, key) = ni;
      flag_unlock(&B_FLAGS(p));
      return 1;
    }
    flag_unlock(&B_FLAGS(p));
    ts[tid].retries++;
  }
}

static int bst_delete(int32_t key, int tid) {
  node_t *gp, *p, *l;
  int32_t lk;
  for (;;) {
    if (!bst_search(key, &gp, &p, &l, &lk, tid)) {
      ts[tid].retries++;
      continue;
    }
    if (lk != key) return 0;
    flag_lock(&B_FLAGS(gp));
    flag_lock(&B_FLAGS(p));
    if (!(B_FLAGS(gp) & F_MARK) && !(B_FLAGS(p) & F_MARK) && *B_CHILD(gp, key) == p &&
        *B_CHILD(p, key) == l) {
      node_t *s = (*B_CHILD(p, key) == B_LEFT(p)) ? B_RIGHT(p) : B_LEFT(p);
      *B_CHILD(gp, key) = s;
      __atomic_fetch_or(&B_FLAGS(p), F_MARK, __ATOMIC_SEQ_CST);
      flag_unlock(&B_FLAGS(p));
      flag_unlock(&B_FLAGS(gp));
      retire(tid, p);
      retire(tid, l);
      return 1;
    }
    flag_unlock(&B_FLAGS(p));
    flag_unlock(&B_FLAGS(gp));
    ts[tid].retries++;
  }
}
#endif

// ===========================================================================
// Treiber stack, CA version after the paper's Algorithm 1
// ===========================================================================
static node_t *volatile stack_top __attribute__((aligned(16)));

static void stack_push(int32_t key, int tid) {
  node_t *n = alloc_node(tid);
  n->key = key;
#if SCHEME == SCH_CA
  for (;;) {
    untag_all();
    node_t *t = (node_t *)cread(&stack_top);
    if (!cafail()) {
      n->next = t;
      fence();
      cwrite(&stack_top, (uint32_t)n);
      if (!cafail()) {
        untag_all();
        return;
      }
    }
    ts[tid].retries++;
  }
#else
  node_t *t = stack_top;
  do {
    n->next = t;
  } while (!__atomic_compare_exchange_n(&stack_top, &t, n, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST) &&
           (ts[tid].retries++, 1));
#endif
}

static int stack_pop(int tid) {
#if SCHEME == SCH_CA
  for (;;) {
    untag_all();
    node_t *t = (node_t *)cread(&stack_top);
    if (!cafail()) {
      if (!t) {
        untag_all();
        return 0;
      }
      node_t *nx = (node_t *)cread(&t->next);
      if (!cafail()) {
        cwrite(&stack_top, (uint32_t)nx);  // linearization point
        if (!cafail()) {
          untag_all();
          retire(tid, t);  // freed now
          return 1;
        }
      }
    }
    ts[tid].retries++;
  }
#else
  for (;;) {
    node_t *t = stack_top;
    if (!t) return 0;
#if SCHEME == SCH_HP
    hp[tid][0] = t;
    fence();
    if (stack_top != t) {
      ts[tid].retries++;
      continue;
    }
#endif
    node_t *nx = t->next;
    if (__atomic_compare_exchange_n(&stack_top, &t, nx, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
      retire(tid, t);
      return 1;
    }
    ts[tid].retries++;
  }
#endif
}

static int stack_peek(int tid) {
#if SCHEME == SCH_CA
  for (;;) {
    untag_all();
    node_t *t = (node_t *)cread(&stack_top);
    if (!cafail()) {
      int r = 0;
      if (t) {
        (void)cread(&t->key);
        if (cafail()) {
          ts[tid].retries++;
          continue;
        }
        r = 1;
      }
      untag_all();
      return r;
    }
    ts[tid].retries++;
  }
#else
  for (;;) {
    node_t *t = stack_top;
    if (!t) return 0;
#if SCHEME == SCH_HP
    hp[tid][0] = t;
    fence();
    if (stack_top != t) {
      ts[tid].retries++;
      continue;
    }
#endif
    (void)t->key;
    return 1;
  }
#endif
}

// ===========================================================================
// hash table: 128 buckets, each a lazy list
// ===========================================================================
static node_t *list_head;
static node_t *buckets[NBUCKETS];
static inline node_t *bucket(int32_t key) {
#if DS == DS_HASH
  return buckets[(uint32_t)key % NBUCKETS];
#else
  (void)key;
  return list_head;
#endif
}

// ===========================================================================
// common operations
// ===========================================================================
static int op_insert(int32_t k, int tid) {
#if DS == DS_BST
  return bst_insert(k, tid);
#elif DS == DS_STACK
  stack_push(k, tid);
  return 1;
#else
  return list_insert(bucket(k), k, tid);
#endif
}
static int op_delete(int32_t k, int tid) {
#if DS == DS_BST
  return bst_delete(k, tid);
#elif DS == DS_STACK
  (void)k;
  return stack_pop(tid);
#else
  return list_delete(bucket(k), k, tid);
#endif
}
static int op_contains(int32_t k, int tid) {
#if DS == DS_BST
  return bst_contains(k, tid);
#elif DS == DS_STACK
  (void)k;
  return stack_peek(tid);
#else
  return list_contains(bucket(k), k, tid);
#endif
}

static void ds_init(void) {
#if DS == DS_BST
  bst_init(0);
#elif DS == DS_STACK
  stack_top = 0;
#elif DS == DS_HASH
  for (int i = 0; i < NBUCKETS; i++) buckets[i] = list_new(0);
#else
  list_head = list_new(0);
#endif
}

// validation: ordered, unmarked, and the expected number of keys
static int32_t bst_count(node_t *n, int32_t *last, int *ok) {
  if (B_FLAGS(n) & F_LEAF) {
    if (n->key >= KEY_MAX - 1) return 0;
    if (n->key <= *last) *ok = 0;
    *last = n->key;
    return 1;
  }
  if (B_FLAGS(n) & (F_MARK | F_LOCK)) *ok = 0;
  return bst_count(B_LEFT(n), last, ok) + bst_count(B_RIGHT(n), last, ok);
}

static int32_t list_count(node_t *h, int *ok) {
  int32_t n = 0, last = KEY_MIN;
  for (node_t *c = h->next; c->key != KEY_MAX; c = c->next) {
    if (c->key <= last || c->mark || c->lock) *ok = 0;
    last = c->key;
    n++;
  }
  return n;
}

static int32_t ds_size(int *ok) {
#if DS == DS_BST
  int32_t last = KEY_MIN;
  return bst_count(bst_root, &last, ok);
#elif DS == DS_STACK
  int32_t n = 0;
  for (node_t *c = stack_top; c; c = c->next) n++;
  (void)ok;
  return n;
#elif DS == DS_HASH
  int32_t n = 0;
  for (int i = 0; i < NBUCKETS; i++) n += list_count(buckets[i], ok);
  return n;
#else
  return list_count(list_head, ok);
#endif
}

// ===========================================================================
// results, in the mailbox (uncached, read by the PS)
// ===========================================================================
struct result {
  uint32_t magic, ds, scheme, upd, nthreads, nops, seed;
  int32_t prefill, final_size, expected_size;
  uint32_t valid, unreclaimed_end, max_unreclaimed, pad[3];
  struct {
    uint32_t cycles, ops, ins_ok, del_ok, found, retries, allocs, frees, removed, pad[7];
  } t[MAXT];
};

static void write_result(volatile uint32_t *dst, const struct result *r) {
  const uint32_t *s = (const uint32_t *)r;
  for (unsigned i = 0; i < sizeof(*r) / 4; i++) dst[i] = s[i];
}

static void barrier(volatile uint32_t *ctr) {
  __atomic_fetch_add(ctr, 1, __ATOMIC_SEQ_CST);
  while (*ctr < NTHREADS);
}

int main(int tid) {
  static int32_t prefill_n;
  if (tid == 0) {
    uint32_t seed = MAILBOX[MB_SEED];
    if (!seed) seed = 12345;
    for (int i = 0; i < MAXT; i++) {
      memset((void *)&ts[i], 0, sizeof(ts[i]));
      ts[i].rnd = seed * 2654435761u + 1013904223u * (i + 1);
      for (int j = 0; j < 4; j++) {
        hp[i][j] = 0;
        q_epoch[i][j] = 0;
      }
    }
    g_epoch = 0;
    ds_init();
    // prefill to half the key range (stack: half of 1K elements)
    int32_t target = KEY_RANGE / 2;
    prefill_n = 0;
    while (prefill_n < target) {
      int32_t k = (int32_t)(rnd(&ts[0]) % KEY_RANGE) + 1;
      if (op_insert(k, 0)) prefill_n++;
    }
    for (int i = 0; i < MAXT; i++) ts[i].allocs = ts[i].frees = ts[i].retries = 0;
    fence();
    sync_start = 1;
  } else {
    while (!sync_start);
  }
  if (tid >= NTHREADS) return 0;

  tstate_t *t = &ts[tid];
  barrier(&sync_arrive);
  uint32_t c0 = rdcycle();
  for (uint32_t i = 0; i < NOPS; i++) {
    uint32_t r = rnd(t);
    int32_t k = (int32_t)((r >> 8) % KEY_RANGE) + 1;
    if (r % 100 < UPD) {
      if (rnd(t) & 1) t->ins_ok += op_insert(k, tid);
      else t->del_ok += op_delete(k, tid);
    } else {
      t->found += op_contains(k, tid);
    }
    t->ops++;
#if SCHEME == SCH_QSBR
    qsbr_quiescent(tid);
#endif
    if (tid == 0 && (i % SAMPLE_EVERY) == SAMPLE_EVERY - 1) {
      uint32_t u = unreclaimed();
      if (u > t->max_unreclaimed) t->max_unreclaimed = u;
    }
  }
  t->cycles = rdcycle() - c0;
#if SCHEME == SCH_HP
  for (int j = 0; j < 4; j++) hp[tid][j] = 0;
#endif
  fence();
  __atomic_fetch_add(&sync_done, 1, __ATOMIC_SEQ_CST);
  if (tid != 0) return 0;
  while (sync_done < NTHREADS);
  fence();

  static struct result res;
  memset(&res, 0, sizeof(res));
  int ok = 1;
  res.magic = 0xCA5EB001u;
  res.ds = DS;
  res.scheme = SCHEME;
  res.upd = UPD;
  res.nthreads = NTHREADS;
  res.nops = NOPS;
  res.seed = MAILBOX[MB_SEED];
  res.prefill = prefill_n;
  res.final_size = ds_size(&ok);
  int32_t exp = prefill_n;
  for (int i = 0; i < NTHREADS; i++) exp += (int32_t)ts[i].ins_ok - (int32_t)ts[i].del_ok;
  res.expected_size = exp;
  res.valid = ok && (res.final_size == exp) && !fatal_code;
  res.unreclaimed_end = unreclaimed();
  res.max_unreclaimed = ts[0].max_unreclaimed;
  for (int i = 0; i < NTHREADS; i++) {
    res.t[i].cycles = ts[i].cycles;
    res.t[i].ops = ts[i].ops;
    res.t[i].ins_ok = ts[i].ins_ok;
    res.t[i].del_ok = ts[i].del_ok;
    res.t[i].found = ts[i].found;
    res.t[i].retries = ts[i].retries;
    res.t[i].allocs = ts[i].allocs;
    res.t[i].frees = ts[i].frees;
    res.t[i].removed = ts[i].removed;
  }
  write_result(&MAILBOX[MB_RESULT], &res);
  fence();
  if (fatal_code) return (fatal_code << 1) | 1;
  return res.valid ? 1 : ((40 + DS) << 1) | 1;
}
