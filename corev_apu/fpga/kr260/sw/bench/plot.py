#!/usr/bin/env python3
"""Plots for the KR260 benchmark results, as standalone SVG (no dependencies).

usage: plot.py <phase5 dir>
reads  <dir>/summary.csv (from analyze.py) and <dir>/micro_raw.txt
writes <dir>/plots/*.svg and <dir>/plots/index.html (charts + data tables)
Hovering a bar shows its exact value (SVG <title>).
"""
import csv
import html
import math
import re
import sys

# palette: validated categorical slots 1-4 (light surface), chart chrome
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SCHEME_COLOR = {"none": "#2a78d6", "ca": "#eb6834", "hp": "#1baf7a", "qsbr": "#eda100"}
SCHEME_LABEL = {"none": "none (leaky)", "ca": "ca (conditional access)", "hp": "hp (hazard pointers)",
                "qsbr": "qsbr (epochs)"}
SCHEMES = ["none", "ca", "hp", "qsbr"]
DS_LABEL = {"list": "Lazy list (1K keys)", "bst": "External BST (10K keys)", "stack": "Treiber stack",
            "hash": "Hash table (128 buckets)"}
DSS = ["list", "bst", "stack", "hash"]
FONT = 'system-ui, -apple-system, "Segoe UI", sans-serif'
BAR_W = 14
GAP = 2


def esc(s):
    return html.escape(str(s), quote=True)


def nice_ticks(vmax, n=5):
    if vmax <= 0:
        return [0, 1]
    raw = vmax / n
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    top = math.ceil(vmax / step) * step
    ticks, v = [], 0.0
    while v <= top + step * 1e-9:
        ticks.append(round(v, 10))
        v += step
    return ticks


def fmt(v):
    if v == 0:
        return "0"
    if abs(v) >= 100:
        return f"{v:.0f}"
    if abs(v) >= 10:
        return f"{v:.1f}"
    if abs(v) >= 1:
        return f"{v:.2f}"
    return f"{v:.3f}"


def column(x, y0, w, h, color, title):
    """A column from baseline y0 up by h, 4px rounded top, square at the baseline."""
    if h <= 0.5:
        return f'<rect x="{x:.1f}" y="{y0 - 1:.1f}" width="{w}" height="1" fill="{color}"><title>{esc(title)}</title></rect>'
    r = min(4, h, w / 2)
    y = y0 - h
    d = (f"M{x:.1f},{y0:.1f} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} H{x + w - r:.1f} "
         f"Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f} V{y0:.1f} Z")
    return f'<path d="{d}" fill="{color}"><title>{esc(title)}</title></path>'


def hbar(x0, y, w, h, color, title):
    """A bar from the left baseline x0, 4px rounded tip, square at the baseline."""
    r = min(4, w, h / 2)
    x = x0 + w
    d = (f"M{x0:.1f},{y:.1f} H{x - r:.1f} Q{x:.1f},{y:.1f} {x:.1f},{y + r:.1f} V{y + h - r:.1f} "
         f"Q{x:.1f},{y + h:.1f} {x - r:.1f},{y + h:.1f} H{x0:.1f} Z")
    return f'<path d="{d}" fill="{color}"><title>{esc(title)}</title></path>'


def svg_open(w, h, title, desc):
    return [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'role="img" aria-labelledby="t d" font-family=\'{FONT}\'>',
            f'<title id="t">{esc(title)}</title><desc id="d">{esc(desc)}</desc>',
            f'<rect width="{w}" height="{h}" fill="{SURFACE}"/>']


def legend(x, y, schemes):
    out = []
    for s in schemes:
        out.append(f'<rect x="{x}" y="{y - 9}" width="10" height="10" rx="2" fill="{SCHEME_COLOR[s]}"/>')
        out.append(f'<text x="{x + 15}" y="{y}" font-size="12" fill="{INK2}">{esc(SCHEME_LABEL[s])}</text>')
        x += 15 + 7 * len(SCHEME_LABEL[s]) + 18
    return out


