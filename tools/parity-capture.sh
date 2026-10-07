#!/bin/bash
# Captures the macOS debug build in the scene the Windows app shows with `--scene parity` (or
# `--scene compact`), for comparing the two apps side by side. Needs the C922 webcam and the
# Realtek USB audio adapter plugged in; your debug-build settings are restored afterwards.
# Usage: tools/parity-capture.sh [parity|compact] [output.png]
set -euo pipefail
cd "$(dirname "$0")/.."

SCENE=${1:-parity}
OUT=${2:-/tmp/lavboard-mac-$SCENE.png}
DOMAIN=com.sauerdev.lavboard.debug

xcodegen generate --quiet
xcodebuild -project Lavboard.xcodeproj -scheme Lavboard -configuration Debug -derivedDataPath build \
    -clonedSourcePackagesDirPath build/SourcePackages -quiet
swiftc -O -o /tmp/lavctl tools/lavctl.swift

BACKUP=$(mktemp)
defaults export "$DOMAIN" "$BACKUP"
restore() {
    osascript -e "tell application id \"$DOMAIN\" to quit" 2>/dev/null || true
    sleep 1
    defaults import "$DOMAIN" "$BACKUP"
    rm -f "$BACKUP"
}
trap restore EXIT

osascript -e "tell application id \"$DOMAIN\" to quit" 2>/dev/null || true
sleep 1
defaults write "$DOMAIN" FakeMicSystem -bool true
defaults delete "$DOMAIN" tracks 2>/dev/null || true
open -n build/Build/Products/Debug/Lavboard.app
sleep 6

c() { /tmp/lavctl "$1"; sleep 0.4; }
for _ in 1 2 3 4; do c "removetrack 1"; done
c "addtx 1 fake"; c "addtx 2 fake"
c "adddevice C922 1 stereo"; c "adddevice Realtek 1"
c "label 1 orange Host"; c "label 2 pink Guest"; c "label 3 yellow Panel"; c "label 4 blue Q&A"
c "mute 4"
if [ "$SCENE" = compact ]; then
    c "adddevice C922 1"; c "adddevice C922 2"; c "label 5 green Cam L"; c "label 6 violet Cam R"
fi
sleep 2
rm -f "$OUT"
c "capture $OUT"
sleep 2
[ -s "$OUT" ] || { echo "error: capture failed" >&2; exit 1; }
echo "Saved $OUT"
