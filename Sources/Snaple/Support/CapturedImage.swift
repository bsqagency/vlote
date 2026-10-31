import CoreGraphics
import Foundation

/// One finished capture. `image` is always the untouched pixels; edits live separately as `DocumentState`.
struct CapturedImage {
    let id: UUID
    let image: CGImage
    /// Device pixels per point at capture time (2 on Retina). Used for DPI metadata and point-size display.
    let scale: CGFloat
    let createdAt: Date

    init(id: UUID = UUID(), image: CGImage, scale: CGFloat, createdAt: Date = Date()) {
        self.id = id; self.image = image; self.scale = scale; self.createdAt = createdAt
    }

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

enum CaptureError: LocalizedError {
    case noDisplay, windowNotFound, failed(String)
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available to capture."
        case .windowNotFound: return "That window is no longer available."
        case .failed(let why): return why
        }
    }
}
