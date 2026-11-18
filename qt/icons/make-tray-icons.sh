#!/bin/sh
# Renders the tray icon variants (state dot in the corner) from worklog.svg. Needs ImageMagick.
# Run from anywhere; the PNGs are resources (WL_RESOURCES in CMakeLists.txt).
set -e
cd "$(dirname "$0")"
for v in working:#22c55e break:#f59e0b stopped:#9ca3af offline:#dc2626; do
    name=${v%%:*}; color=${v#*:}
    magick -background none -density 600 worklog.svg -resize 128x128 \
        -fill "$color" -stroke white -strokewidth 5 -draw "circle 96,96 96,66" \
        PNG32:tray-$name.png
done
