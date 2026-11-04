# 3. Conditional access (CA) in hardware

## The idea in one sentence
A thread **tags** the cache lines it reads with `cread`. If any other core writes one of those lines, or the line leaves the cache, the thread's **accessRevokedBit** is set. Its next `cread`/`cwrite` then fails, so it never acts on data that may already have been freed.

The coherence protocol already tells a cache when another core takes a line away (the GetM snoop). CA just listens to that signal.

## The four instructions (as in the paper)
| Instruction | Encoding | What it does |
|---|---|---|
| `cread rd, imm(rs1)` | custom-0, funct3 000 | tag the line, then load if access is not revoked; on failure return 0 and set CAFAIL |
| `cwrite rs2, imm(rs1)` | custom-0, funct3 001 | store only if the line is tagged and access is not revoked; check and store are one atomic step; on failure store nothing and set CAFAIL |
| `untagOne rs1` | custom-1, funct3 000 | stop watching one line |
| `untagAll` | custom-1, funct3 001 | stop watching everything; clear accessRevokedBit and CAFAIL |

**Reading the result.** RISC-V has no flags register, so failure is read from a new read-only CSR at **0xCC0**:
- bit 0 = CAFAIL
- bit 1 = accessRevokedBit

Software checks with `csrr t0, 0xCC0; andi t0, t0, 1; bnez t0, retry`.

**What revokes access:**
- another core's write to a tagged line (GetM snoop)
- evicting or flushing a tagged line
- more than 8 lines tagged
- a trap or interrupt while lines are tagged

A remote **read** does not revoke, as in the paper.

## How it fits the pipeline
CVA6 runs loads *speculatively*, before it knows that an earlier branch or exception will not cancel them. CA state must only change for instructions that really execute, so:
- **Two-step update:** `cread`, `untagOne` and `untagAll` are first *recorded* in a small table (`ca_tag_set.sv`) when the cache sees them. They *take effect* when the instruction commits. Cancelled ones leave no trace.
- **`cwrite` runs at commit, like an atomic instruction.** It waits until it is the oldest instruction and earlier stores are drained. The cache then holds the line in M and no snoop can arrive. In that state it checks the tag and does the store in the same step. This is what makes `cwrite` atomic: nothing can sneak in between the check and the write.
- **Two ordering rules the paper does not need**, because it does not model a speculative pipeline:
  - While an `untagAll` is waiting to commit, no new CA instruction is accepted. Otherwise the typical retry loop `untagAll; cread` would see the old revoked bit forever.
  - A `cread` also fails if an older `cread` that has not committed yet already lost its line. Otherwise it could read from a node that is being freed.

## What was fixed in the original implementation
The branch already had these instructions for the write-through cache, but not with the paper's semantics:
- A failing `cread` still loaded the data, and returned the failure by overwriting bit 0 of that data.
- `cwrite` decided success early and stored later, so it was not atomic. Its result was also invisible to software, and a decoder bug made it overwrite a register when it had an immediate offset.
- The untag instructions performed a real memory load.

## How it was verified
- **Reference model of the paper's rules** in the two-cache testbench. It checks after every operation:
  1. A successful `cread`/`cwrite` means no tagged line was taken by the other core since tagging.
  2. A failed `cwrite` wrote nothing.
  3. Values read are correct.
  4. CAFAIL behaves as specified.
- **No spurious failures:** in random runs, a failure without a cause is an error.
- **11 directed tests**, one per rule, for example: remote read does not revoke, untagOne, overflow, eviction, trap, and squashed cread.
- **Results:** 400/400 random runs pass, and all 11 injected CA bugs are caught.
- **Full system on the board:**
  - Hart 1 frees and reuses nodes while hart 0 reads them with `cread`. A successful `cread` never saw a freed node.
  - The paper's `cread`/`cwrite` try-lock protects a counter correctly.
  - The **same programs with plain loads/stores fail**: they read freed nodes and break the lock. This shows the tests really detect what CA prevents.

## Source
| File | Role |
|---|---|
| `core/cache_subsystem/ca_tag_set.sv` | tagSet (8 lines), pending table, accessRevokedBit, CAFAIL |
| `core/cache_subsystem/cache_ctrl.sv` | `cread`/untag handling on the load port |
| `core/cache_subsystem/miss_handler.sv` | `cwrite` at commit (`AMO_CWRITE`), revocation on snoop/eviction |
| `core/decoder.sv`, `store_unit.sv`, `commit_stage.sv` | decode; cwrite through the atomic path |
| `core/csr_regfile.sv` | CSR 0xCC0 |
| `verif/tests/custom/ca_2core/ca_2core.S` | the full-system CA test |
