import AppKit
import Foundation

// Unit checks for clipboard history: dedup, size limit, display clamp, concealed skip,
// self-write check, ignored apps, pins, plain-text copy, helper-app filter. Compiled with test.sh (cliptests).
// Top-level code: keep this the only main file in the binary.
// Each case uses its own named pasteboard, so the real clipboard is never touched.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("  FAIL: \(message)") }
}

final class FrontBox {
    var id: String? = "com.test.editor"
}

final class Harness {
    let pasteboard: NSPasteboard
    let supportDir: URL
    /// Bundle ID the fake frontmost app reports. Read through a box so the closure can see changes.
    let front: FrontBox
    var frontmost: String? { get { front.id } set { front.id = newValue } }
    let store: ClipStore

    init() {
        let pb = NSPasteboard(name: NSPasteboard.Name("vlote.test.\(UUID().uuidString)"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlote-cliptests-\(UUID().uuidString)", isDirectory: true)
        let box = FrontBox()
        front = box
        pasteboard = pb
        supportDir = dir
        store = ClipStore(pasteboard: pb, supportDir: dir,
                          frontmostBundleID: { box.id }, startTimer: false)
    }

    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func cleanup() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: supportDir)
    }
}

func resetPrefs() {
    let p = ClipPreferences.shared
    p.historySize = 100
    p.displayCount = 20
    p.recordHistory = true
    UniversalIgnore.shared.ignoredBundleIDs = []
    p.confirmDelete = true
}

// ---- Cases ----

func testDuplicateConsecutiveTextNotAddedTwice() {
    resetPrefs()
    let h = Harness()
    h.write("hello")
    h.store.poll()
    h.write("hello")
    h.store.poll()
    check(h.store.clips.count == 1, "duplicate consecutive text added twice (count \(h.store.clips.count))")
    h.write("world")
    h.store.poll()
    check(h.store.clips.count == 2, "distinct text after duplicate not added")
    h.cleanup()
}

func testHistoryNeverExceedsSize() {
    resetPrefs()
    ClipPreferences.shared.historySize = 10
    let h = Harness()
    for i in 0..<15 {
        h.write("item \(i)")
        h.store.poll()
    }
    check(h.store.clips.count == 10, "history has \(h.store.clips.count) clips, expected 10")
    check(h.store.clips.first?.text == "item 14", "newest clip not first")
    check(h.store.clips.last?.text == "item 5", "oldest clips not dropped")
    h.cleanup()
}

func testDisplayClampedToHistory() {
    check(ClipPreferences.clampedDisplayCount(50, historySize: 10) == 10, "display 50 with history 10 not clamped to 10")
    check(ClipPreferences.clampedDisplayCount(0, historySize: 10) == 1, "display 0 not raised to 1")
    check(ClipPreferences.clampedDisplayCount(5, historySize: 10) == 5, "display 5 changed unexpectedly")
    check(ClipPreferences.clampedDisplayCount(5, historySize: 0) == 1, "history 0 not handled")
}

func testConcealedTypeSkipped() {
    resetPrefs()
    let h = Harness()
    h.pasteboard.clearContents()
    h.pasteboard.setString("secret-password", forType: .string)
    h.pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    h.store.poll()
    check(h.store.clips.isEmpty, "concealed pasteboard item was recorded")
    h.cleanup()
}

func testSelfWriteNotRecorded() {
    resetPrefs()
    let h = Harness()
    let clip = Clip(id: UUID(), kind: .text, text: "from history", imageFile: nil,
                    sourceApp: nil, date: Date())
    h.store.copyToPasteboard(clip)
    check(h.store.ownChangeCount == h.pasteboard.changeCount, "ownChangeCount not set to our write")
    h.store.poll()
    check(h.store.clips.isEmpty, "our own write was re-recorded")
    h.cleanup()
}

