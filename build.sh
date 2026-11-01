#!/bin/bash
# Builds Macnizer.app without Xcode - Command Line Tools are enough.
#
#   ./build.sh              native architecture only (fast, for development)
#   ./build.sh --universal  arm64 + x86_64 (for distribution)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="vlote"
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
    Sources/Snaple/*/*.swift    # Snaple (screenshot) feature set, folder structure kept
    Sources/FullPage/*.swift    # Full-page browser capture (scroll and stitch)
    Sources/Clipboard/*.swift   # Clipboard history (store, preferences)
    Sources/main.swift          # must be last; swiftc treats it as the entry point
)

FRAMEWORKS=(
    -framework AppKit -framework SwiftUI -framework ApplicationServices
    -framework Carbon -framework Combine
    -framework ScreenCaptureKit -framework Vision -framework ImageIO
    -framework CoreImage -framework UniformTypeIdentifiers -framework Security
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
if [[ -f Resources/Macnizer.icns ]]; then cp Resources/Macnizer.icns "${RES_DIR}/"; fi
if [[ -f Resources/StatusIcon.png ]]; then cp Resources/StatusIcon.png "${RES_DIR}/"; fi
if [[ -f Resources/StatusIcon@2x.png ]]; then cp Resources/StatusIcon@2x.png "${RES_DIR}/"; fi

# Signing, in priority order:
#
#   MACNIZER_ADHOC=1  Ad-hoc. Only for a DMG going to people who do not have
#                     the Developer ID certificate story.
#   Developer ID      Preferred whenever the certificate is installed, for
#                     development as well as release. One identity everywhere
#                     means the designated requirement never changes, so
#                     permissions granted once stay granted.
#   Self-signed       Fallback from before a real certificate existed.
#   Ad-hoc            Last resort.
#
# Why the local identity matters: macOS ties Accessibility and Automation
# grants to the code signature's designated requirement. An ad-hoc signature's
# requirement is its cdhash, which changes on every build, so every rebuild
# revokes the permissions. A stable identity makes the requirement
# `identifier + certificate leaf`, which survives rebuilds.
SIGN_ID="Macnizer Local Signing"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
         | grep "Developer ID Application" | head -1 \
         | sed -E 's/.*"(.*)".*/\1/' || true)"

if [[ "${MACNIZER_ADHOC:-}" == "1" ]]; then
    echo "==> Signing ad-hoc"
    codesign --force --deep --sign - "$BUNDLE" 2>/dev/null
elif [[ -n "$DEVID" ]]; then
    echo "==> Signing with $DEVID (hardened runtime)"
    # --options runtime is required for notarisation; the entitlements restore
    # Apple Events, which the hardened runtime would otherwise block.
    codesign --force --deep --timestamp --options runtime \
             --entitlements Resources/Macnizer.entitlements \
             --sign "$DEVID" "$BUNDLE"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> Signing with local identity"
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
else
    echo "==> Signing ad-hoc (run ./setup-signing.sh to stop permissions resetting)"
    codesign --force --deep --sign - "$BUNDLE" 2>/dev/null
fi

echo "==> Built ${BUNDLE} ($(lipo -archs "${MACOS_DIR}/${APP_NAME}"))"
