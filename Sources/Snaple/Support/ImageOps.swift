import CoreGraphics
import Foundation

/// Pure CoreGraphics helpers. No AppKit, no global state — easy to unit test.
enum ImageOps {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        for cs in [colorSpace, sRGB].compactMap({ $0 }) {
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) {
                return ctx
            }
        }
        return nil
    }

    /// Converts a rect in view points (top-left origin) to an integral, clamped pixel rect.
    static func pixelRect(for pointRect: CGRect, scale: CGFloat, in image: CGImage) -> CGRect {
        let r = CGRect(x: pointRect.minX * scale, y: pointRect.minY * scale,
                       width: pointRect.width * scale, height: pointRect.height * scale)
        let integral = CGRect(x: floor(r.minX), y: floor(r.minY),
                              width: ceil(r.maxX) - floor(r.minX), height: ceil(r.maxY) - floor(r.minY))
        return integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Crops into a *new* bitmap. `CGImage.cropping` shares the parent's pixel buffer, which would keep an
    /// entire 5K display frame alive behind a small thumbnail — a real cost against the idle-RAM budget.
    static func copy(_ image: CGImage, cropping rect: CGRect) -> CGImage? {
        guard !rect.isEmpty, let cropped = image.cropping(to: rect),
              let ctx = makeContext(width: cropped.width, height: cropped.height, colorSpace: image.colorSpace) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return ctx.makeImage()
    }

    /// Soft drop shadow around an image (used for window captures; the system shadow is not captured).
    static func addShadow(to image: CGImage, scale: CGFloat) -> CGImage {
        let pad = Int(64 * scale)
        let w = image.width + pad * 2, h = image.height + pad * 2
        guard let ctx = makeContext(width: w, height: h, colorSpace: image.colorSpace) else { return image }
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
                      color: CGColor(gray: 0, alpha: 0.38))
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// sRGB value of one pixel (top-left pixel coordinates).
    static func pixelColor(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let px = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var out: (UInt8, UInt8, UInt8)?
        var buffer = [UInt8](repeating: 0, count: 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let p = raw.bindMemory(to: UInt8.self)
            out = (p[0], p[1], p[2])
        }
        return out.map { (r: $0.0, g: $0.1, b: $0.2) }
    }

    /// Draws an image upright into a context whose coordinate system is top-left (flipped).
    static func drawUpright(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Small JPEG preview for library grids (white-backed so transparent window corners don't turn black).
    static func thumbnailJPEG(_ image: CGImage, maxPixel: Int, quality: CGFloat = 0.72) -> Data? {
        let longest = max(image.width, image.height)
        let factor = min(1, CGFloat(maxPixel) / CGFloat(longest))
        let w = max(1, Int((CGFloat(image.width) * factor).rounded())), h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let ctx = makeContext(width: w, height: h, colorSpace: sRGB) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return ImageEncoder.data(for: out, scale: 1, format: .jpeg, quality: quality)
    }
}
