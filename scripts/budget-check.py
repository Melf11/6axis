#!/usr/bin/env python3
"""Compares measurements from the UI check against scripts/budgets.txt.
   python3 scripts/budget-check.py <ui-check-dir> <app>"""
import os
import re
import subprocess
import sys

out, app = sys.argv[1], sys.argv[2]
root = os.path.dirname(os.path.abspath(__file__))


def read(name):
    try:
        return open(os.path.join(out, name), encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


budgets, notes = {}, {}
for line in open(os.path.join(root, "budgets.txt"), encoding="utf-8"):
    m = re.match(r"\s*(\w+)\s+(\d+)\s+(\d+)\s*(?:#\s*(.*))?$", line)
    if m:
        budgets[m.group(1)] = int(m.group(3) if os.environ.get("GITHUB_ACTIONS") else m.group(2))
        notes[m.group(1)] = (m.group(4) or "").strip()

values = {k: float(v) for k, v in re.findall(r"^BUDGET (\w+) (\d+)", read("budget.log"), re.M)}
drag = read("drag.log")
lat = [float(x) for x in re.findall(r"latency avg [\d.]+ max ([\d.]+) ms", drag)]
orbit = re.search(r"DRAG orbit: (\d+) frames", drag)
# Frame latency only counts when the window was on screen (CI runners may not present frames).
if lat and "DRAG window visible=1" in drag and orbit and int(orbit.group(1)) >= 100:
    values["drag_latency_ms"] = max(lat)
burst = re.search(r"DRAG burst: \d+ queued events consumed in (\d+) ms", drag)
if burst:
    values["drag_burst_ms"] = float(burst.group(1))
rebuild = read("rebuild.log")
if m := re.search(r"REBUILD commit returned after (\d+) ms", rebuild):
    values["rebuild_blocking_ms"] = float(m.group(1))
if m := re.search(r"REBUILD done after (\d+) ms", rebuild):
    values["rebuild_total_ms"] = float(m.group(1))
size = subprocess.run(["du", "-sk", app], capture_output=True, text=True).stdout.split()
if size:
    values["app_size_mb"] = int(size[0]) / 1024

rows, fail = [], False
for key, limit in budgets.items():
    v = values.get(key)
    if v is None:
        status = "–"
    elif v <= limit:
        status = "ok"
    else:
        status = "ZU HOCH"
        fail = True
    rows.append((key, "–" if v is None else f"{v:.0f}", str(limit), status, notes[key]))

w = [max(len(r[i]) for r in rows) for i in range(4)]
print("Grenzwerte:")
for r in rows:
    print(f"  {'✓' if r[3] == 'ok' else ('·' if r[3] == '–' else '✗')} {r[0]:<{w[0]}}  {r[1]:>{w[1]}} / {r[2]:<{w[2]}}  {r[4]}")
    if r[3] == "ZU HOCH":
        print(f"::error::Grenzwert {r[0]} überschritten: {r[1]} > {r[2]} ({r[4]})")
if os.environ.get("GITHUB_ACTIONS"):
    print("::notice title=Grenzwerte::" + " · ".join(f"{r[0]} {r[1]}/{r[2]}" for r in rows))
if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(summary, "a", encoding="utf-8") as f:
        f.write("### Grenzwerte\n\n| | Messwert | Grenze | Bedeutung |\n|---|---|---|---|\n")
        for r in rows:
            f.write(f"| {r[0]} | {r[1]} | {r[2]} | {r[4]} |\n")
sys.exit(1 if fail else 0)
