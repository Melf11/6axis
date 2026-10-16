#!/bin/bash
# Bug-report chat against a mock GitHub (no network): an allowed account and one that isn't listed.
#   scripts/bugreport-check.sh [snapshot-dir]     (needs build/6axis.app)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/6axis.app/Contents/MacOS/SixAxis"
fail=0
run() {   # login, expected chat (1/0), port
    python3 "$ROOT/scripts/mock_github.py" "$3" "$1" 2>/dev/null & local mock=$!
    for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$3/" && break; sleep 0.1; done
    out=$(env SIXAXIS_BUGREPORT_TEST="$2" SIXAXIS_FAST_SNAPSHOTS=1 SIXAXIS_GITHUB_API="http://127.0.0.1:$3" \
          SIXAXIS_GITHUB_LOGIN="http://127.0.0.1:$3" SIXAXIS_GITHUB_CLIENT_ID=test ${4:+SIXAXIS_SNAPSHOTS="$4"} "$BIN" 2>&1)
    kill $mock 2>/dev/null; wait $mock 2>/dev/null
    echo "$out" | grep "^CHECK" | sed "s/^/  [@$1] /"
    echo "$out" | grep -q "^CHECK FAIL" && fail=1
    echo "$out" | grep -q "^CHECK ok" || { echo "  [@$1] no checks ran"; fail=1; }
}
echo "Bug-report chat:"
run Melf11 1 18766 "${1:-}"
run stranger 0 18767
exit $fail
