# Macnizer

A menu bar app that keeps your Mac tidy without being asked: it arranges every
open window into a clean layout automatically, and gives you one place to see and
cull the browser tabs piling up across Chrome, Brave, Edge, Arc, Vivaldi and Safari.

Built for macOS 14+, universal (Apple Silicon and Intel). No Xcode required —
Command Line Tools are enough.

## Built with

| | |
|---|---|
| **Swift 6** | The whole app. No third-party dependencies at all. |
| **AppKit** | Menu bar item, popover, the drag-preview overlay window. |
| **SwiftUI** | The panel UI, hosted inside an AppKit popover. |
| **Accessibility API** (`AXUIElement`) | Reading and moving other apps' windows. The only supported way to do this on macOS, and why the app needs Accessibility permission. |
| **Core Graphics window list** | Filtering to windows on the *current* Space. |
| **Carbon** (`RegisterEventHotKey`) | Global hotkeys. Still the only way to get one without Input Monitoring permission. |
| **AppleScript** (`NSAppleScript`) | Reading and closing browser tabs. |
| **Core Graphics** | Drawing the app icon (`tools/make-icon.swift`) and the menu bar glyph (`StatusIcon.swift`). |
| `swiftc`, `lipo`, `codesign`, `hdiutil`, `iconutil`, `notarytool` | Build and packaging. No Xcode project, no SwiftPM. |

## Setup

```bash
./build.sh
open build/Macnizer.app
```

If you have an Apple **Developer ID Application** certificate installed,
`build.sh` uses it automatically — for development as well as release. That is
the best case: one identity everywhere, a designated requirement that never
changes, and permissions that stay granted across rebuilds.

Without one, run `./setup-signing.sh` first. It creates a self-signed identity,
which achieves the same permission stability locally. Failing both, the app is
ad-hoc signed and macOS revokes its permissions on every single rebuild — see
*Why signing matters* below.

On first launch Macnizer asks for **Accessibility** access. This is not optional:
macOS gives no other way to move another app's windows. Approve it under
**System Settings › Privacy & Security › Accessibility**, and arranging starts
immediately — no relaunch.

The first time you open the **Tabs** pane, each browser separately asks for
**Automation** access. Macnizer reads only tab titles and URLs; it has no way to
see page contents.

To launch at login: System Settings › General › Login Items › **+**, and pick
`build/Macnizer.app`.

## Giving it to someone else

```bash
./package.sh            # ad-hoc: recipients must right-click > Open
./package.sh --release  # Developer ID + notarised: opens with a double-click
```

Both produce `dist/Macnizer-1.0.dmg` — universal, with an Applications symlink
and install notes.

## Publishing

With a paid Apple Developer account, `--release` removes the Gatekeeper warning
entirely. Four one-time setup steps, then a single command forever after.

**1. Create a Developer ID Application certificate.** Without Xcode, by hand:

- Keychain Access › Certificate Assistant › *Request a Certificate From a
  Certificate Authority*. Enter your email, choose **Saved to disk**.
