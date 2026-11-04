# 2. The MSI coherence protocol

## Why coherence is needed
Each core has a private L1 data cache. If core 0 writes address X, core 1 might still have an old copy of X in its cache. A coherence protocol makes sure every read sees the latest write, and that two cores never hold conflicting copies.

## The three states of a cache line
| State | Meaning | This core may read | This core may write |
|---|---|---|---|
| **M** (Modified) | This cache has the only valid copy, possibly newer than memory | yes | yes |
| **S** (Shared) | A clean copy; other caches may have one too | yes | no (must upgrade to M first) |
| **I** (Invalid) | Not in this cache | no (miss) | no (miss) |

**How it is stored:** CVA6 already kept `valid` and `dirty` bits per line. We added one bit, `owned`.

| State | valid | owned |
|---|---|---|
| I | 0 | (don't care) |
| S | 1 | 0 |
| M | 1 | 1 |

`dirty` says whether an M line must be written back to memory.

**The rule the design guarantees:** a line is M in at most one cache, and then it is I in the other.

## Requests on the bus
| Request | Sent when | Effect on the other cache |
|---|---|---|
| **GetS** (get shared) | load miss | if it had the line in M: write it back, M → S |
| **GetM** (get modified) | store miss, store to an S line, AMO, cwrite | write it back if dirty, then → I |
| **PutM** (put modified) | writing back a dirty line during a flush | nothing to snoop |

## State changes in one picture
```
          own load miss (GetS)            own store (GetM)
   I  --------------------------->  S  -------------------->  M
   ^                                |                          |
   |      other core's GetM         |   other core's GetS      |
   +--------------------------------+   (write back) M -> S <--+
   ^                                                           |
   +-------------- other core's GetM (write back) -------------+
```
Evicting a line: S simply drops to I. A dirty M is written back first.

## The coherence bus (`cc_bus.sv`)
- **One request at a time:** a cache must get the bus (a *tenure*) before it touches memory for a cacheable line. The bus serves one tenure at a time and alternates fairly between the cores.
- **How a tenure runs:**
  1. A cache asks for the bus with GetS, GetM or PutM.
  2. The bus sends that request as a **snoop** to the other cache.
  3. The other cache looks the line up and, if needed, writes dirty data back to memory. It answers "done" only after memory has confirmed the write.
  4. The bus grants the requester, which now reads memory knowing it holds the newest data.
  5. The requester signals "done", and the bus moves on.
- **No data between caches:** because of step 3, memory is always up to date before anyone reads it, so caches never send data to each other directly.

## Why it cannot deadlock
**Key rule: a cache can always answer a snoop without needing the bus.** Snoops are only accepted while the cache is idle or waiting for the bus, never in the middle of its own memory operation. So even when both cores want the bus at once, the one being snooped can always finish the snoop, and the bus can always make progress.

## Races handled (and tested)
| Race | Fix |
|---|---|
| A snoop arrives while our own miss to the same line waits for the bus | the miss re-reads the tags after it gets the bus |
| A store is between its tag look-up and its write when a snoop takes the line | stores to that set are held off while a snoop is in progress |
| Store to an S line: old S copy still valid while the upgrade is in flight (found by our testbench) | loads may not hit a line the miss unit is fetching |
| Two cores spinning on LR/SC kill each other's reservation forever, a livelock (found by our testbench) | after an LR, the cache keeps the bus for up to 64 cycles so its SC can succeed |
| Two cores' memory ports formed a combinational loop on the FPGA | a register slice per core |

## Atomics (AMO, LR/SC)
Atomic instructions such as `amoadd` used to bypass the cache, which would be wrong with two caches. Now they run inside the L1:
1. Get the line in M (GetM tenure).
2. Do the read-modify-write in one cycle.
3. Release the bus.

**LR/SC:** LR records a reservation. Any snoop or eviction of that line clears it, and SC succeeds only if the reservation is still there.

## How it was verified
- **Single-cache testbench:** random loads, stores and snoops against a reference memory model.
  - 300/300 seeds pass.
  - 9 deliberately injected bugs were all caught.
- **Two-cache testbench** with the real bus. Each cycle, every line used is checked for "M in at most one cache".
  - Loads are checked against the history of written values.
  - AMOs must be exact, and two AMOs on a counter may never return the same old value.
  - Fairness and timeout watchdogs catch deadlock and livelock.
  - 400/400 runs pass, and 6 of 7 injected bugs are caught. The 7th cannot change behaviour with two caches.
- **Full CPU:**
  - 72/73 standard RISC-V ISA tests pass, including all 10 atomic-instruction tests.
  - A two-core program checks counters, ping-pong, false sharing and message passing.
  - It passes in simulation and on the board.

## Source
| File | Role |
|---|---|
| `core/cache_subsystem/miss_handler.sv` | misses, write-backs, snoop handling, AMOs, LR/SC, cwrite |
| `core/cache_subsystem/cache_ctrl.sv` | per-port hit/miss logic; a store to S becomes a miss |
| `core/cache_subsystem/std_nbdcache.sv` | the cache; status array with the `owned` bit |
| `core/cache_subsystem/cc_bus.sv` | the coherence bus |
