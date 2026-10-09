#!/bin/bash
# UI regression check: runs the app's scripted demos (real windows, Metal, input pipeline) and fails if
# a demo reports model errors, crashes, hangs or produces fewer screenshots than expected.
#   scripts/ui-check.sh [output-dir]      (needs build/6axis.app)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/ui-check}"
BIN="$ROOT/build/6axis.app/Contents/MacOS/SixAxis"
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0

# Runs the app with a time limit; output goes to $OUT/<name>.log
# run <name> <seconds> VAR=value … [-- app arguments …]
run() {
    local name="$1" limit="$2"; shift 2
    local vars=() args=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
    [ "${1:-}" = "--" ] && { shift; args=("$@"); }
    ( env "${vars[@]}" "$BIN" ${args[@]+"${args[@]}"} > "$OUT/$name.log" 2>&1 ) &
    local pid=$! waited=0
    while kill -0 $pid 2>/dev/null; do
        sleep 1; waited=$((waited + 1))
        if [ $waited -ge "$limit" ]; then kill -9 $pid; echo "✗ $name: timeout after ${limit}s"; echo "::error::ui-check $name timeout after ${limit}s"; fail=1; return; fi
    done
    wait $pid; local code=$?
    [ $code -eq 0 ] || { echo "✗ $name: exit code $code"; tail -5 "$OUT/$name.log"; fail=1; }
}
expect() {   # name, pattern, description
    if grep -qE "$2" "$OUT/$1.log"; then echo "✓ $1: $3"; else echo "✗ $1: $3 – not found"; echo "::error::ui-check $1: $3 – not found"; fail=1; fi
}
count() {    # dir, minimum, description
    local n; n=$(ls "$1"/*.png 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -ge "$2" ]; then echo "✓ $3: $n screenshots"; else echo "✗ $3: $n of $2 screenshots"; fail=1; fi
}

for lang in de en; do
    run "demo-$lang" 180 SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS="$OUT/demo-$lang" -- -AppleLanguages "($lang)"
    expect "demo-$lang" "DEMO: errors \[:\]" "modelling demo without errors"
    count "$OUT/demo-$lang" 15 "demo-$lang"
done
run drawing 180 SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_DEMO=1 SIXAXIS_DRAWING_DEMO="$OUT/drawing"
expect drawing '^SHEETS \[".+", ".+"\]' "drawing with assembly and part sheets"
[ -s "$OUT/drawing/drawing.pdf" ] && [ -s "$OUT/drawing/parts.dxf" ] && echo "✓ drawing: PDF and DXF written" || { echo "✗ drawing: PDF/DXF missing"; fail=1; }
run examples 180 SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_EXAMPLES_DEMO="$OUT/examples"
if grep -q "^EXAMPLE .* errors" "$OUT/examples.log"; then echo "✗ examples: $(grep '^EXAMPLE' "$OUT/examples.log")"; fail=1; else echo "✓ examples: build without errors"; fi
count "$OUT/examples" 3 "examples"
run rebuild 240 SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_REBUILD_TEST="$OUT/rebuild"
expect rebuild "REBUILD done .* bodies=1 errors=0" "background rebuild of a heavy model"

run navigation 120 SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_NAV_TEST="$OUT/navigation"
if python3 - "$OUT/navigation.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
m = re.search(r"NAV zoom with cmd: distance ([\d.]+) -> ([\d.]+)", log)
p = re.search(r"NAV swipe: camera moved ([\d.]+)", log)
# Direction depends on settings; ⌘-scroll must change the distance clearly, a swipe must move the camera.
ratio = float(m.group(2)) / float(m.group(1)) if m else 1
sys.exit(0 if (ratio < 0.9 or ratio > 1.1) and p and float(p.group(1)) > 1 else 1)
PY
then echo "✓ navigation: ⌘-scroll zooms, two-finger scroll moves the camera (3D)"; else echo "✗ navigation: 3D zoom/pan"; echo "::error::ui-check navigation: 3D zoom/pan"; fail=1; fi
expect navigation "NAV drawing snapshots written" "drawing window scroll pan and zoom"

run drag 120 SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_DRAG_TEST=1
if python3 - "$OUT/drag.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
burst = re.search(r"DRAG burst: (\d+) queued events consumed in (\d+) ms", log)
lat = [float(x) for x in re.findall(r"latency avg [\d.]+ max ([\d.]+) ms", log)]
ok = burst and int(burst.group(1)) == 480 and int(burst.group(2)) < 1000 and lat and max(lat) < 120
print(f"burst {burst.group(2) if burst else '?'} ms, max latency {max(lat) if lat else '?'} ms")
sys.exit(0 if ok else 1)
PY
then echo "✓ drag: mouse/swipe events stay responsive"; else echo "✗ drag: navigation too slow"; echo "::error::ui-check drag: navigation too slow"; fail=1; fi

if [ $fail -ne 0 ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
    # Surface details as annotations (readable without access to the job log).
    for f in "$OUT"/*.log; do
        echo "::error title=ui-check $(basename "$f")::$(grep -E 'NAV|DEMO: errors|SHEETS|EXAMPLE|REBUILD|rror|atal' "$f" | tail -6 | tr '\n' '|' | cut -c1-900)"
    done
fi
exit $fail