def tick_fmt(ticks):
    step = ticks[1] - ticks[0] if len(ticks) > 1 else 1
    dec = max(0, -math.floor(math.log10(step) + 1e-9)) if step < 1 else 0
    if step < 1 and round(step * 10 ** dec) % 1 != 0:
        dec += 1
    dec = min(dec + (1 if step in (0.25, 2.5) else 0), 3)
    return lambda v: f"{v:.{dec}f}"


def y_axis(out, left, right, top, bottom, ticks, scale, label):
    tf = tick_fmt(ticks)
    for t in ticks:
        y = bottom - t * scale
        out.append(f'<line x1="{left}" x2="{right}" y1="{y:.1f}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
        out.append(f'<text x="{left - 6}" y="{y + 4:.1f}" font-size="11" fill="{MUTED}" text-anchor="end" '
                   f'style="font-variant-numeric: tabular-nums">{tf(t)}</text>')
    out.append(f'<line x1="{left}" x2="{right}" y1="{bottom}" y2="{bottom}" stroke="{AXIS}" stroke-width="1"/>')
    lx = left - 52
    out.append(f'<text x="{lx}" y="{(top + bottom) / 2:.1f}" font-size="11" fill="{INK2}" '
               f'text-anchor="middle" transform="rotate(-90 {lx} {(top + bottom) / 2:.1f})">{esc(label)}</text>')


# ---------------------------------------------------------------------------
def throughput_chart(rows, ds):
    groups = [(u, t) for u in (0, 10, 100) for t in (1, 2)]
    data = {(r["scheme"], int(r["upd"]), int(r["threads"])): float(r["mops"]) for r in rows if r["ds"] == ds}
    vmax = max(data.values())
    ticks = nice_ticks(vmax)
    W, H = 760, 340
    left, right, top, bottom = 76, W - 20, 82, H - 56
    scale = (bottom - top) / ticks[-1]
    out = svg_open(W, H, f"{DS_LABEL[ds]}: throughput",
                   f"Throughput in million operations per second for each reclamation scheme, "
                   f"at 0, 10 and 100 percent updates, with 1 and 2 threads, on the KR260 at 50 MHz.")
    out.append(f'<text x="20" y="26" font-size="16" font-weight="600" fill="{INK}">{esc(DS_LABEL[ds])}: throughput</text>')
    out.append(f'<text x="20" y="44" font-size="12" fill="{INK2}">Million operations per second, mean of 3 seeds, '
               f'KR260 at 50 MHz. Higher is better.</text>')
    out += legend(20, 66, SCHEMES)
    y_axis(out, left, right, top, bottom, ticks, scale, "Mops/s")
    slot = (right - left) / len(groups)
    gw = len(SCHEMES) * BAR_W + (len(SCHEMES) - 1) * GAP
    for gi, (u, t) in enumerate(groups):
        gx = left + gi * slot + (slot - gw) / 2
        for si, s in enumerate(SCHEMES):
            v = data.get((s, u, t), 0.0)
            base = data.get(("none", u, t), 0.0)
            rel = f" ({v / base:.2f}x none)" if base and s != "none" else ""
            out.append(column(gx + si * (BAR_W + GAP), bottom, BAR_W, v * scale, SCHEME_COLOR[s],
                              f"{SCHEME_LABEL[s]}, {u}% updates, {t} thread{'s' if t > 1 else ''}: {fmt(v)} Mops/s{rel}"))
        cx = left + gi * slot + slot / 2
        out.append(f'<text x="{cx:.1f}" y="{bottom + 17}" font-size="11" fill="{INK2}" text-anchor="middle">'
                   f'{u}% upd</text>')
        out.append(f'<text x="{cx:.1f}" y="{bottom + 31}" font-size="11" fill="{MUTED}" text-anchor="middle">'
                   f'{t} thread{"s" if t > 1 else ""}</text>')
    out.append("</svg>")
    return "\n".join(out)


def relative_chart(rows):
    data = {(r["ds"], r["scheme"], int(r["upd"]), int(r["threads"])): float(r["mops"]) for r in rows}
    schemes = ["ca", "hp", "qsbr"]
    rel = {}
    for ds in DSS:
        for u in (0, 10, 100):
            base = data[(ds, "none", u, 2)]
            for s in schemes:
                rel[(ds, s, u)] = data[(ds, s, u, 2)] / base
    ticks = nice_ticks(max(rel.values()), 4)
    W, H = 980, 384
    top, bottom = 108, H - 46
    pw = (W - 100) / len(DSS)
    scale = (bottom - top) / ticks[-1]
    out = svg_open(W, H, "Throughput relative to the leaky baseline, 2 threads",
                   "For each data structure and update rate, the throughput of ca, hp and qsbr divided by "
                   "the throughput of none, with 2 threads. A value above 1 is faster than none.")
    out.append(f'<text x="20" y="26" font-size="16" font-weight="600" fill="{INK}">Throughput relative to none '
               f'(leaky), 2 threads</text>')
    out.append(f'<text x="20" y="44" font-size="12" fill="{INK2}">Each scheme divided by none for the same workload; '
               f'the line marks none = 1.0. Above the line is faster than leaking memory.</text>')
    out += legend(20, 68, schemes)
    gw = len(schemes) * BAR_W + (len(schemes) - 1) * GAP
    for pi, ds in enumerate(DSS):
        left = 80 + pi * pw
        right = left + pw - 24
        if pi == 0:
            y_axis(out, left, right, top, bottom, ticks, scale, "relative to none")
        else:
            for t in ticks:
                y = bottom - t * scale
                out.append(f'<line x1="{left}" x2="{right}" y1="{y:.1f}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
            out.append(f'<line x1="{left}" x2="{right}" y1="{bottom}" y2="{bottom}" stroke="{AXIS}" stroke-width="1"/>')
        out.append(f'<text x="{(left + right) / 2:.1f}" y="{top - 12}" font-size="12" font-weight="600" fill="{INK}" '
                   f'text-anchor="middle">{esc(ds)}</text>')
        slot = (right - left) / 3
        for gi, u in enumerate((0, 10, 100)):
            gx = left + gi * slot + (slot - gw) / 2
            for si, s in enumerate(schemes):
                v = rel[(ds, s, u)]
                out.append(column(gx + si * (BAR_W + GAP), bottom, BAR_W, v * scale, SCHEME_COLOR[s],
                                  f"{ds}, {SCHEME_LABEL[s]}, {u}% updates, 2 threads: {v:.2f}x none"))
            out.append(f'<text x="{left + gi * slot + slot / 2:.1f}" y="{bottom + 17}" font-size="11" fill="{INK2}" '
                       f'text-anchor="middle">{u}% upd</text>')
        y1 = bottom - 1.0 * scale
        out.append(f'<line x1="{left}" x2="{right}" y1="{y1:.1f}" y2="{y1:.1f}" stroke="{INK2}" stroke-width="1.5"/>')
    out.append(f'<text x="{W - 20}" y="{bottom - 1.0 * scale - 5:.1f}" font-size="11" fill="{INK2}" '
               f'text-anchor="end">none = 1.0</text>')
    out.append("</svg>")
    return "\n".join(out)


def unreclaimed_chart(rows):
    data = {(r["ds"], r["scheme"]): float(r["unreclaimed_end"]) for r in rows
            if int(r["upd"]) == 100 and int(r["threads"]) == 2}
    ticks = nice_ticks(max(data.values()))
    W, H = 760, 340
    left, right, top, bottom = 76, W - 20, 82, H - 46
    scale = (bottom - top) / ticks[-1]
    out = svg_open(W, H, "Removed but not yet freed nodes",
                   "Nodes removed from the data structure but not yet freed, at the end of a run with 2 threads "
                   "and 100 percent updates. ca frees immediately and has none.")
    out.append(f'<text x="20" y="26" font-size="16" font-weight="600" fill="{INK}">Removed but not yet freed nodes</text>')
    out.append(f'<text x="20" y="44" font-size="12" fill="{INK2}">End of run, 2 threads, 100% updates, mean of 3 seeds. '
               f'Lower is better; ca frees each node right after unlinking it.</text>')
    out += legend(20, 66, SCHEMES)
    y_axis(out, left, right, top, bottom, ticks, scale, "nodes")
    slot = (right - left) / len(DSS)
    bw = 22
    gw = len(SCHEMES) * bw + (len(SCHEMES) - 1) * GAP
    for gi, ds in enumerate(DSS):
        gx = left + gi * slot + (slot - gw) / 2
        for si, s in enumerate(SCHEMES):
            v = data[(ds, s)]
            x = gx + si * (bw + GAP)
            out.append(column(x, bottom, bw, v * scale, SCHEME_COLOR[s], f"{ds}, {SCHEME_LABEL[s]}: {v:.0f} nodes"))
            out.append(f'<text x="{x + bw / 2:.1f}" y="{bottom - v * scale - 5:.1f}" font-size="10" fill="{INK2}" '
                       f'text-anchor="middle" style="font-variant-numeric: tabular-nums">{v:.0f}</text>')
        out.append(f'<text x="{left + gi * slot + slot / 2:.1f}" y="{bottom + 17}" font-size="11" fill="{INK2}" '
                   f'text-anchor="middle">{esc(ds)}</text>')
    out.append("</svg>")
    return "\n".join(out)


MICRO_NAMES = ["plain load (hit)", "cread (hit)", "cread + CAFAIL check (csrr, andi)", "csrr 0xCC0 alone",
               "untagOne", "untagAll", "plain store", "cread + cwrite (try-lock pattern)",
               "amoswap.w (in-L1 AMO)", "lr.w + sc.w", "fence rw,rw"]


def micro_chart(path):
    w = [int(x) for x in re.search(r"MBOX (.*)", open(path).read()).group(1).split()]
    vals = [(n, w[2 + 2 * i] / 100) for i, n in enumerate(MICRO_NAMES)]
    vals.sort(key=lambda t: t[1])
    W = 760
    row, top = 26, 70
    H = top + row * len(vals) + 30
    left, right = 250, W - 60
    vmax = max(v for _, v in vals)
    ticks = nice_ticks(vmax)
    scale = (right - left) / ticks[-1]
    tf = tick_fmt(ticks)
    out = svg_open(W, H, "Cost of the primitives",
                   "Cycles per instruction or instruction pair, one core, all accesses hitting the L1.")
    out.append(f'<text x="20" y="26" font-size="16" font-weight="600" fill="{INK}">Cost of the primitives</text>')
    out.append(f'<text x="20" y="44" font-size="12" fill="{INK2}">Cycles per operation, one core, L1 hits. '
               f'The CAFAIL check after a cread is what makes CA reads expensive.</text>')
    bottom = top + row * len(vals)
    for t in ticks:
        x = left + t * scale
        out.append(f'<line x1="{x:.1f}" x2="{x:.1f}" y1="{top - 6}" y2="{bottom}" stroke="{GRID}" stroke-width="1"/>')
        out.append(f'<text x="{x:.1f}" y="{bottom + 16}" font-size="11" fill="{MUTED}" text-anchor="middle" '
                   f'style="font-variant-numeric: tabular-nums">{tf(t)}</text>')
    out.append(f'<line x1="{left}" x2="{left}" y1="{top - 6}" y2="{bottom}" stroke="{AXIS}" stroke-width="1"/>')
    for i, (n, v) in enumerate(vals):
        y = top + i * row
        out.append(f'<text x="{left - 8}" y="{y + 13}" font-size="12" fill="{INK2}" text-anchor="end">{esc(n)}</text>')
        if v > 0.05:
            out.append(hbar(left, y + 3, v * scale, 14, SCHEME_COLOR["none"], f"{n}: {v:.2f} cycles"))
        out.append(f'<text x="{left + v * scale + 6:.1f}" y="{y + 14}" font-size="11" fill="{INK}" '
                   f'style="font-variant-numeric: tabular-nums">{v:.1f}</text>')
    out.append("</svg>")
    return "\n".join(out)


def table_html(rows):
    out = ['<table><thead><tr><th>ds</th><th>updates</th><th>threads</th>'
           + "".join(f"<th>{s} Mops/s</th>" for s in SCHEMES) + "</tr></thead><tbody>"]
    data = {(r["ds"], r["scheme"], int(r["upd"]), int(r["threads"])): r for r in rows}
    for ds in DSS:
        for u in (0, 10, 100):
            for t in (1, 2):
                cells = "".join(f"<td>{float(data[(ds, s, u, t)]['mops']):.3f}</td>" for s in SCHEMES)
                out.append(f"<tr><td>{ds}</td><td>{u}%</td><td>{t}</td>{cells}</tr>")
    out.append("</tbody></table>")
    out.append('<table><thead><tr><th>ds</th>' + "".join(f"<th>{s} unreclaimed</th>" for s in SCHEMES)
               + "</tr></thead><tbody>")
    for ds in DSS:
        cells = "".join(f"<td>{float(data[(ds, s, 100, 2)]['unreclaimed_end']):.0f}</td>" for s in SCHEMES)
        out.append(f"<tr><td>{ds}</td>{cells}</tr>")
    out.append("</tbody></table>")
    return "\n".join(out)


def main():
    d = sys.argv[1]
    rows = list(csv.DictReader(open(f"{d}/summary.csv")))
    import os
    os.makedirs(f"{d}/plots", exist_ok=True)
    files = []
    for ds in DSS:
        files.append((f"throughput_{ds}.svg", throughput_chart(rows, ds)))
    files.append(("relative_to_none_2threads.svg", relative_chart(rows)))
    files.append(("unreclaimed_nodes.svg", unreclaimed_chart(rows)))
    files.append(("primitive_costs.svg", micro_chart(f"{d}/micro_raw.txt")))
    for name, svg in files:
        open(f"{d}/plots/{name}", "w").write(svg)
    page = [f"<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' "
            f"content='width=device-width, initial-scale=1'><title>KR260 CA benchmarks</title><style>"
            f"body{{background:#f9f9f7;color:{INK};font-family:{FONT};margin:0;padding:16px;max-width:1000px}}"
            f"img{{max-width:100%;height:auto;display:block;margin:12px 0 28px;border:1px solid rgba(11,11,11,0.10);"
            f"border-radius:8px}} table{{border-collapse:collapse;margin:8px 0 24px;font-size:13px;"
            f"font-variant-numeric:tabular-nums}} th,td{{padding:4px 10px;border-bottom:1px solid {GRID};"
            f"text-align:right}} th:first-child,td:first-child{{text-align:left}} p{{color:{INK2}}}</style></head><body>",
            "<h1>Conditional access benchmarks on the KR260</h1>",
            "<p>Two CVA6 cores, MSI-coherent L1s, 50 MHz. Hover a bar for its value. Data tables follow the charts.</p>"]
    for name, _ in files:
        page.append(f'<img src="{name}" alt="{esc(name)}">')
    page.append("<h2>Data</h2>")
    page.append(table_html(rows))
    page.append("</body></html>")
    open(f"{d}/plots/index.html", "w").write("\n".join(page))
    print("\n".join(f"{d}/plots/{n}" for n, _ in files))
    print(f"{d}/plots/index.html")


if __name__ == "__main__":
    main()
