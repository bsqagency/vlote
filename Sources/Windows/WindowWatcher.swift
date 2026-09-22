import AppKit
import ApplicationServices

/// C callbacks cannot capture context, so the watcher passes itself through the
/// refcon pointer and unwraps it here. The source is attached to the main run
/// loop, so this already arrives on the main thread.
private let axCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    Unmanaged<WindowWatcher>.fromOpaque(refcon)
        .takeUnretainedValue()
        .handle(notification as String)
}

/// Turns window events into re-layouts.
///
/// Two distinct paths, because they need very different handling:
///
/// - **Structural** (opened, closed, minimised) -> full retile. The set of
///   windows changed, so the arrangement has to be recomputed.
/// - **Moved or resized** -> drift check. Something knocked a window off its
///   tile; put that one window back without disturbing anything else.
///
/// The drift path is the dangerous one: we write frames ourselves, and apps
/// push back on sizes they dislike, so naive handling turns into an endless
/// fight. See `Tiler.correctDrift` for the guards.
final class WindowWatcher {
    static let shared = WindowWatcher()

    private var observers: [pid_t: AXObserver] = [:]
    private var pendingRetile: DispatchWorkItem?
    private var pendingDrift: DispatchWorkItem?
    private var isRunning = false

    private static let structural: Set<String> = [
        kAXWindowCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXApplicationHiddenNotification as String,
        kAXApplicationShownNotification as String,
    ]

    private static let positional: Set<String> = [
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
    ]

    private static var watched: [String] { Array(structural) + Array(positional) }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { Diagnostics.shared.log("watcher already running"); return }
        guard AX.isTrusted else {
            Diagnostics.shared.log("watcher NOT started — accessibility not trusted")
            return
        }
        isRunning = true

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(to: app)
        }

        let wsCenter = NSWorkspace.shared.notificationCenter

        wsCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                             object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.attach(to: app)
            self?.scheduleRetile()
        }

        wsCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                             object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.detach(pid: app.processIdentifier)
            }
            self?.scheduleRetile()
        }

        // Each Space has its own set of on-screen windows, so a Space switch is
        // effectively a whole new window set.
        wsCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                             object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRetile()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRetile(delay: 0.5)   // let the display settle first
        }

        Diagnostics.shared.log("watching \(observers.count) apps")
        scheduleRetile()
    }

    func stop() {
        pendingRetile?.cancel(); pendingRetile = nil
        pendingDrift?.cancel(); pendingDrift = nil
        for pid in observers.keys { detach(pid: pid) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isRunning = false
    }

    // MARK: - Routing

    func handle(_ notification: String) {
        if Self.positional.contains(notification) {
            scheduleDriftCheck()
        } else if Self.structural.contains(notification) {
            scheduleRetile()
        }
    }

    // MARK: - Per-app observers

    private func attach(to app: NSRunningApplication, retriesLeft: Int = 3) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil
        else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success,
              let observer
        else {
            // An app that has only just launched may not have an AX server yet.
            if retriesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard !app.isTerminated else { return }
                    self?.attach(to: app, retriesLeft: retriesLeft - 1)
                }
            }
            return
        }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var attached = false
        for notification in Self.watched {
            if AXObserverAddNotification(observer, element, notification as CFString, refcon) == .success {
                attached = true
            }
        }
        guard attached else { return }

        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }

    // MARK: - Debounce

    /// Opening a window fires several notifications in a burst, and apps often
    /// resize a window a few times while it is coming up. Coalescing means one
    /// retile per burst instead of a visible scramble.
    func scheduleRetile(delay: TimeInterval = 0.28) {
        guard Settings.shared.autoTile else { return }
        pendingRetile?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, Settings.shared.autoTile, !Tiler.shared.isApplying else { return }
            self.pendingRetile = nil
            Tiler.shared.retile()
        }
        pendingRetile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Dragging a window emits a move event per frame, so this waits for the
    /// gesture to finish rather than correcting mid-drag.
    func scheduleDriftCheck(delay: TimeInterval = 0.35) {
        guard Settings.shared.autoTile, Settings.shared.snapBack else { return }
        pendingDrift?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDrift = nil
            Tiler.shared.correctDrift()
        }
        pendingDrift = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
