#!/bin/bash
# Headless checks: layout geometry + AppleScript syntax.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Layout geometry"
swiftc -O -target arm64-apple-macosx14.0 -framework AppKit -framework Combine \
    Sources/Core/Geometry.swift Sources/Core/Settings.swift Sources/Windows/LayoutTree.swift \
    Tests/main.swift -o build/layouttests
./build/layouttests

echo "==> Full Page: PDF page cuts and stitcher"
# Only the files these two need. SliceCapture/FullPageCapture pull in the whole app,
# so Tests/FullPage/Shims.swift stands in for CapturedSlice, FullPageError and fpLog.
swiftc -O -target arm64-apple-macosx14.0 -framework AppKit -framework ImageIO \
    -framework UniformTypeIdentifiers -framework ScreenCaptureKit \
    Sources/FullPage/Stitcher.swift Sources/FullPage/PDFExport.swift \
    Sources/Snaple/Output/Output.swift Sources/Snaple/App/Preferences.swift \
    Sources/Snaple/Support/CapturedImage.swift \
    Tests/FullPage/Shims.swift Tests/FullPage/main.swift -o build/fptests
./build/fptests
