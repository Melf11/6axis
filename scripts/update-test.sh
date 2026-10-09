#!/bin/bash
# End-to-end test of the in-app updater with a local feed:
# an "old" app updates itself to a signed 9.9.9 build; a second run with a forged signature must not install.
#   scripts/update-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/apps" "$T/feed"

echo "building new version 9.9.9 …"
VERSION=9.9.9 "$ROOT/scripts/build-app.sh" release >/dev/null
(cd "$ROOT/build" && ditto -c -k --sequesterRsrc --keepParent 6axis.app "$T/feed/6axis-9.9.9.zip")
echo "building old version 1.0.0 …"
VERSION=1.0.0 "$ROOT/scripts/build-app.sh" release >/dev/null

PUB="$(swift "$ROOT/scripts/update-key.swift" generate "$T/key")"
UPDATE_SIGNING_KEY="$(cat "$T/key")" swift "$ROOT/scripts/update-key.swift" sign "$T/feed/6axis-9.9.9.zip" >/dev/null
feed() {
    cat > "$T/feed/latest.json" <<JSON
{"tag_name":"v9.9.9","name":"6axis v9.9.9","body":"## Test\\n- Update-Test","html_url":"https://github.com/Melf11/6axis/releases",
 "assets":[{"name":"6axis-9.9.9.zip","browser_download_url":"file://$T/feed/6axis-9.9.9.zip"},
           {"name":"6axis-9.9.9.zip.sig","browser_download_url":"file://$T/feed/$1"}]}
JSON
}
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$T/apps/6axis.app/Contents/Info.plist"; }
run_old() {
    rm -rf "$T/apps/6axis.app"; cp -R "$ROOT/build/6axis.app" "$T/apps/"
    ( SIXAXIS_UPDATE_TEST=1 SIXAXIS_UPDATE_NO_RELAUNCH=1 SIXAXIS_UPDATE_FEED="file://$T/feed/latest.json" \
        SIXAXIS_UPDATE_PUBLIC_KEY="$PUB" "$T/apps/6axis.app/Contents/MacOS/SixAxis" > "$T/run.log" 2>&1 ) &
    local pid=$!
    for i in $(seq 1 60); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    if kill -0 $pid 2>/dev/null; then echo "  app did not quit within 30 s"; kill -9 $pid; fi
    grep UPDATE "$T/run.log" || true
    for i in $(seq 1 50); do [ -d "$T/apps/previous.app" ] || [ "$(version)" = 9.9.9 ] && break; sleep 0.2; done
    sleep 1
}
fail=0

echo "1) forged signature:"
echo "AAAA$(head -c 60 /dev/urandom | base64)" > "$T/feed/forged.sig"
feed forged.sig
run_old
if [ "$(version)" = 1.0.0 ]; then echo "✓ forged update rejected, app unchanged (1.0.0)"; else echo "✗ forged update installed!"; fail=1; fi

echo "2) valid signature, update sheet open, unsaved changes:"
feed 6axis-9.9.9.zip.sig
export SIXAXIS_UPDATE_WITH_SHEET=1
run_old
unset SIXAXIS_UPDATE_WITH_SHEET
if [ "$(version)" = 9.9.9 ] && ! grep -q "did not quit" "$T/run.log"; then echo "✓ installs with the sheet open"; else echo "✗ stuck with the sheet open (version $(version))"; fail=1; fi

echo "3) valid signature:"
feed 6axis-9.9.9.zip.sig
run_old
if [ "$(version)" = 9.9.9 ] && ! grep -q "did not quit" "$T/run.log" && codesign --verify --deep --strict "$T/apps/6axis.app" 2>/dev/null; then
    echo "✓ app replaced by 9.9.9, signature intact"
else
    echo "✗ update not installed (version $(version))"; fail=1
fi
[ ! -e "$T/apps/previous.app" ] && echo "✓ no leftovers" || { echo "✗ backup left behind"; fail=1; }

"$ROOT/scripts/build-app.sh" release >/dev/null   # restore the normal build
exit $fail
