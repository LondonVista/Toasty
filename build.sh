#!/bin/bash
# Builds Toasty.app and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

# SwiftUI's @State macro is missing from the SDK 27 Command Line Tools, so pin 26.5 when it is there.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
SDK_ARGS=()
[ -d "$SDK" ] && SDK_ARGS=(-sdk "$SDK")

if [ ! -f AppIcon.icns ]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    swift tools/make_icon.swift build/icon.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o AppIcon.icns
fi

APP=build/Toasty.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O "${SDK_ARGS[@]}" -target arm64-apple-macos13.0 Sources/*.swift -o "$APP/Contents/MacOS/Toasty"
codesign --force --sign - "$APP"

pkill -x Toasty 2>/dev/null || true
rm -rf /Applications/Toasty.app
cp -R "$APP" /Applications/
open /Applications/Toasty.app --args "$@"
echo "Installed /Applications/Toasty.app"
