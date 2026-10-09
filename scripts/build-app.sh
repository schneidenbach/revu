#!/bin/sh
# Wraps the revu binary in Revu.app (ad-hoc signed).
#
#   scripts/build-app.sh                       build a release binary, write build/Revu.app
#   scripts/build-app.sh --binary PATH         use an existing binary instead of building
#   scripts/build-app.sh --out DIR             write DIR/Revu.app (relative paths are from the repo root)
set -e
cd "$(dirname "$0")/.."

BINARY=""
OUT="build"
while [ $# -gt 0 ]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "usage: $0 [--binary PATH] [--out DIR]" >&2; exit 1 ;;
    esac
done

if [ -z "$BINARY" ]; then
    swift build -c release
    BINARY="$(swift build -c release --show-bin-path)/revu"
fi

# The version lives in one place: Sources/RevuCore/Version.swift.
VERSION="$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/RevuCore/Version.swift)"
[ -n "$VERSION" ] || { echo "could not read the version from Version.swift" >&2; exit 1; }

APP="$OUT/Revu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/revu"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ch.schneidenba.revu</string>
    <key>CFBundleName</key><string>Revu</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDisplayName</key><string>Revu</string>
    <key>CFBundleExecutable</key><string>revu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP ($VERSION)"
