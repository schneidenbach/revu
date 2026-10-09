#!/bin/sh
# Regenerates assets/AppIcon.icns from scripts/make-icon.swift. Only needed when the design changes;
# the .icns is checked in and build-app.sh just copies it.
set -e
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift "$WORK/icon_1024.png" >/dev/null

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p assets
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "Wrote assets/AppIcon.icns"
