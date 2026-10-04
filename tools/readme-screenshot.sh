#!/bin/bash
# Captures docs/screenshot.png for the README from a debug build: demo tape labels, one muted
# mic and speech on the meters. Your settings are restored afterwards.
# Needs the receiver plugged in and all four transmitters switched on.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN=com.sauerdev.lavboard
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)
OUT="$PWD/docs/screenshot.png"
# Captured into a fresh folder first, so a failed capture can never pass for the committed image.
SHOT_DIR=$(mktemp -d "/tmp/lavboard screenshot.XXXXXX")
SHOT="$SHOT_DIR/screenshot.png"

xcodegen generate --quiet
xcodebuild -project Lavboard.xcodeproj -scheme Lavboard -configuration Debug -derivedDataPath build \
    -clonedSourcePackagesDirPath build/SourcePackages -quiet MARKETING_VERSION="$VERSION"
swiftc -O -o /tmp/lavctl tools/lavctl.swift

BACKUP=$(mktemp)
defaults export "$DOMAIN" "$BACKUP"
restore() {
    pkill -x Lavboard || true
    sleep 1
    defaults import "$DOMAIN" "$BACKUP"
    rm -f "$BACKUP"
    rm -rf "$SHOT_DIR"
    [ -d /Applications/Lavboard.app ] && open /Applications/Lavboard.app
}
trap restore EXIT

pkill -x Lavboard || true
sleep 1
defaults delete "$DOMAIN" streamOutputUID 2>/dev/null || true
# Start from four tracks on TX1-TX4, whatever tracks you have set up.
defaults delete "$DOMAIN" tracks 2>/dev/null || true
open -n build/Build/Products/Debug/Lavboard.app

connected=0
for _ in $(seq 1 30); do
    sleep 1
    /tmp/lavctl "status /tmp/lavboard-status.json"
    sleep 0.3
    connected=$(python3 -c 'import json; print(sum(t["connected"] for t in json.load(open("/tmp/lavboard-status.json"))["transmitters"]))' 2>/dev/null || echo 0)
    [ "$connected" = 4 ] && break
done
[ "$connected" = 4 ] || { echo "error: switch on all four transmitters first ($connected connected)" >&2; exit 1; }

/tmp/lavctl "label 1 orange Host"
/tmp/lavctl "label 2 pink Guest"
/tmp/lavctl "label 3 yellow Panel"
/tmp/lavctl "label 4 blue Q&A"
/tmp/lavctl "mute 4"
# Bring the window to the front so it is captured active, not dimmed.
open build/Build/Products/Debug/Lavboard.app
sleep 1
say -v Samantha "Welcome back to the show. Tonight we are talking about live sound for small venues." &
sleep 2.2
/tmp/lavctl "capture $SHOT"
sleep 1.5
wait
[ -s "$SHOT" ] || { echo "error: capture failed" >&2; exit 1; }
sips --resampleWidth 1760 "$SHOT" --out "$OUT" >/dev/null
echo "Saved $OUT"
