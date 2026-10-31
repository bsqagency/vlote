import CoreGraphics

/// Step 4: joins the slices into one image at device pixel scale.
enum Stitcher {

    /// Places each slice at `scrollY × dpr` on a canvas of `totalHeight` device pixels.
    /// A slice only fills rows not already drawn, so a later overlapping slice never covers
    /// the first slice (which holds the fixed/sticky elements).
    static func stitch(_ slices: [CapturedSlice], totalHeight: Int, dpr: CGFloat) throws -> CGImage {
        guard let first = slices.first else { throw FullPageError.noSlices }
        let width = first.image.width
        let height = max(1, totalHeight)

        let colorSpace = first.image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FullPageError.bitmapFailed }

        var covered = 0   // rows from the top already drawn
        for slice in slices {
            let top = Int((slice.scrollY * Double(dpr)).rounded())
            let sliceHeight = slice.image.height
            let start = max(top, covered)
            let end = min(top + sliceHeight, height)
            if start > covered {
                fpLog("stitch gap of \(start - covered) px before row \(start)")
            }
            guard end > start else { continue }

            let cropRect = CGRect(x: 0, y: start - top, width: slice.image.width, height: end - start)
            guard let part = slice.image.cropping(to: cropRect) else { throw FullPageError.cropFailed }

            // Core Graphics origin is bottom-left; rows are counted from the top.
            ctx.draw(part, in: CGRect(x: 0, y: height - end, width: width, height: end - start))
            covered = end
        }

        guard let image = ctx.makeImage() else { throw FullPageError.bitmapFailed }
        return image
    }
}
