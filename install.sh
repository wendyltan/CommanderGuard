#!/bin/bash
set -euo pipefail
ROOT="/Volumes/ExtSSD/Projects/CommanderGuard"
APP="$HOME/Applications/CommanderGuard.app"
DESKTOP="$HOME/Desktop/Commander 守护.app"
PLIST="$HOME/Library/LaunchAgents/com.wuwendi.commander-guard.plist"
SOURCE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d /Volumes/ExtSSD/Projects ]]; then echo "Missing destination /Volumes/ExtSSD/Projects" >&2; exit 1; fi
if [[ -L "$ROOT" || -L "$APP" || -L "$PLIST" ]]; then echo "Refusing symlink install destination" >&2; exit 1; fi
if [[ -e "$ROOT" && ! -f "$ROOT/CommanderGuard.swift" ]]; then echo "Refusing to overwrite non-CommanderGuard project: $ROOT" >&2; exit 1; fi
if [[ -e "$APP" && ! -f "$APP/Contents/Info.plist" ]] || { [[ -e "$APP" ]] && ! /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null | grep -qx 'com.wuwendi.commander-guard'; }; then echo "Refusing to overwrite unrelated app: $APP" >&2; exit 1; fi
if [[ -e "$DESKTOP" || -L "$DESKTOP" ]]; then
  if [[ ! -L "$DESKTOP" || "$(readlink "$DESKTOP")" != "$APP" ]]; then echo "Refusing to overwrite existing Desktop item: $DESKTOP" >&2; exit 1; fi
fi
if [[ -e "$PLIST" ]] && ! /usr/libexec/PlistBuddy -c 'Print Label' "$PLIST" 2>/dev/null | grep -qx 'com.wuwendi.commander-guard'; then echo "Refusing to overwrite unrelated LaunchAgent: $PLIST" >&2; exit 1; fi

"$SOURCE/build.sh" >/dev/null
mkdir -p "$ROOT" "$HOME/Applications" "$HOME/Desktop" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/CommanderGuard"
if [[ ! "$SOURCE" -ef "$ROOT" ]]; then
  for file in CommanderGuard.swift build.sh install.sh uninstall.sh README.md .gitignore; do ditto "$SOURCE/$file" "$ROOT/$file"; done
fi
if [[ -f "$PLIST" ]]; then launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true; fi
ditto "$SOURCE/build/CommanderGuard.app" "$APP"
if [[ -L "$DESKTOP" ]]; then rm "$DESKTOP"; fi
ln -s "$APP" "$DESKTOP"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.wuwendi.commander-guard</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/CommanderGuard</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>30</integer>
<key>StandardOutPath</key><string>$HOME/Library/Logs/CommanderGuard/stdout.log</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/CommanderGuard/stderr.log</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed CommanderGuard. Existing Remote Desktop Commander service was not changed."
