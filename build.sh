#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
OUT="$PWD/build"
mkdir -p "$OUT/CommanderGuard.app/Contents/MacOS"
xcrun swiftc -O -module-cache-path "/private/tmp/CommanderGuard-SwiftModuleCache" CommanderGuard.swift -framework Cocoa -framework IOKit -o "$OUT/CommanderGuard.app/Contents/MacOS/CommanderGuard"
cat > "$OUT/CommanderGuard.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.wuwendi.commander-guard</string>
<key>CFBundleName</key><string>Commander 守护</string>
<key>CFBundleExecutable</key><string>CommanderGuard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$OUT/CommanderGuard.app"
codesign --verify --deep --strict "$OUT/CommanderGuard.app"
plutil -lint "$OUT/CommanderGuard.app/Contents/Info.plist"
echo "$OUT/CommanderGuard.app"
