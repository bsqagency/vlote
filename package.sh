#!/bin/bash
# Builds a distributable Macnizer.dmg.
#
#   ./package.sh            ad-hoc signed. Recipients must right-click > Open.
#   ./package.sh --release  Developer ID + notarised + stapled. Opens cleanly
#                           on any Mac, no warning, works offline.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Macnizer"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
STAGE="build/dmg-stage"
NOTARY_PROFILE="macnizer-notary"

RELEASE=false
[[ "${1:-}" == "--release" ]] && RELEASE=true

if $RELEASE; then
    DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
    if [[ -z "$DEVID" ]]; then
        echo "No 'Developer ID Application' certificate found. See README 'Publishing'."
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "No stored notarisation credentials named '$NOTARY_PROFILE'."
        echo "Create them once (this prompts you, and nothing is stored in this repo):"
        echo
        echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "        --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD"
        exit 1
    fi
    echo "==> Building universal, signed by $DEVID"
    MACNIZER_DEVID=1 ./build.sh --universal >/dev/null
else
    # Ad-hoc is the minimum, not a choice: macOS refuses to run a wholly
    # unsigned arm64 binary. The local self-signed identity is deliberately not
    # used — it exists only on this machine, so elsewhere it just looks broken.
    echo "==> Building universal, ad-hoc signed"
    MACNIZER_ADHOC=1 ./build.sh --universal >/dev/null
fi

echo "==> Staging"
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "build/${APP_NAME}.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

if $RELEASE; then
cat > "$STAGE/READ ME.txt" <<'TXT'
Macnizer
========

1. Drag Macnizer onto the Applications folder, then open it normally.

2. Grant Accessibility access when asked.
   System Settings > Privacy & Security > Accessibility > switch Macnizer on.
   macOS does not let ANY app move windows without this, so until it is granted
   Macnizer can see your windows but cannot arrange them. The menu bar panel
   shows an orange warning until then.

3. Optional - the Tabs pane asks for Automation access per browser the first
   time you use it. Macnizer reads only tab titles and URLs, never page content.

Macnizer lives in the menu bar and has no Dock icon. The glyph is filled while
arranging and hollow while paused.

    Option-Command-T        pause / resume arranging
    Option-Command-Space    next layout
    Option-Command-R        arrange now
    Option-Command-O        open the panel

Drag any window onto another to split that tile - top/bottom half for rows,
left/right for columns. Drop again to add a third.

Requires macOS 14 or later. Universal: Apple Silicon and Intel.
TXT
else
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Macnizer
========

1. Drag Macnizer onto the Applications folder.

2. IMPORTANT - the first launch needs a right-click.
   In Applications, RIGHT-CLICK Macnizer and choose "Open", then click
   "Open" again in the dialog. Double-clicking will NOT work the first time:
   this build is not notarised by Apple, so macOS says the developer "cannot
   be verified". After the first right-click-Open it launches normally.

   If macOS still refuses:
       xattr -dr com.apple.quarantine /Applications/Macnizer.app

3. Grant Accessibility access when asked.
   System Settings > Privacy & Security > Accessibility > switch Macnizer on.

4. Optional - the Tabs pane asks for Automation access per browser.
   Macnizer reads only tab titles and URLs, never page content.

Macnizer lives in the menu bar and has no Dock icon.

    Option-Command-T        pause / resume arranging
    Option-Command-Space    next layout
    Option-Command-R        arrange now
    Option-Command-O        open the panel

Drag any window onto another to split that tile - top/bottom half for rows,
left/right for columns.

Requires macOS 14 or later. Universal: Apple Silicon and Intel.
TXT
fi

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

if $RELEASE; then
    echo "==> Signing the disk image"
    codesign --force --timestamp --sign "$DEVID" "$DMG"

    echo "==> Notarising (a few minutes; Apple scans the binary)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    # Stapling attaches the notarisation ticket to the file itself, so it opens
    # cleanly even on a Mac with no internet connection.
    echo "==> Stapling the ticket"
    xcrun stapler staple "$DMG"

    echo "==> Verifying as Gatekeeper sees it"
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -3
fi

echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
echo "    architectures: $(lipo -archs "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}")"
if $RELEASE; then echo "    notarised and stapled — opens with a normal double-click"; fi
