#!/bin/bash
# Builds "Lavboard.app" for direct download and packages it as a DMG.
#
#   scripts/release.sh 0.2.0                        Developer ID signed DMG in dist/
#   scripts/release.sh 0.2.0 --notarize             also notarize and staple the app
#   scripts/release.sh 0.2.0 --notarize --publish   also create a draft GitHub release
#
# Signing and notarization go through the Apple Developer account signed into Xcode
# (Xcode > Settings > Accounts), using Xcode's cloud-managed Developer ID certificate, so no
# certificates or app-specific passwords need to be set up by hand. The team comes from
# DEVELOPMENT_TEAM in Config/Local.xcconfig, or TEAM_ID in the environment.
#
# Only notarized builds open on other Macs without Gatekeeper blocking them.

set -euo pipefail

usage() { echo "usage: scripts/release.sh VERSION [--notarize] [--publish]" >&2; exit 1; }
[ $# -ge 1 ] || usage
VERSION=$1
shift
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION must look like 1.2.3" >&2; exit 1; }

NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
    case $arg in
        --notarize) NOTARIZE=1 ;;
        --publish) PUBLISH=1 ;;
        *) usage ;;
    esac
done
[ $PUBLISH -eq 0 ] || [ $NOTARIZE -eq 1 ] || { echo "error: only notarized builds can be published (add --notarize)" >&2; exit 1; }

cd "$(dirname "$0")/.."
APP_NAME="Lavboard"
OUT=build/release
ARCHIVE="$OUT/Lavboard.xcarchive"
DMG="dist/Lavboard-$VERSION.dmg"

TEAM=${TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null | head -1)}
[ -n "$TEAM" ] || { echo "error: set DEVELOPMENT_TEAM in Config/Local.xcconfig or TEAM_ID" >&2; exit 1; }

export_options() {
    cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>destination</key><string>$1</string>
</dict>
</plist>
EOF
}

echo "==> Archiving $APP_NAME $VERSION"
rm -rf "$OUT"
mkdir -p "$OUT" dist
xcodegen generate --quiet
xcodebuild archive \
    -project Lavboard.xcodeproj \
    -scheme Lavboard \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -quiet \
    MARKETING_VERSION="$VERSION"

if [ $NOTARIZE -eq 1 ]; then
    echo "==> Signing with Developer ID and uploading for notarization"
    export_options upload
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
        -exportPath "$OUT/upload" -allowProvisioningUpdates -quiet
    echo "==> Waiting for Apple (usually a few minutes)"
    for _ in $(seq 1 90); do
        if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/app" >"$OUT/notary.log" 2>&1; then
            break
        fi
        if grep -qi 'invalid\|rejected' "$OUT/notary.log"; then
            cat "$OUT/notary.log" >&2
            echo "error: notarization was rejected" >&2
            exit 1
        fi
        sleep 20
    done
    [ -d "$OUT/app/$APP_NAME.app" ] || { cat "$OUT/notary.log" >&2; echo "error: notarization timed out" >&2; exit 1; }
else
    echo "==> Signing with Developer ID (not notarized: other Macs will block this build)"
    export_options export
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
        -exportPath "$OUT/app" -allowProvisioningUpdates -quiet
fi

APP="$OUT/app/$APP_NAME.app"
codesign --verify --deep --strict "$APP"
echo "    $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ $NOTARIZE -eq 0 ] || spctl --assess --type execute -v "$APP"

echo "==> Packaging $DMG"
STAGE=$(mktemp -d)
SCRATCH=$(mktemp -d)
trap 'hdiutil detach "$SCRATCH/mnt" -quiet 2>/dev/null || true; rm -rf "$STAGE" "$SCRATCH"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov -quiet "$SCRATCH/rw.dmg"
mkdir "$SCRATCH/mnt"
hdiutil attach "$SCRATCH/rw.dmg" -mountpoint "$SCRATCH/mnt" -nobrowse -noautoopen -quiet
cp "$APP/Contents/Resources/AppIcon.icns" "$SCRATCH/mnt/.VolumeIcon.icns"
xcrun SetFile -a C "$SCRATCH/mnt"
hdiutil detach "$SCRATCH/mnt" -quiet
rm -f "$DMG"
hdiutil convert "$SCRATCH/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"

if [ $PUBLISH -eq 1 ]; then
    NOTES=$(mktemp)
    printf 'Download **Lavboard-%s.dmg**, open it and drag Lavboard into Applications.\n' "$VERSION" > "$NOTES"
    gh release create "v$VERSION" "$DMG" --draft --title "Lavboard $VERSION" --notes-file "$NOTES" --generate-notes
    rm -f "$NOTES"
    echo "==> Draft release v$VERSION created. Review it on GitHub, then publish it."
fi
