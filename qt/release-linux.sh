#!/usr/bin/env bash
# Linux release build against the system Qt (Ubuntu 26.04: Qt 6.10, apt packages in CLAUDE.md).
# Installs into a prefix (default ~/.local: binary, app menu entry, icons, plus a desktop icon) and packs the same tree
# into ../worklog-release/WorkLog-<version>-linux-<arch>.tar.gz. The tarball does not bundle Qt:
# the target machine needs the Qt 6.10+ runtime packages.
# Usage: qt/release-linux.sh [prefix]   (prefix "-" skips the install and only builds the tarball)
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SRC")
OUT=$(dirname "$REPO")/worklog-release
BUILD=$(dirname "$REPO")/worklog-build-linux-release
PREFIX=${1:-$HOME/.local}

VERSION=$(sed -n 's/^project(WorkLogApp VERSION \([0-9.]*\).*/\1/p' "$SRC/CMakeLists.txt")
NAME=WorkLog-$VERSION-linux-$(uname -m)

GEN=()
command -v ninja >/dev/null && GEN=(-G Ninja)
cmake -S "$SRC" -B "$BUILD" "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"

STAGE=$OUT/$NAME
rm -rf "$STAGE" "$OUT/$NAME.tar.gz"
cmake --install "$BUILD" --prefix "$STAGE" --strip
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
rm -rf "$STAGE"
echo "Tarball: $OUT/$NAME.tar.gz (unpack, then copy bin/ and share/ into ~/.local or /usr/local)"

if [ "$PREFIX" != "-" ]; then
    cmake --install "$BUILD" --prefix "$PREFIX" --strip
    # the menu entry runs the binary by full path, so it works without $PREFIX/bin on PATH
    APP=$PREFIX/share/applications/net.goldhoorn.worklog.desktop
    sed -i "s|^Exec=.*|Exec=$PREFIX/bin/worklog|" "$APP"
    # an icon on the desktop too (GNOME's Desktop Icons extension wants it executable and trusted)
    DESK=$(xdg-user-dir DESKTOP 2>/dev/null || true)
    if [ -n "$DESK" ] && [ "$DESK" != "$HOME" ] && [ -d "$DESK" ]; then
        install -m 755 "$APP" "$DESK/WorkLog.desktop"
        gio set "$DESK/WorkLog.desktop" metadata::trusted true 2>/dev/null || true
        echo "Desktop icon: $DESK/WorkLog.desktop"
    fi
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" || true
    echo "Installed: $PREFIX/bin/worklog (and WorkLog in the app menu)"
fi
