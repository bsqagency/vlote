import AppKit
import CoreImage

/// Lazily-built blurred / pixelated copies of the base image, used to fill redaction regions.
/// Redaction is baked into exported pixels, so it cannot be undone from the shared file.
final class RedactionCache {
    private let base: CGImage
    private let scale: CGFloat
    private var blurred: CGImage?
    private var pixelated: CGImage?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init(base: CGImage, scale: CGFloat) { self.base = base; self.scale = scale }

    func image(for kind: Annotation.Kind) -> CGImage? {
        switch kind {
        case .blur:
            if blurred == nil { blurred = render { ci in
                let f = CIFilter(name: "CIGaussianBlur")!
                f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
                f.setValue(16 * self.scale, forKey: kCIInputRadiusKey)
                return f.outputImage
            } }
            return blurred
        case .pixelate:
            if pixelated == nil { pixelated = render { ci in
                let f = CIFilter(name: "CIPixellate")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
                f.setValue(12 * self.scale, forKey: kCIInputScaleKey)
                return f.outputImage
            } }
            return pixelated
        default: return nil
        }
    }

    private func render(_ filter: (CIImage) -> CIImage?) -> CGImage? {
        let input = CIImage(cgImage: base)
        guard let out = filter(input)?.cropped(to: input.extent) else { return nil }
        return Self.context.createCGImage(out, from: input.extent, format: .BGRA8, colorSpace: base.colorSpace ?? ImageOps.sRGB)
    }
}

/// Draws a base image plus annotations into any CGContext whose coordinate system is **top-left origin**
/// (a flipped NSView context, or an export bitmap that has been flipped). One code path serves both the
/// live canvas and the exported file, so what you see is exactly what you get.
struct AnnotationRenderer {
    let base: CGImage
    let scale: CGFloat
    let redaction: RedactionCache

    init(base: CGImage, scale: CGFloat, redaction: RedactionCache? = nil) {
        self.base = base
        self.scale = scale
        self.redaction = redaction ?? RedactionCache(base: base, scale: scale)
    }

    var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    func draw(_ annotations: [Annotation], in ctx: CGContext, hiding hidden: UUID? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ImageOps.drawUpright(base, in: imageRect, ctx)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations where a.id != hidden { draw(a, in: ctx) }
    }

    private func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)

        switch a.kind {
        case .line:
            ctx.move(to: a.start); ctx.addLine(to: a.end); ctx.strokePath()

        case .arrow:
            let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let head = min(length, a.lineWidth * 3.5 + 6 * scale)
            let angle = atan2(dy, dx)
            let spread: CGFloat = 0.46
            let baseCentre = CGPoint(x: a.end.x - cos(angle) * head * 0.8, y: a.end.y - sin(angle) * head * 0.8)
            ctx.move(to: a.start); ctx.addLine(to: baseCentre); ctx.strokePath()
            ctx.move(to: a.end)
            ctx.addLine(to: CGPoint(x: a.end.x - head * cos(angle - spread), y: a.end.y - head * sin(angle - spread)))
            ctx.addLine(to: CGPoint(x: a.end.x - head * cos(angle + spread), y: a.end.y - head * sin(angle + spread)))
            ctx.closePath(); ctx.fillPath()

        case .rectangle:
            ctx.stroke(a.normalizedRect)

        case .ellipse:
            ctx.strokeEllipse(in: a.normalizedRect)

        case .pen:
            strokePath(a.points, width: a.lineWidth, in: ctx)

        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.55)
            ctx.setLineCap(.butt)
            strokePath(a.points, width: a.lineWidth, in: ctx)

        case .text:
            (a.text as NSString).draw(at: a.start, withAttributes: a.textAttributes)

        case .step:
            ctx.fillEllipse(in: a.bounds)
            let label = "\(a.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)

        case .blur, .pixelate:
            guard let filtered = redaction.image(for: a.kind) else { return }
            ctx.clip(to: a.normalizedRect)
            ImageOps.drawUpright(filtered, in: imageRect, ctx)

        case .spotlight:
            let hole = CGPath(roundedRect: a.normalizedRect, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil)
            ctx.addRect(imageRect.insetBy(dx: -1, dy: -1))
            ctx.addPath(hole)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fillPath(using: .evenOdd)
        }
    }

    private func strokePath(_ pts: [CGPoint], width: CGFloat, in ctx: CGContext) {
        guard let first = pts.first else { return }
        if pts.count == 1 {
            let r = width / 2
            ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
            return
        }
        // Quadratic smoothing through segment midpoints removes mouse-sampling jaggies.
        ctx.move(to: first)
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            ctx.addQuadCurve(to: mid, control: pts[i - 1])
        }
        ctx.addLine(to: pts[pts.count - 1])
        ctx.strokePath()
    }

    /// Flattens base + annotations (+ optional crop) into a new bitmap in the base image's colour space.
    func export(_ annotations: [Annotation], crop: CGRect?) -> CGImage? {
        var region = imageRect
        if let crop {
            let clipped = crop.integral.intersection(imageRect)
            if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 { region = clipped }
        }
        let w = Int(region.width), h = Int(region.height)
        guard let ctx = ImageOps.makeContext(width: w, height: h, colorSpace: base.colorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -region.minX, y: -region.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(annotations, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
