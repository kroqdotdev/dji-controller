#!/bin/bash
# Captures docs/screenshot.png for the README from a debug build: demo tape labels, one muted
# mic and speech on the meters. Your settings are restored afterwards.
# Needs the receiver plugged in and all four transmitters switched on.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN=com.sauerdev.lavboard
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1)
OUT="$PWD/docs/screenshot.png"

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
    [ -d /Applications/Lavboard.app ] && open /Applications/Lavboard.app
}
trap restore EXIT

pkill -x Lavboard || true
sleep 1
defaults delete "$DOMAIN" streamOutputUID 2>/dev/null || true
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
sleep 1
say -v Samantha "Welcome back to the show. Tonight we are talking about live sound for small venues." &
sleep 2.2
/tmp/lavctl "capture $OUT"
sleep 1.5
wait
[ -f "$OUT" ] || { echo "error: capture failed" >&2; exit 1; }
echo "Saved $OUT"
