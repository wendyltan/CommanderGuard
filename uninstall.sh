#!/bin/bash
set -euo pipefail
APP="$HOME/Applications/CommanderGuard.app"
DESKTOP="$HOME/Desktop/Commander 守护.app"
PLIST="$HOME/Library/LaunchAgents/com.wuwendi.commander-guard.plist"
if [[ -f "$PLIST" ]] && /usr/libexec/PlistBuddy -c 'Print Label' "$PLIST" 2>/dev/null | grep -qx 'com.wuwendi.commander-guard'; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm "$PLIST"
fi
if [[ -L "$DESKTOP" && "$(readlink "$DESKTOP")" == "$APP" ]]; then rm "$DESKTOP"; fi
if [[ -d "$APP" ]] && /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null | grep -qx 'com.wuwendi.commander-guard'; then rm -rf "$APP"; fi
echo "Removed CommanderGuard app, shortcut, and its LaunchAgent. Project source, status, and logs were preserved."