- At [developer.apple.com/account/resources/certificates/add](https://developer.apple.com/account/resources/certificates/add),
  choose **Developer ID Application**, upload the request, download the `.cer`.
- Double-click the `.cer` to install. Confirm with:

  ```bash
  security find-identity -v -p codesigning | grep "Developer ID"
  ```

**2. Create an app-specific password** at [appleid.apple.com](https://appleid.apple.com)
› Sign-In and Security › App-Specific Passwords. Your normal Apple password will
not work for notarisation.

**3. Find your Team ID** — the 10-character code on your account's Membership page.

**4. Store the notarisation credentials once.** Interactive, and deliberately not
scripted here, so no credential ever touches this repository:

```bash
xcrun notarytool store-credentials "macnizer-notary" \
    --apple-id you@example.com --team-id ABCDE12345 --password abcd-efgh-ijkl-mnop
```

Then `./package.sh --release` signs with your Developer ID and the hardened
runtime, builds and signs the disk image, uploads it to Apple, waits for the
scan, staples the ticket and verifies the result. Notarisation usually takes a
few minutes. Stapling matters: it embeds the ticket so the app opens cleanly
even on a Mac with no internet connection.

### Entitlements

The hardened runtime is mandatory for notarisation and blocks Apple Events by
default — which would silently break the Tabs pane, since reading browser tabs
goes through AppleScript. `Resources/Macnizer.entitlements` restores it with
`com.apple.security.automation.apple-events`.

Accessibility needs no entitlement; it is gated purely on the user's approval,
so window tiling is unaffected either way.

### What about the Mac App Store?

A different and harder path, probably not worth it here. App Store apps must be
sandboxed. Window management through the Accessibility API can work under the
sandbox — Magnet and Moom ship that way — but **reading browser tabs over
AppleScript effectively cannot**: it needs temporary-exception Apple Events
entitlements that Apple grants sparingly. Shipping to the App Store would most
likely mean dropping the Tabs feature.

Direct distribution with Developer ID has none of those constraints, no review,
and no revenue share.

## Using it

Macnizer runs in the menu bar. The icon dims when arranging is paused.

| Shortcut | Does |
|---|---|
| `⌥⌘T` | Pause / resume automatic arranging |
| `⌥⌘Space` | Next layout |
| `⌥⌘R` | Arrange now |
| `⌥⌘O` | Open the panel |

Resizing a tiled window snaps it back rather than adjusting the split ratio —
drag windows onto each other to change the arrangement instead.

### Layouts

**Split** (default) recursively halves the screen along its longer edge, so tiles
stay near-square however many windows you have. **Main + Stack** gives one window
most of the screen with the rest beside it. **Columns**, **Rows** and **Grid** do
what they say.

### Arranging by hand

Drag any window onto another and the target tile splits. Drop on the **top or
bottom** half to get rows, the **left or right** half to get columns, and drop
again onto one of those to add a third. A highlight shows where it will land.
Release over empty space and the window snaps back. **Back to this layout** in
the Windows pane clears every manual split.

### Tabs

Scans every running browser and lists the tabs in one place. Duplicates are
detected by normalised URL — tracking parameters (`utm_*`, `fbclid`, `gclid`) and
fragments are stripped first, so the same page reached three different ways still
counts as one. **Close duplicates** keeps one copy of each page and closes the rest.

**Sessions** saves the current set of tabs under a name so you can close
everything and bring it back later. Stored as plain JSON in
`~/Library/Application Support/Macnizer/sessions.json`.

## What it deliberately does not do

**It does not fight you.** Macnizer rearranges when a window opens, closes, is
minimised, or when you switch Space or display — not when you move a window
yourself. Dragging a window somewhere is treated as intent, and it stays there
until the next structural change. Watching for moves would mean reacting to our
own writes and to apps that push back, which is how auto-tilers end up in a
frame-fighting loop.

**It leaves some windows alone**: anything smaller than the minimum size (panels,
inspectors, find bars), windows in native fullscreen, sheets and dialogs, and any
app on the ignore list. System Settings, Finder, Calculator, Preview, Spotify and
a few others start out ignored — edit the list from the Windows pane, which always
offers to ignore whichever app is frontmost.

## Known limits

- **Not notarised.** Fine on this machine; distributing it to anyone else needs
  a real Apple Developer ID and notarisation.
- **Not notarised unless you build with `--release`.** The default DMG needs a
  right-click › Open on first launch.
- **Arc's AppleScript support is partial** — tab listing works, closing individual
  tabs can be unreliable.

## Why signing matters

macOS ties Accessibility and Automation grants to a signature's *designated
requirement*. For an ad-hoc signature that requirement is the binary's `cdhash`:

```
designated => cdhash H"91d22016d3fefdf01db3a7ee6a7895efcd4390c3"
```

That hash changes on every build, so every rebuild silently revoked the grant and
the app had to be re-approved by hand. Signing with a stable self-signed identity
gives a requirement that depends only on the bundle ID and the certificate:

```
designated => identifier "com.brandsquare.macnizer" and certificate leaf = H"3edcf5b9..."
```

Both survive a rebuild, so permissions are granted once and stay granted.

The certificate is deliberately **not** marked as trusted, and does not need to
be: TCC honours the certificate-leaf requirement regardless, which was confirmed
by rebuilding and checking that the grant survived. Leaving trust settings alone
means setup runs without any authorisation prompt, and importing with
`-T /usr/bin/codesign` pre-authorises signing so builds never stop to ask for
keychain access.

**If macOS keeps prompting although the switch is already on**, the entry is
stale - left from an earlier ad-hoc build, which TCC identified by a hash that
changed every rebuild. Clear it and grant once more:

```bash
tccutil reset Accessibility com.brandsquare.macnizer
```

### If the certificate will not sign

`security find-identity -v -p codesigning` reporting **0 valid identities**
while the certificate is plainly there, and Keychain Access shows it paired with
its private key, almost always means Apple's **intermediate CA** is missing, so
the chain cannot reach the Apple root:

```bash
curl -fsSLO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security import DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db
```

Two other traps when requesting the certificate: pick **Developer ID
Application**, not iOS/Apple Distribution (those cannot sign a Mac app for
distribution outside the store), and when double-clicking the downloaded `.cer`
make sure the Keychain dropdown says **login**, not **iCloud** — otherwise the
certificate and its private key land in different keychains and never pair.

## Tests

```bash
./test.sh
```

Checks every layout at 1–9 windows across three gap settings: correct frame count,
no overlaps, nothing escaping the screen, full coverage when gaps are zero, and
that the Cocoa↔Accessibility coordinate flip round-trips exactly.

## Layout of the code

```
Sources/
  main.swift              Entry point; accessory (menu-bar-only) activation
  Core/
    Diagnostics.swift     Status reporting to the log and the panel
    Geometry.swift        Cocoa <-> Accessibility coordinate conversion
    Settings.swift        UserDefaults-backed preferences
    Hotkeys.swift         Global shortcuts via the Carbon hot key API
  Windows/
    AXBridge.swift        Wrappers over the C Accessibility API
    WindowManager.swift   Finds tileable windows; moves and resizes them
    LayoutTree.swift      The arrangement as a tree; splits, drops, presets
    Tiler.swift           Owns one tree per screen and writes frames
    WindowWatcher.swift   Window events -> debounced retile
    DragWatcher.swift     Drag a window onto another -> split that tile
  Tabs/
    BrowserBridge.swift   AppleScript bridge to the browsers
    TabStore.swift        Tab model, duplicate detection, saved sessions
  UI/
    AppDelegate.swift     Lifecycle, permissions, hotkey wiring
    MenuBarController.swift
    StatusIcon.swift      The menu bar glyph, drawn as a template image
    DropOverlay.swift     The highlight showing where a drop will land
    PanelView.swift       The SwiftUI panel
```
