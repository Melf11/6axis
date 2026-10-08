#!/bin/bash
# Makes 6axis.app self-contained: copies every non-system dylib it needs (recursively) into
# Contents/Frameworks, rewrites all references to @rpath, removes Homebrew rpaths, adds the
# licences of the bundled libraries, verifies nothing points outside the app and signs ad hoc.
#
# Usage: scripts/bundle-libs.sh build/6axis.app
set -euo pipefail

APP="${1:?usage: bundle-libs.sh path/to/6axis.app}"
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
FW="$APP/Contents/Frameworks"
LIC="$APP/Contents/Resources/Licenses"
BREW="$(brew --prefix)"
mkdir -p "$FW" "$LIC"

is_system() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Non-system dependencies of a Mach-O file (first line of otool -L is the file itself / its id).
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r d; do is_system "$d" || echo "$d"; done; }

# Resolve an install name to a real file. @rpath names are looked up in the rpaths of the
# referencing file and in the Homebrew lib directories.
resolve() {
    local name="$1" from="$2"
    case "$name" in
        @rpath/*|@loader_path/*|@executable_path/*)
            local base="${name##*/}"
            local dirs
            dirs="$(otool -l "$from" | awk '/LC_RPATH/{getline; getline; print $2}' | sed "s|@loader_path|$(dirname "$from")|")"
            for d in $dirs "$(dirname "$from")" "$BREW/opt/opencascade/lib" "$BREW/lib"; do
                [ -f "$d/$base" ] && { echo "$d/$base"; return; }
            done
            echo "unresolved: $name (from $from)" >&2; exit 1 ;;
        *) echo "$name" ;;
    esac
}

# 1. Collect the dependency closure.
declare -a queue=("$EXE")
declare -a bundled=()
seen=" "
while [ ${#queue[@]} -gt 0 ]; do
    file="${queue[0]}"; queue=("${queue[@]:1}")
    for d in $(deps "$file"); do
        real="$(resolve "$d" "$file")"
        base="${real##*/}"
        [[ "$seen" == *" $base "* ]] && continue
        seen="$seen$base "
        cp -L "$real" "$FW/$base"
        chmod u+w "$FW/$base"
        bundled+=("$real")
        queue+=("$real")
    done
done
echo "Bundled ${#bundled[@]} libraries"

# 2. Rewrite install names and rpaths.
fix() {
    local f="$1"
    for d in $(deps "$f"); do
        install_name_tool -change "$d" "@rpath/${d##*/}" "$f" 2>/dev/null
    done
    for r in $(otool -l "$f" | awk '/LC_RPATH/{getline; getline; print $2}'); do
        [[ "$r" == @* ]] || install_name_tool -delete_rpath "$r" "$f" 2>/dev/null || true
    done
}
fix "$EXE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
for lib in "$FW"/*.dylib; do
    install_name_tool -id "@rpath/${lib##*/}" "$lib" 2>/dev/null
    fix "$lib"
    install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

# 3. Licences of the bundled libraries (LGPL compliance for OpenCASCADE: libraries stay
#    replaceable dylibs, licence text and source location are included).
notice="$LIC/THIRD-PARTY.txt"
{
    echo "6axis bundles the following libraries as separate, replaceable dynamic libraries"
    echo "(Contents/Frameworks). Their licences are in this folder."
    echo
} > "$notice"
formulas=$(for p in "${bundled[@]}"; do
    real="$(cd "$(dirname "$p")" && pwd -P)"
    echo "$real" | sed -n "s|^$BREW/Cellar/\([^/]*\)/.*|\1|p"
done | sort -u)
for f in $formulas; do
    prefix="$(brew --prefix "$f")"
    mkdir -p "$LIC/$f"
    find "$prefix" -maxdepth 1 \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'LICENCE*' \) -exec cp {} "$LIC/$f/" \; 2>/dev/null || true
    find "$prefix/share/doc/$f" -maxdepth 1 \( -iname '*LICENSE*' -o -iname '*LGPL*' -o -iname '*EXCEPTION*' -o -iname 'COPYING*' \) -exec cp {} "$LIC/$f/" \; 2>/dev/null || true
    info="$(brew info --json=v2 "$f" | python3 -c 'import json,sys; f=json.load(sys.stdin)["formulae"][0]; print(f["versions"]["stable"], f.get("license") or "", f["homepage"], f["urls"]["stable"]["url"], sep="|")')"
    IFS='|' read -r version license homepage source <<< "$info"
    printf "%s %s\n  Lizenz: %s\n  Projekt: %s\n  Quellcode: %s\n\n" "$f" "$version" "$license" "$homepage" "$source" >> "$notice"
done
echo "Licences: $(echo $formulas | tr '\n' ' ')"

# 4. Verify: no reference may point outside the app.
bad=0
for f in "$EXE" "$FW"/*.dylib; do
    if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -Ev '^(@rpath|/usr/lib|/System)' ; then
        echo "external reference in $f" >&2; bad=1
    fi
    if otool -l "$f" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -E "^($BREW|/usr/local)"; then
        echo "Homebrew rpath left in $f" >&2; bad=1
    fi
done
[ $bad -eq 0 ] || exit 1

# 5. Ad-hoc signature (required on Apple Silicon); libraries first, then the app.
for lib in "$FW"/*.dylib; do codesign --force --sign - "$lib" 2>/dev/null; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Self-contained: $APP ($(du -sh "$APP" | cut -f1))"
