# 1. Overview: what was built

## The goal
The paper *Efficient Hardware Primitives for Immediate Memory Reclamation in Optimistic Data Structures* (Singh, Brown, Spear) proposes **Conditional Access (CA)**.
- **The problem:** in concurrent data structures, a thread may still be reading a node that another thread has just removed. Freeing that node at once is unsafe, so today's software schemes (hazard pointers, epochs) delay the free.
- **CA's idea:** use the hardware cache-coherence protocol to *detect* when such a node is touched by another core. A reader then learns its reads are no longer safe, and the remover can free memory immediately.
- **What we needed:** the paper evaluated CA in a simulator. We needed a real system: a multicore CPU with private caches, a coherence protocol, and the CA instructions, running on an FPGA.

## What we built, layer by layer

```
   +---------------- KR260 FPGA (PL) ------------------+      +--- ARM side (PS) ---+
   |                                                   |      |                     |
   |  CVA6 core 0            CVA6 core 1               |      |  DDR memory         |
   |  +-----------+          +-----------+             |      |  JTAG / control     |
   |  | pipeline  |          | pipeline  |             |      |                     |
   |  | CA unit   |          | CA unit   |  <- layer 3 |      |                     |
   |  | L1 D$ MSI |<-snoop-->| L1 D$ MSI |  <- layer 1 |      |                     |
   |  +-----+-----+          +-----+-----+             |      |                     |
   |        |   coherence bus (cc_bus)  |  <- layer 2  |      |                     |
   |        +------------+-------------+               |      |                     |
   |               memory port (AXI) ------------------+----->|  DDR                |
   |               mailbox (results) <-----------------+------|  read by PC         |
   +---------------------------------------------------+      +---------------------+
```

| Layer | What it does | Explained in |
|---|---|---|
| 1. MSI L1 cache | Each line is Modified, Shared or Invalid. A cache answers "snoops" from the other core. | [02_msi_cache.md](02_msi_cache.md) |
| 2. Coherence bus | Lets one core at a time do a memory transaction. It first asks the other cache to give up or downgrade the line. | [02_msi_cache.md](02_msi_cache.md) |
| 3. Conditional access | `cread`/`cwrite`/`untagOne`/`untagAll`, plus a failure flag in a CSR | [03_conditional_access.md](03_conditional_access.md) |
| 4. KR260 system | Puts both cores on the FPGA, connects them to the board's DDR, loads programs over USB/JTAG | [04_kr260.md](04_kr260.md) |

## Starting point and main design decisions
- **Base core:** CVA6 (OpenHW Group), a 6-stage in-order RISC-V core. We use the 32-bit configuration RV32IMAC. The new config is `cv32a6_imac_sv32_wb`.
- **Which cache to extend:** CVA6 has a write-through cache and a write-back cache. We built MSI on the **write-back** cache (`std_nbdcache`), because MSI needs "dirty" lines that are owned by one core.
- **A simple bus:** the bus handles one transaction at a time. This makes the protocol easy to reason about and to prove deadlock-free. It is enough for 2 cores.
- **Atomics run inside the cache:** AMOs and LR/SC execute in the L1 while it owns the line. `cwrite` uses the same path, which makes it truly atomic.
- **Failure reporting:** CA failure is reported through a CSR at 0xCC0, because RISC-V has no flags register.

## How it was checked, in order
1. **Unit testbenches** for one cache, then two caches with the bus. Each is a random test with a reference model, run over hundreds of seeds. Bugs were deliberately injected to confirm that the tests catch them.
2. **Full-core simulation** of the real CPU running RISC-V programs: the standard ISA tests, plus our own two-core programs.
3. **The same RTL on the KR260.** Every test gives the same result as in simulation.
4. **The paper's benchmarks on the board.**

## Source locations
| Area | Files |
|---|---|
| MSI cache | `core/cache_subsystem/miss_handler.sv`, `cache_ctrl.sv`, `std_nbdcache.sv`, `cc_bus.sv` |
| Conditional access | `core/cache_subsystem/ca_tag_set.sv`; decoder, store/commit and CSR changes in `core/` |
| KR260 | `corev_apu/fpga/kr260/` |
| Tests | `core/cache_subsystem/test/`, `verif/tests/custom/msi_2core/`, `verif/tests/custom/ca_2core/` |
| Benchmarks | `corev_apu/fpga/kr260/sw/bench/` |
