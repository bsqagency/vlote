import AppKit
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator {
    enum Mode { case area, window, fullscreen, repeatLast, ocr, qr }

    private enum Last {
        case region(CGDirectDisplayID, CGRect)
        case window(CGWindowID)
        case fullscreen(CGDirectDisplayID)
    }

    var onCapture: ((CapturedImage) -> Void)?
    /// Remaining seconds while a timed capture counts down; nil when finished.
    var onCountdown: ((Int?) -> Void)?

    private var busy = false
    private var last: Last?

    func start(_ mode: Mode, delay: Int = 0) {
        guard !busy else { return }
        guard Permissions.ensureScreenRecording() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if delay > 0 {
                    for remaining in stride(from: delay, to: 0, by: -1) {
                        onCountdown?(remaining)
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    onCountdown?(nil)
                }
                try await run(mode)
            } catch {
                onCountdown?(nil)
                report(error)
            }
        }
    }

    private func run(_ mode: Mode) async throws {
        let capturer = ScreenCapturer.shared
        let cursor = Preferences.includeCursor

        switch mode {
        case .fullscreen:
            guard let id = displayIDUnderCursor() else { throw CaptureError.noDisplay }
            let r = try await capturer.captureDisplay(id: id, sourceRect: nil, includeCursor: cursor)
            last = .fullscreen(id)
            deliver(r.image, scale: r.scale)

        case .repeatLast:
            switch last {
            case .region(let id, let rect)?:
                let r = try await capturer.captureDisplay(id: id, sourceRect: rect, includeCursor: cursor)
                deliver(r.image, scale: r.scale)
            case .fullscreen(let id)?:
                let r = try await capturer.captureDisplay(id: id, sourceRect: nil, includeCursor: cursor)
                deliver(r.image, scale: r.scale)
            case .window(let id)?:
                try await captureWindow(id)
            case nil:
                Toast.show("Nothing to repeat yet", symbol: "arrow.counterclockwise")
            }

        case .area, .window, .ocr, .qr:
            let frames = try await capturer.captureAllDisplays(includeCursor: cursor)
            let session = SelectionSession(frames: frames, windowMode: mode == .window)
            let result = await withCheckedContinuation { cont in session.begin { cont.resume(returning: $0) } }
            try await handle(result, mode: mode)
        }
    }

    private func handle(_ result: SelectionResult, mode: Mode) async throws {
        switch result {
        case .cancelled:
            return

        case .color(let hex):
            Output.copyText(hex)
            Toast.show("Copied \(hex)", symbol: "eyedropper")

        case .window(let id):
            try await captureWindow(id)

        case .region(let frame, let rect):
            let px = ImageOps.pixelRect(for: rect, scale: frame.scale, in: frame.image)
            guard let cropped = ImageOps.copy(frame.image, cropping: px) else { throw CaptureError.failed("Could not crop the capture.") }
            last = .region(frame.displayID, rect)
            switch mode {
            case .ocr:
                let text = try await Recognizer.text(in: cropped)
                if text.isEmpty { Toast.show("No text found", symbol: "text.magnifyingglass"); return }
                Output.copyText(text)
                Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
            case .qr:
                let codes = try await Recognizer.barcodes(in: cropped)
                guard let first = codes.first else { Toast.show("No QR code or barcode found", symbol: "qrcode.viewfinder"); return }
                Output.copyText(codes.joined(separator: "\n"))
                Toast.show("Copied: " + first.prefix(60), symbol: "qrcode.viewfinder")
            default:
                deliver(cropped, scale: frame.scale)
            }
        }
    }

    private func captureWindow(_ id: CGWindowID) async throws {
        let r = try await ScreenCapturer.shared.captureWindow(id: id)
        last = .window(id)
        deliver(Preferences.windowShadow ? ImageOps.addShadow(to: r.image, scale: r.scale) : r.image, scale: r.scale)
    }

    private func deliver(_ image: CGImage, scale: CGFloat) {
        Output.playShutter()
        onCapture?(CapturedImage(image: image, scale: scale))
    }

    private func displayIDUnderCursor() -> CGDirectDisplayID? {
        let m = NSEvent.mouseLocation
        return (NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main)?.displayID
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
            Permissions.showDeniedAlert()
        } else {
            Toast.show("Capture failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }
}
