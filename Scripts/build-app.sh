#!/bin/bash
# Builds Snooker.app from the Xcode project and leaves it in SnookerMac/build/.
#
# Xcode users do not need this script: open Snooker.xcodeproj and press Run.
set -euo pipefail

cd "$(dirname "$0")/.."          # project root = SnookerMac/

CONFIG="${1:-Release}"
PROJECT="Snooker.xcodeproj"
SCHEME="Snooker"
DERIVED="$PWD/build/DerivedData"
LOG="$PWD/build/xcodebuild.log"

mkdir -p build
echo "Building Snooker ($CONFIG) with xcodebuild..."
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED" build > "$LOG" 2>&1; then
    echo "Build FAILED. Last lines of $LOG:"
    tail -30 "$LOG"
    exit 1
fi

BUILT="$DERIVED/Build/Products/$CONFIG/Snooker.app"
if [ ! -d "$BUILT" ]; then
    echo "Build succeeded but $BUILT is missing. See $LOG"
    exit 1
fi

rm -rf build/Snooker.app
cp -R "$BUILT" build/Snooker.app
# The learned players the ESC menu can switch on: the compiled models go into the app's resources, where
# `Models.url` looks for them first.
if [ -d AI/Models ]; then
    mkdir -p build/Snooker.app/Contents/Resources
    cp -R AI/Models/*.mlmodelc build/Snooker.app/Contents/Resources/ 2>/dev/null || true
fi
echo "Built: $PWD/build/Snooker.app"
