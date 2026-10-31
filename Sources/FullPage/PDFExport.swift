import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Formats offered by the Full Page preview window's Download menu.
enum FullPageFormat: String, CaseIterable, Identifiable {
    case png, jpg, pdf

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .png: return "PNG"
        case .jpg: return "JPG"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .pdf: return .pdf
        }
    }
}

/// Step 6: encodes the stitched image. PNG and JPG reuse Snaple's ImageEncoder (CGImageDestination).
/// PDF is split into A4 pages, cutting at blank rows where possible.
enum PDFExport {
    static let pageWidth: CGFloat = 595
    static let pageHeight: CGFloat = 842

    /// How far above a page boundary we look for a blank row, in image pixels.
    static let searchRange = 120
    /// Mean row brightness (0–255) at or above which a row counts as background (white-ish).
    static let blankLevel: Double = 248

    static func data(for image: CGImage, format: FullPageFormat, scale: CGFloat) -> Data? {
        switch format {
        case .png:
            return ImageEncoder.data(for: image, scale: scale, format: .png)
        case .jpg:
            guard let flat = flattened(image) else { return nil }
            return ImageEncoder.data(for: flat, scale: scale, format: .jpeg, quality: 0.9)
        case .pdf:
            return pdfData(image)
        }
    }

    /// Returns the interior cut rows (exclusive of 0 and the image height), ascending.
    /// `pageHeight` is in image pixels. Each cut sits on a blank row within `searchRange` above
    /// its boundary, or exactly on the boundary when none is found.
    static func pageCuts(for image: CGImage, pageHeight: Int) -> [Int] {
        guard let means = rowMeans(of: image) else { return [] }
        return pageCuts(rowMeans: means, pageHeight: pageHeight)
    }

    /// Pure version of `pageCuts(for:pageHeight:)` working on per-row mean brightness, for tests.
    static func pageCuts(rowMeans: [Double], pageHeight: Int) -> [Int] {
        let height = rowMeans.count
        guard pageHeight > 0, height > pageHeight else { return [] }

        var cuts: [Int] = []
        var previous = 0
        var boundary = pageHeight
        while boundary < height {
            var cut = boundary
            let lowest = max(previous + 1, boundary - searchRange)
            var row = boundary
            while row >= lowest {
                if rowMeans[row] >= blankLevel { cut = row; break }
                row -= 1
            }
            cuts.append(cut)
            previous = cut
            boundary += pageHeight
        }
        return cuts
    }

    /// A4 PDF: the image is scaled to the page width and split into page-height slices.
    static func pdfData(_ image: CGImage) -> Data? {
        let width = CGFloat(image.width)
        let height = image.height
        let pointsPerPixel = pageWidth / width
        let pageHeightPx = Int((pageHeight / pointsPerPixel).rounded(.down))

        let cuts = pageCuts(for: image, pageHeight: pageHeightPx)
        let bounds = [0] + cuts + [height]

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        for index in 0..<(bounds.count - 1) {
            let top = bounds[index]
            let bottom = bounds[index + 1]
            guard bottom > top else { continue }

            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(box)
            if let slice = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)) {
                let sliceHeight = CGFloat(bottom - top) * pointsPerPixel
                // PDF origin is bottom-left, so the slice hangs from the top of the page.
                ctx.draw(slice, in: CGRect(x: 0, y: pageHeight - sliceHeight, width: pageWidth, height: sliceHeight))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: - Helpers

    /// Draws the image over a white background, dropping any alpha.
    private static func flattened(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Mean grey level of each row, top row first, over a white background.
    private static func rowMeans(of image: CGImage) -> [Double]? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = ctx.data else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Bitmap memory row 0 is the top of the drawn image.
        let pixels = base.bindMemory(to: UInt8.self, capacity: w * h)
        var means = [Double](repeating: 0, count: h)
        for row in 0..<h {
            var sum = 0
            let start = row * w
            for col in 0..<w { sum += Int(pixels[start + col]) }
            means[row] = Double(sum) / Double(w)
        }
        return means
    }
}
