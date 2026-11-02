#!/usr/bin/env python3
"""Turns the KR260 benchmark mailbox dumps into a CSV and Markdown tables.

usage: analyze.py <results.txt> <out dir>
results.txt lines: "<config>:<seed> | RESULT ... | MBOX w16 w17 ..."
Throughput is total operations / slowest thread's cycles at the PL clock.
"""
import csv
import statistics
import sys
from collections import defaultdict

CLOCK_HZ = 49_999_500
DS = {1: "list", 2: "bst", 3: "stack", 4: "hash"}
SCH = {0: "none", 1: "ca", 2: "hp", 3: "qsbr"}
SCHEMES = ["none", "ca", "hp", "qsbr"]
UPDS = [0, 10, 100]


def decode(words):
    w = [int(x) for x in words]
    head = ["magic", "ds", "scheme", "upd", "nthreads", "nops", "seed", "prefill", "final_size",
            "expected_size", "valid", "unreclaimed_end", "max_unreclaimed"]
    r = dict(zip(head, w[:13]))
    r["threads"] = []
    for t in range(2):
        b = 16 + 16 * t
        r["threads"].append(dict(zip(
            ["cycles", "ops", "ins_ok", "del_ok", "found", "retries", "allocs", "frees", "removed"],
            w[b:b + 9])))
    return r


def main():
    src, out = sys.argv[1], sys.argv[2]
    runs = []
    bad = []
    for line in open(src):
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3 or not parts[2].startswith("MBOX"):
            bad.append(line.strip())
            continue
        cfg = parts[0]
        r = decode(parts[2].split()[1:])
        if r["magic"] != 0xCA5EB001 or "PASS" not in parts[1] or not r["valid"]:
            bad.append(line.strip())
            continue
        n = r["nthreads"]
        cyc = max(r["threads"][t]["cycles"] for t in range(n))
        ops = sum(r["threads"][t]["ops"] for t in range(n))
        retries = sum(r["threads"][t]["retries"] for t in range(n))
        removed = sum(r["threads"][t]["removed"] for t in range(n))
        frees = sum(r["threads"][t]["frees"] for t in range(n))
        runs.append(dict(cfg=cfg, ds=DS[r["ds"]], scheme=SCH[r["scheme"]], upd=r["upd"], threads=n,
                         seed=r["seed"], cycles=cyc, ops=ops,
                         mops=ops / (cyc / CLOCK_HZ) / 1e6,
                         cycles_per_op=cyc * n / ops,
                         retries=retries, removed=removed, frees=frees,
                         unreclaimed_end=r["unreclaimed_end"], max_unreclaimed=r["max_unreclaimed"]))

    with open(f"{out}/runs.csv", "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(runs[0].keys()))
        wr.writeheader()
        wr.writerows(runs)

    agg = defaultdict(list)
    for r in runs:
        agg[(r["ds"], r["scheme"], r["upd"], r["threads"])].append(r)

    def mean(key, k):
        v = [r[k] for r in agg.get(key, [])]
        return statistics.mean(v) if v else None

    def spread(key, k):
        v = [r[k] for r in agg.get(key, [])]
        return (max(v) - min(v)) / statistics.mean(v) * 100 if len(v) > 1 and statistics.mean(v) else 0.0

    with open(f"{out}/summary.csv", "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["ds", "scheme", "upd", "threads", "runs", "mops", "mops_spread_pct", "cycles_per_op",
                     "retries", "unreclaimed_end", "max_unreclaimed"])
        for key in sorted(agg):
            wr.writerow([*key, len(agg[key]), f"{mean(key, 'mops'):.4f}", f"{spread(key, 'mops'):.1f}",
                         f"{mean(key, 'cycles_per_op'):.0f}", f"{mean(key, 'retries'):.0f}",
                         f"{mean(key, 'unreclaimed_end'):.0f}", f"{mean(key, 'max_unreclaimed'):.0f}"])

    md = []
    md.append("Throughput in Mops/s (mean of seeds; 50 MHz PL clock). "
              "In brackets: relative to `none`.\n")
    for ds in ["list", "bst", "stack", "hash"]:
        md.append(f"\n#### {ds}\n")
        md.append("| updates | threads | " + " | ".join(SCHEMES) + " |")
        md.append("|---|---|" + "---|" * len(SCHEMES))
        for upd in UPDS:
            for n in (1, 2):
                base = mean((ds, "none", upd, n), "mops")
                cells = []
                for s in SCHEMES:
                    m = mean((ds, s, upd, n), "mops")
                    if m is None:
                        cells.append("-")
                    elif s == "none" or not base:
                        cells.append(f"{m:.3f}")
                    else:
                        cells.append(f"{m:.3f} ({m / base:.2f})")
                md.append(f"| {upd}% | {n} | " + " | ".join(cells) + " |")
    md.append("\n\nUnreclaimed nodes (removed but not yet freed) at the end of the run, "
              "2 threads, 100% updates (mean of seeds):\n")
    md.append("| ds | " + " | ".join(SCHEMES) + " |")
    md.append("|---|" + "---|" * len(SCHEMES))
    for ds in ["list", "bst", "stack", "hash"]:
        cells = [f"{mean((ds, s, 100, 2), 'unreclaimed_end'):.0f}" if mean((ds, s, 100, 2), 'unreclaimed_end') is not None
                 else "-" for s in SCHEMES]
        md.append(f"| {ds} | " + " | ".join(cells) + " |")
    md.append("\n\nCA retries per run (failed CA attempts: revoked access or lost try-lock), "
              "mean of seeds:\n")
    md.append("| ds | updates | 1 thread | 2 threads |")
    md.append("|---|---|---|---|")
    for ds in ["list", "bst", "stack", "hash"]:
        for upd in UPDS:
            c1 = mean((ds, "ca", upd, 1), "retries")
            c2 = mean((ds, "ca", upd, 2), "retries")
            md.append(f"| {ds} | {upd}% | {c1:.0f} | {c2:.0f} |" if c1 is not None and c2 is not None
                      else f"| {ds} | {upd}% | - | - |")
    md.append(f"\n\nRuns used: {len(runs)}; rejected (no result, failed or invalid): {len(bad)}\n")
    for b in bad:
        md.append(f"- rejected: `{b[:160]}`")
    open(f"{out}/tables.md", "w").write("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
