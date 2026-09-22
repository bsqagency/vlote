#!/bin/bash
# Builds a distributable Macnizer.dmg (universal, ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Macnizer"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
STAGE="build/dmg-stage"

# Ad-hoc, not the local identity: that certificate exists only on the machine
# that created it, so signing with it elsewhere would just look broken. Ad-hoc
# is the honest choice for a build that is not notarised. It is also the
# MINIMUM - macOS refuses to run an entirely unsigned arm64 binary.
echo "==> Building universal, ad-hoc signed"
MACNIZER_ADHOC=1 ./build.sh --universal >/dev/null

echo "==> Staging"
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "build/${APP_NAME}.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Macnizer
========

1. Drag Macnizer onto the Applications folder.

2. IMPORTANT - the first launch needs a right-click.
   In Applications, RIGHT-CLICK Macnizer and choose "Open", then click
   "Open" again in the dialog.

   Double-clicking will NOT work the first time. macOS blocks apps that
   are not notarised by Apple, and says the developer "cannot be verified".
   This is expected: Macnizer is signed, but not with a paid Apple
   Developer ID. After the first right-click-Open, it launches normally.

   If macOS still refuses, open Terminal and run:
       xattr -dr com.apple.quarantine /Applications/Macnizer.app

3. Grant Accessibility access when asked.
   System Settings > Privacy & Security > Accessibility > switch Macnizer on.
   Without this macOS will not let ANY app move windows, so Macnizer can see
   your windows but cannot arrange them. The menu bar panel shows an orange
   warning until this is granted.

4. Optional - the Tabs pane asks for Automation access per browser the first
   time you use it. Macnizer reads only tab titles and URLs.

Macnizer lives in the menu bar; it has no Dock icon.

    Option-Command-T        pause / resume arranging
    Option-Command-Space    next layout
    Option-Command-R        arrange now
    Option-Command-O        open the panel

Drag any window onto another to split that tile - top/bottom half for rows,
left/right for columns.

Requires macOS 14 or later. Works on both Apple Silicon and Intel.
TXT

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
echo "    architectures: $(lipo -archs "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}")"
