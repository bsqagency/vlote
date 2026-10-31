import Foundation
import CoreGraphics

// Test-only stand-ins for the types Stitcher and PDFExport need from the capture flow.
// SliceCapture.swift and FullPageCapture.swift depend on the whole app, so test.sh does not compile them.
// Keep these in step with the originals (CapturedSlice, FullPageError, fpLog).

struct CapturedSlice {
    let image: CGImage
    let scrollY: Double
}

enum FullPageError: Error {
    case noSlices
    case cropFailed
    case bitmapFailed
}

func fpLog(_ message: String) {}
