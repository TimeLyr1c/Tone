#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Command Line Tools include Swift but may not include XCTest. This harness needs only Foundation.
mkdir -p .build/core-checks-cache
swiftc -O -module-cache-path "$PWD/.build/core-checks-cache" \
    Tone/Core/*.swift Tests/CoreChecks/main.swift \
    -o .build/core-checks
.build/core-checks
