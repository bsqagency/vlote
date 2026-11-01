import AppKit
import Foundation

// Headless checks for the universal ignore list: migration, union, isIgnored,
// isTooSmall, persistence, and the helper-process filter. Compiled with test.sh.

var failures = 0

func check(_ cond: Bool, _ msg: String) {
    if !cond {
        failures += 1
        print("FAIL: \(msg)")
    }
}

let suiteName = "vlote.ignore.tests"
func freshDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: suiteName)!
    d.removePersistentDomain(forName: suiteName)
    return d
}

func testMigrationTakesUnion() {
    let d = freshDefaults()
    d.set(["com.apple.finder", "com.a"], forKey: "floatedApps")
    d.set(["com.a", "com.b"], forKey: "clip.ignoredBundleIDs")
    d.set(300.0, forKey: "minWindowSize")
    let u = UniversalIgnore(defaults: d)
    check(u.ignoredBundleIDs == ["com.apple.finder", "com.a", "com.b"], "migration did not take the union")
    check(u.minimumWindowSize == 300, "migration did not carry the minimum size")
    check(d.bool(forKey: UniversalIgnore.migratedKey), "migration was not marked done")
    check(UniversalIgnore.migratedIDs(organize: ["x"], clip: ["y", "x"]) == ["x", "y"], "pure union is wrong")
}

func testMigrationRunsOnce() {
    let d = freshDefaults()
    d.set(["com.a"], forKey: "clip.ignoredBundleIDs")
    _ = UniversalIgnore(defaults: d)
    d.set(["z"], forKey: "clip.ignoredBundleIDs")
    let again = UniversalIgnore(defaults: d)
    check(!again.ignoredBundleIDs.contains("z"), "migration ran a second time")
    check(again.ignoredBundleIDs.contains("com.a"), "migrated list lost on relaunch")
}

func testIsIgnored() {
    let u = UniversalIgnore(defaults: freshDefaults())
    u.ignoredBundleIDs = ["com.test.ignored"]
    check(!u.isIgnored(bundleID: nil), "nil bundle should not be ignored")
    check(u.isIgnored(bundleID: "com.test.ignored"), "listed app not ignored")
    check(!u.isIgnored(bundleID: "com.test.other"), "unlisted app ignored")
}

func testIsTooSmall() {
    let u = UniversalIgnore(defaults: freshDefaults())
    u.minimumWindowSize = 220
    check(u.isTooSmall(CGSize(width: 150, height: 400)), "narrow window not too small")
    check(u.isTooSmall(CGSize(width: 400, height: 150)), "short window not too small")
    check(!u.isTooSmall(CGSize(width: 300, height: 300)), "large window too small")
    check(!u.isTooSmall(CGSize(width: 220, height: 220)), "boundary size should be allowed")
}

func testPersistence() {
    let d = freshDefaults()
    let a = UniversalIgnore(defaults: d)
    a.ignoredBundleIDs = ["com.x", "com.y"]
    a.minimumWindowSize = 412
    let b = UniversalIgnore(defaults: d)
    check(b.ignoredBundleIDs == ["com.x", "com.y"], "ignore list did not survive restart")
    check(b.minimumWindowSize == 412, "minimum size did not survive restart")
}

func testHelperNamesFiltered() {
    check(!ClipAppFilter.isListable(displayName: "QuickLookUIService", fileName: "QuickLookUIService.app",
                                    uiElement: false, backgroundOnly: false), "helper service listed")
    check(!ClipAppFilter.isListable(displayName: "Foo Helper", fileName: "Foo Helper.app",
                                    uiElement: false, backgroundOnly: false), "helper listed")
    check(!ClipAppFilter.isListable(displayName: "Notes", fileName: "Notes.app",
                                    uiElement: true, backgroundOnly: false), "UI-element app listed")
    check(ClipAppFilter.isListable(displayName: "Notes", fileName: "Notes.app",
                                   uiElement: false, backgroundOnly: false), "normal app not listed")
}

testMigrationTakesUnion()
testMigrationRunsOnce()
testIsIgnored()
testIsTooSmall()
testPersistence()
testHelperNamesFiltered()

UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)

if failures == 0 {
    print("Ignore tests passed")
} else {
    print("\(failures) ignore test(s) failed")
    exit(1)
}
