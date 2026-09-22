#!/bin/bash
# Builds Macnizer.app without Xcode — Command Line Tools are enough.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Macnizer"
BUNDLE="build/${APP_NAME}.app"
MACOS_DIR="${BUNDLE}/Contents/MacOS"
RES_DIR="${BUNDLE}/Contents/Resources"

echo "==> Cleaning"
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Compiling"
# main.swift must come last and must NOT be compiled with -parse-as-library:
# swiftc treats a file named main.swift as the program entry point.
swiftc \
    -O \
    -target arm64-apple-macosx14.0 \
    -framework AppKit \
    -framework SwiftUI \
    -framework ApplicationServices \
    -framework Carbon \
    -framework Combine \
    Sources/Core/*.swift \
    Sources/Windows/*.swift \
    Sources/Tabs/*.swift \
    Sources/UI/*.swift \
    Sources/main.swift \
    -o "${MACOS_DIR}/${APP_NAME}"

echo "==> Assembling bundle"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"

# macOS ties Accessibility and Automation grants to the code signature's
# designated requirement. An ad-hoc signature's requirement is its cdhash, which
# changes on every build - so every rebuild silently revoked the permissions.
#
# Signing with a stable self-signed identity instead gives a requirement of
# `identifier + certificate leaf`, both of which survive a rebuild. Grant the
# permissions once and they stick. Create the identity with ./setup-signing.sh.
SIGN_ID="Macnizer Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> Signing with stable identity"
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
else
    echo "==> Signing ad-hoc (run ./setup-signing.sh to stop permissions resetting)"
    codesign --force --deep --sign - "$BUNDLE" 2>/dev/null
fi

echo "==> Built ${BUNDLE}"
