#!/bin/bash
# Builds Blinker.app into ./build.
# Usage: ./build.sh [--open | --install]
#   --open     launch the freshly built app
#   --install  copy it to /Applications (or ~/Applications if that isn't writable) and launch it
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Blinker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Blinker "$APP/Contents/MacOS/Blinker"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Blinker</string>
    <key>CFBundleIdentifier</key><string>io.github.guneysol.blinker</string>
    <key>CFBundleExecutable</key><string>Blinker</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime: no code injection via DYLD_* variables, no
# unsigned libraries. Quiet "replacing existing signature"; failures still exit via set -e.
codesign --force --options runtime --sign - "$APP" 2>/dev/null
echo "Built $APP"

relaunch() {
    # Stop the running Blinker, like portside: no AppleScript, so no "wants to control" prompt.
    # Only your own processes, and only the app itself (its exact path with no arguments), so
    # an editor or a `Blinker --watch` session is never touched. Blinker exits cleanly on TERM.
    local pid
    for pid in $(pgrep -U "$(id -u)" -x Blinker); do
        case "$(ps -o args= -p "$pid")" in
            "/Applications/Blinker.app/Contents/MacOS/Blinker" | \
            "$HOME/Applications/Blinker.app/Contents/MacOS/Blinker" | \
            "$PWD/build/Blinker.app/Contents/MacOS/Blinker")
                kill "$pid" 2>/dev/null || true
                while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done ;;
        esac
    done
    open "$1"
}

case "${1:-}" in
    --open) relaunch "$APP" ;;
    --install)
        if [[ -w /Applications ]]; then dest=/Applications; else dest=~/Applications; fi
        # Only ever replace or remove our own Blinker.app, never another app with the same name.
        for dir in /Applications ~/Applications; do
            old="$dir/Blinker.app"
            [[ -e "$old" ]] || continue
            id=$(defaults read "$old/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
            if [[ "$id" != io.github.guneysol.blinker ]]; then
                [[ "$dir" == "$dest" ]] || continue
                echo "$old belongs to another app ($id). Move it, then run this again."
                exit 1
            fi
            rm -rf "$old"
        done
        mkdir -p "$dest"
        cp -R "$APP" "$dest/"
        relaunch "$dest/Blinker.app"
        echo "Installed $dest/Blinker.app. It's running in your menu bar now."
        ;;
esac
