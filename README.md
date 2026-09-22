# Macnizer

A menu bar app that keeps your Mac tidy without being asked: it arranges every
open window into a clean layout automatically, and gives you one place to see and
cull the browser tabs piling up across Chrome, Brave, Edge, Arc, Vivaldi and Safari.

Built for macOS 14+. No Xcode required — Command Line Tools are enough.

## Setup

```bash
./setup-signing.sh
./build.sh
open build/Macnizer.app
```

`setup-signing.sh` runs once and creates a self-signed code-signing identity in
your login keychain. Without it the app is ad-hoc signed, and macOS revokes its
permissions on every single rebuild — see *Why signing matters* below.

On first launch Macnizer asks for **Accessibility** access. This is not optional:
macOS gives no other way to move another app's windows. Approve it under
**System Settings › Privacy & Security › Accessibility**, and arranging starts
immediately — no relaunch.

The first time you open the **Tabs** pane, each browser separately asks for
**Automation** access. Macnizer reads only tab titles and URLs; it has no way to
see page contents.

To launch at login: System Settings › General › Login Items › **+**, and pick
`build/Macnizer.app`.

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
- **Apple Silicon only.** `build.sh` targets `arm64`. Add `-target
  x86_64-apple-macosx14.0` and `lipo` the results for a universal binary.
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

The certificate is deliberately **not** marked as trusted. `codesign` does not
require trust to sign, and leaving trust settings alone means the setup runs
without any authorisation prompt. Importing with `-T /usr/bin/codesign`
pre-authorises signing, so builds never stop to ask for keychain access.

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
    DropOverlay.swift     The highlight showing where a drop will land
    PanelView.swift       The SwiftUI panel
```
