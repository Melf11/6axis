#!/bin/bash
# Social preview images (Open Graph, 1200 × 630) for the product page: website/assets/og-de.png, og-en.png.
# Uses website/assets/hero.svg (from scripts/screenshots.sh) and Google Chrome (headless).
#   scripts/make-og-image.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
cp "$ROOT/website/assets/hero.svg" "$ROOT/website/assets/logo.png" "$TMP/"
svg="$(sed 's/ width="[0-9]*mm" height="[0-9]*mm"//' "$TMP/hero.svg")"
for lang in de en; do
    if [ "$lang" = de ]; then
        H="Vom Modell zur Werkstatt&shy;zeichnung."; T="Kostenloses CAD für den Mac · offline · Open Source"
    else
        H="From model to workshop drawing."; T="Free CAD for the Mac · offline · open source"
    fi
    cat > "$TMP/og-$lang.html" <<EOF
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:1200px;height:630px;overflow:hidden}
body{background:#121827;color:#E9EDF5;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif;display:grid;grid-template-columns:540px 1fr;align-items:center;gap:40px;padding:0 64px;box-sizing:border-box}
.brand{display:flex;align-items:center;gap:16px;font-weight:700;font-size:38px;margin-bottom:34px}
.brand img{width:64px;height:64px}
h1{font-weight:800;font-size:66px;line-height:1.02;letter-spacing:-.035em;margin:0 0 26px;hyphens:manual}
p{font-size:22px;color:#A3ADC2;margin:0;white-space:nowrap}
.sheet{background:#1A2236;border:1px solid #2B3550;border-radius:18px;padding:28px 34px;height:520px;box-sizing:border-box;display:flex}
.sheet svg{width:100%;height:100%}
svg .visible{stroke:#E9EDF5;stroke-linecap:round} svg .hidden,svg .center,svg .thin{stroke:#A3ADC2}
svg .dim{stroke:#6B9BFF} svg .arrow{fill:#6B9BFF} svg text{fill:#6B9BFF;font-family:-apple-system,sans-serif}
.axes{display:flex;gap:10px;margin-top:36px}.axes i{width:56px;height:6px;border-radius:3px}
</style></head><body>
<div><div class="brand"><img src="logo.png">6axis</div><h1>$H</h1><p>$T</p>
<div class="axes"><i style="background:#FF6B7A"></i><i style="background:#3EDBA0"></i><i style="background:#6B9BFF"></i></div></div>
<div class="sheet">$svg</div>
</body></html>
EOF
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1200,630 \
        --screenshot="$ROOT/website/assets/og-$lang.png" "file://$TMP/og-$lang.html" 2>/dev/null
    echo "  website/assets/og-$lang.png"
done
rm -rf "$TMP"
