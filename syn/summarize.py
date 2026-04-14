#!/usr/bin/env python3
"""Summarize yosys stat reports into a compact table."""
import os, re, glob

BUILD_DIR = os.environ.get("BUILD_DIR", "build/syn")

rows = []
for f in sorted(glob.glob(f"{BUILD_DIR}/*.stat")):
    name = os.path.basename(f).replace(".stat", "")
    txt = open(f).read()
    # Extract totals
    cells = seq = area = None
    m = re.search(r"(\d+)\s+\S+\s+cells\s*$", txt, re.MULTILINE)
    if m: cells = int(m.group(1))
    # Count sequential cells (dff* / sdff* / latch)
    seq_total = 0
    for m in re.finditer(r"^\s+(\d+)\s+\S+\s+(sky130_fd_sc_hd__\S+)\s*$",
                         txt, re.MULTILINE):
        n, cell = int(m.group(1)), m.group(2)
        if ("df" in cell or "sdf" in cell or "edf" in cell or
            "latch" in cell or "dlxtp" in cell):
            seq_total += n
    m = re.search(r"Chip area for module.*?:\s+([\d.]+)", txt)
    if m: area = float(m.group(1))
    else:
        # Fallback: sum column 2 of detailed cell lines
        total = 0.0
        for line in re.finditer(r"^\s+\d+\s+([\d.eE+]+)\s+sky130_", txt, re.MULTILINE):
            try: total += float(line.group(1))
            except: pass
        if total > 0: area = total
    rows.append((name, cells, seq_total, area))

print()
print(f"{'Config':<24} {'Cells':>8} {'FFs':>6} {'Area(µm²)':>12}")
print(f"{'-'*24} {'-'*8} {'-'*6} {'-'*12}")
for name, cells, ff, area in rows:
    c = str(cells) if cells is not None else "?"
    a = f"{area:.0f}" if area is not None else "?"
    print(f"{name:<24} {c:>8} {ff:>6} {a:>12}")
print()
