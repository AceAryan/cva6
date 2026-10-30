PROJECT CONTEXT
I am implementing hardware primitives from the paper "Efficient Hardware
Primitives for Immediate Memory Reclamation in Optimistic Data Structures"
(Singh, Brown, Spear) on top of the CVA6 RISC-V core, for my advisor's
research. Target hardware is the AMD/Xilinx Kria KR260. End goal: a 2-core
CVA6 system with private L1 caches, a custom MSI-based cache coherence
protocol between the two cores, and conditional-access (CA) memory
reclamation primitives layered on top of that coherence fabric.

This is a from-scratch architectural modification of CVA6, not a toy
exercise — treat correctness of the coherence protocol (no stale reads,
no lost invalidations, no deadlock) as the top priority at every phase.

GROUND RULES (apply to every phase, no exceptions)
- Never commit, push, or change git config. Never add a Co-authored-by
  trailer to anything.
- All logs go under ~/logs.

PHASE 0 — Orientation (read-only)
1. Inspect the CVA6 repo structure on the working branch: locate the L1
   data/instruction cache RTL, the memory-side interconnect / AXI
   crossbar, and anywhere a second core or multi-core config is
   referenced or stubbed.
2. Summarize, in plain terms: how CVA6 currently handles cache-to-memory
   traffic in single-core config, what bus/interconnect protocol it
   speaks (AXI likely), and what would need to change to add a second
   core and inter-cache snooping.
3. Produce a short written plan (not code) for how MSI will be bolted on:
   per-cache-line state bits (M/S/I), what triggers a transition, what
   the snoop/broadcast or request path looks like between the two L1s,
   and where this logic physically sits (inside each cache controller,
   or a small shared arbiter/bus between the two).
4. Stop here and show me the plan before writing any RTL.

PHASE 1 — Single-core snoop port (smallest correct unit)
Goal: get ONE CVA6 core's L1 cache controller exposing a snoop
interface (respond to external invalidate/read-shared requests) without
yet wiring a second core to it.
- Add the snoop port RTL and the per-line MSI state bits to the single
  core's L1 controller.
- Write a minimal testbench that drives synthetic snoop requests
  (invalidate, read-for-ownership) at the port and checks the cache
  line state transitions correctly (M→I, S→I, etc.) and that dirty
  data is written back correctly on eviction/invalidate.
- Do not touch the second core or the inter-core bus yet.
- Report simulation results and stop for review before Phase 2.

PHASE 2 — MSI protocol + inter-core bus
Goal: connect two instances of the modified core via a minimal bus/
arbiter that carries MSI requests (GetS, GetM, Inv) and responses.
- Decide and document: broadcast-snoop bus vs. simple point-to-point
  link for a 2-core system (broadcast is simpler and sufficient for
  N=2 — confirm this is the direction before building).
  - Only pursue a directory structure if we explicitly decide we need it; for 2 cores, broadcast MSI is the default and simpler choice.
- Implement the bus/arbiter RTL connecting both cores' snoop ports.
- Extend the testbench to a 2-core scenario: core A writes a line
  (goes to M), core B reads it (forces A to writeback+downgrade to S,
  or forces I depending on the exact protocol you choose), core B
  writes it (forces A to I). Verify data correctness and state
  correctness at every step.
- Explicitly test and report on: deadlock/livelock scenarios (both
  cores requesting ownership of the same line simultaneously), and
  write-write races.
- Stop for review before Phase 3.

PHASE 3 — Conditional-access primitives on top of MSI
Goal: implement the CA hardware primitives from the paper, using the
now-working MSI coherence substrate as the base mechanism they need
(e.g. detecting concurrent access to a memory region being reclaimed).
- Re-read the relevant sections of the paper (I'll provide/confirm
  which primitives are in scope — don't assume all of them).
- Map each required primitive to where it hooks into the MSI
  controller / cache line state machine.
- Implement incrementally, one primitive at a time, with a targeted
  testbench per primitive before moving to the next.

PHASE 4 — KR260 bring-up
Goal: get the 2-core CVA6 + MSI + CA design running on real KR260
hardware (not just simulation).
- Confirm toolchain/build flow for CVA6 on KR260 (Vivado/PetaLinux or
  whatever the existing baseline uses) before changing anything.
- Build the 2-core bitstream, document resource utilization
  (LUTs/FFs/BRAM) relative to the KR260's available fabric, and flag
  if we're close to capacity.
- Define a minimal hardware test (e.g. a small concurrent
  producer/consumer or lock-free data structure workload) that
  exercises both the MSI protocol and the CA primitives, and run it
  on-board.
- Report pass/fail and any divergence from simulation behavior.

DELIVERABLES PER PHASE
- A short written summary of what changed and why.
- Simulation/test logs (saved under ~/logs) showing correctness.
- An explicit list of open questions or design decisions that need my
  input before the next phase starts.

Start with Phase 0 only. Do not proceed to Phase 1 until I confirm the
Phase 0 plan.