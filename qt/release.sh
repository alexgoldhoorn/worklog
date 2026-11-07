#!/usr/bin/env bash
# Windows release build: a Release exe plus the Qt runtime (windeployqt), zipped.
# Usage (Git Bash): qt/release.sh [outdir]   default outdir: ../worklog-release next to the repo
set -euo pipefail

# Override for your install: QT_ROOT=/c/Qt qt/release.sh
QT_ROOT=${QT_ROOT:-/c/Qt}
QT=${QT:-$QT_ROOT/6.12.0/mingw_64}
export PATH="$QT_ROOT/Tools/mingw1310_64/bin:$QT_ROOT/Tools/CMake_64/bin:$QT/bin:$PATH"

SRC=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SRC")
OUT=${1:-$(dirname "$REPO")/worklog-release}
BUILD=$(dirname "$REPO")/worklog-build-release

VERSION=$(sed -n 's/^project(WorkLogApp VERSION \([0-9.]*\).*/\1/p' "$SRC/CMakeLists.txt")
NAME=WorkLog-$VERSION-win64
DIST=$OUT/$NAME

cmake -S "$SRC" -B "$BUILD" -G "MinGW Makefiles" -DCMAKE_PREFIX_PATH="$(cygpath -m "$QT")" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j8

rm -rf "$DIST" "$OUT/$NAME.zip"
mkdir -p "$DIST"
cp "$BUILD/appWorkLogApp.exe" "$DIST/WorkLog.exe"
windeployqt --release --qmldir "$SRC" --no-translations --compiler-runtime "$DIST/WorkLog.exe"

powershell -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$DIST")' -DestinationPath '$(cygpath -w "$OUT/$NAME.zip")'"
echo "Done: $OUT/$NAME.zip (run $NAME/WorkLog.exe; it needs the files next to it)"