func testIgnoredBundleNotRecorded() {
    resetPrefs()
    UniversalIgnore.shared.ignoredBundleIDs = ["com.test.ignored"]
    let h = Harness()
    h.frontmost = "com.test.ignored"
    h.write("password manager text")
    h.store.poll()
    check(h.store.clips.isEmpty, "ignored app's copy was recorded")
    h.frontmost = "com.test.editor"
    h.write("normal text")
    h.store.poll()
    check(h.store.clips.count == 1, "non-ignored app's copy was not recorded")
    h.cleanup()
}

func testPinnedSurvivesTrimAndSortsFirst() {
    resetPrefs()
    ClipPreferences.shared.historySize = 3
    let h = Harness()
    h.write("pin me")
    h.store.poll()
    h.store.togglePin(h.store.clips[0])
    for i in 0..<5 {
        h.write("a\(i)")
        h.store.poll()
    }
    check(h.store.clips.contains { $0.text == "pin me" && $0.pinned }, "pinned clip was trimmed")
    check(h.store.clips.first?.text == "pin me", "pinned clip not sorted first")
    check(h.store.clips.count == 4, "expected 1 pinned + 3 unpinned, got \(h.store.clips.count)")
    h.cleanup()
}

func testOldJSONDecodesUnpinned() {
    let json = #"{"id":"E031A120-E9F3-4E7D-BDB8-515EF268BD41","kind":"text","text":"old","sourceApp":"Notes","date":815122186.5}"#
    let clip = try? JSONDecoder().decode(Clip.self, from: Data(json.utf8))
    check(clip != nil, "old JSON without pinned failed to decode")
    check(clip?.pinned == false, "old JSON clip not unpinned")
    check(clip?.text == "old", "old JSON text not decoded")
}

func testDisplayClampsWhenHistoryShrinks() {
    check(ClipPreferences.clampedDisplayCount(20, historySize: 15) == 15, "display 20 with history 15 not clamped to 15")
}

func testPlainTextCopyWritesOnlyString() {
    resetPrefs()
    let h = Harness()
    let clip = Clip(id: UUID(), kind: .text, text: "plain words", imageFile: nil, sourceApp: nil, date: Date())
    h.store.copyToPasteboard(clip, plainText: true)
    check(h.pasteboard.string(forType: .string) == "plain words", "plain-text copy did not write the string")
    let types = h.pasteboard.types ?? []
    check(!types.contains(.rtf) && !types.contains(.html) && !types.contains(.rtfd), "plain-text copy wrote rich types")
    h.cleanup()
}

func testHelperAppFilter() {
    check(ClipAppFilter.isHelperName("QuickLookUIService"), "QuickLookUIService not treated as helper")
    check(!ClipAppFilter.isHelperName("Safari"), "Safari treated as helper")
    check(ClipAppFilter.isListable(displayName: "Safari", fileName: "Safari.app", uiElement: false, backgroundOnly: false),
          "Safari.app not listed")
    check(!ClipAppFilter.isListable(displayName: "QuickLookUIService", fileName: "QuickLookUIService.app",
                                    uiElement: false, backgroundOnly: false), "QuickLookUIService listed")
    check(!ClipAppFilter.isListable(displayName: "Menu Thing", fileName: "Menu Thing.app",
                                    uiElement: true, backgroundOnly: false), "LSUIElement app listed")
}

// ---- Run ----
testPinnedSurvivesTrimAndSortsFirst()
testOldJSONDecodesUnpinned()
testDisplayClampsWhenHistoryShrinks()
testPlainTextCopyWritesOnlyString()
testHelperAppFilter()

testDuplicateConsecutiveTextNotAddedTwice()
testHistoryNeverExceedsSize()
testDisplayClampedToHistory()
testConcealedTypeSkipped()
testSelfWriteNotRecorded()
testIgnoredBundleNotRecorded()

if failures == 0 {
    print("Clipboard tests passed")
} else {
    print("Clipboard tests: \(failures) failure(s)")
    exit(1)
}
