#!/bin/bash
# Builds Macnizer.app without Xcode - Command Line Tools are enough.
#
#   ./build.sh              native architecture only (fast, for development)
#   ./build.sh --universal  arm64 + x86_64 (for distribution)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Macnizer"
BUNDLE="build/${APP_NAME}.app"
MACOS_DIR="${BUNDLE}/Contents/MacOS"
RES_DIR="${BUNDLE}/Contents/Resources"

UNIVERSAL=false
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=true

SOURCES=(
    Sources/Core/*.swift
    Sources/Windows/*.swift
    Sources/Tabs/*.swift
    Sources/UI/*.swift
    Sources/main.swift          # must be last; swiftc treats it as the entry point
)

FRAMEWORKS=(
    -framework AppKit -framework SwiftUI -framework ApplicationServices
    -framework Carbon -framework Combine
)

compile() {  # compile <arch> <output>
    swiftc -O -target "$1-apple-macosx14.0" "${FRAMEWORKS[@]}" "${SOURCES[@]}" -o "$2"
}

echo "==> Cleaning"
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

if $UNIVERSAL; then
    echo "==> Compiling arm64 + x86_64"
    # swiftc emits one architecture per invocation, so build both and lipo them.
    compile arm64  "build/.${APP_NAME}-arm64"
    compile x86_64 "build/.${APP_NAME}-x86_64"
    lipo -create "build/.${APP_NAME}-arm64" "build/.${APP_NAME}-x86_64" \
         -output "${MACOS_DIR}/${APP_NAME}"
    rm -f "build/.${APP_NAME}-arm64" "build/.${APP_NAME}-x86_64"
else
    echo "==> Compiling $(uname -m)"
    compile "$(uname -m)" "${MACOS_DIR}/${APP_NAME}"
fi

echo "==> Assembling bundle"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
[[ -f Resources/Macnizer.icns ]] && cp Resources/Macnizer.icns "${RES_DIR}/"

# macOS ties Accessibility and Automation grants to the code signature's
# designated requirement. An ad-hoc signature's requirement is its cdhash, which
# changes on every build - so every rebuild silently revokes the permissions.
#
# A stable self-signed identity gives a requirement of `identifier + certificate
# leaf`, which survives rebuilds. The certificate must also be TRUSTED, or TCC
# ignores it and falls back to the cdhash anyway. See ./setup-signing.sh.
SIGN_ID="Macnizer Local Signing"

if [[ "${MACNIZER_ADHOC:-}" == "1" ]]; then
    echo "==> Signing ad-hoc (for distribution)"
    codesign --force --deep --sign - "$BUNDLE" 2>/dev/null
elif security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> Signing with local identity"
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
else
    echo "==> Signing ad-hoc (run ./setup-signing.sh to stop permissions resetting)"
    codesign --force --deep --sign - "$BUNDLE" 2>/dev/null
fi

echo "==> Built ${BUNDLE} ($(lipo -archs "${MACOS_DIR}/${APP_NAME}"))"
