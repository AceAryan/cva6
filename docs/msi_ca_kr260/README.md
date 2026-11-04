# Two-core CVA6 with MSI coherence and conditional access, on the KR260

This folder explains the project in plain terms. Read it in order:

1. [01_overview.md](01_overview.md): what was built and why, the big picture
2. [02_msi_cache.md](02_msi_cache.md): how the two caches stay coherent (MSI)
3. [03_conditional_access.md](03_conditional_access.md): the paper's instructions in hardware
4. [04_kr260.md](04_kr260.md): the FPGA system on the KR260, and the results

## One-paragraph summary
We took the open-source CVA6 RISC-V core and built a two-core system on the AMD KR260 FPGA board.
- **Coherence:** each core has its own write-back data cache, and a new MSI coherence protocol keeps the two caches consistent.
- **Conditional access:** on top of that we implemented the four Conditional Access instructions from Singh, Brown and Spear: `cread`, `cwrite`, `untagOne`, `untagAll`. They let lock-free and optimistic data structures free memory immediately and safely.
- **Verification:** everything was checked in simulation (random testbenches, injected bugs, the standard RISC-V test suite) and then on the board.
- **Benchmarks on the board:** we ran the paper's benchmarks (lazy list, external BST, stack, hash table) against other reclamation schemes and reproduced the paper's main findings.

## Key numbers
| | |
|---|---|
| Cores | 2 × CVA6, 32-bit (RV32IMAC), 50 MHz on the KR260 |
| Caches | 32 KiB write-back L1 data cache per core, 16 KiB instruction cache, 16-byte lines |
| FPGA use | 50% of LUTs, 14% of registers, 51% of block RAM |
| Correctness | 72/73 RISC-V ISA tests on the board (the 1 failure is disabled upstream too), all coherence and CA tests pass, 288/288 benchmark runs valid |
| Main result | CA frees memory immediately (0 unreclaimed nodes) and is fastest under high contention (stack: 1.33× the leaky baseline); it is slower for read-only work because of how the failure flag is read |

## Where the detailed logs are
`~/logs/phase1` … `~/logs/phase5` (one `PHASE*_SUMMARY.md` or `BENCHMARK_SUMMARY.md` each).
