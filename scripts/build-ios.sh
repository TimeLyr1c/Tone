#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Prefer full Xcode without changing the machine's global xcode-select setting.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -project Tone.xcodeproj -scheme Tone -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios \
    CODE_SIGNING_ALLOWED=NO build
