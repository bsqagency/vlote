#!/bin/bash
# Headless checks: layout geometry + AppleScript syntax.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Layout geometry"
swiftc -O -target arm64-apple-macosx14.0 -framework AppKit -framework Combine \
    Sources/Core/Geometry.swift Sources/Core/Settings.swift Sources/Windows/LayoutTree.swift \
    Tests/main.swift -o build/layouttests
./build/layouttests
