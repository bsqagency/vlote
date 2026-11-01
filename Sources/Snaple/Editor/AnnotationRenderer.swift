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

    /// `cornerRadius` (image coordinates) rounds only the base image; annotations stay unclipped.
    /// Export passes 0 so the saved file keeps square corners.
    func draw(_ annotations: [Annotation], in ctx: CGContext, hiding hidden: UUID? = nil, cornerRadius: CGFloat = 0) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.saveGState()
        if cornerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.clip()
        }
        ImageOps.drawUpright(base, in: imageRect, ctx)
        ctx.restoreGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations where a.id != hidden { draw(a, in: ctx) }
    }

    private func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(a.lineWidth)

        switch a.kind {
        case .line:
            paintPath(a, in: ctx, stroke: true) { c in c.move(to: a.start); c.addLine(to: a.end) }

        case .arrow:
            let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let head = min(length, a.lineWidth * 3.5 + 6 * scale)
            let angle = atan2(dy, dx)
            let spread: CGFloat = 0.46
            let baseCentre = CGPoint(x: a.end.x - cos(angle) * head * 0.8, y: a.end.y - sin(angle) * head * 0.8)
            paintPath(a, in: ctx, stroke: true) { c in c.move(to: a.start); c.addLine(to: baseCentre) }
            paintPath(a, in: ctx, stroke: false) { c in
                c.move(to: a.end)
                c.addLine(to: CGPoint(x: a.end.x - head * cos(angle - spread), y: a.end.y - head * sin(angle - spread)))
                c.addLine(to: CGPoint(x: a.end.x - head * cos(angle + spread), y: a.end.y - head * sin(angle + spread)))
                c.closePath()
            }

        case .rectangle:
            paintPath(a, in: ctx, stroke: true) { $0.addRect(a.normalizedRect) }

        case .ellipse:
            paintPath(a, in: ctx, stroke: true) { $0.addEllipse(in: a.normalizedRect) }

        case .pen:
            strokePath(a, in: ctx)

        case .roundedRectangle, .triangle, .star:
            if let path = a.shapePath { paintPath(a, in: ctx, stroke: true) { $0.addPath(path) } }

        case .highlighter:
            drawBrush(a, in: ctx)

        case .text:
            (a.text as NSString).draw(at: a.start, withAttributes: a.textAttributes)

        case .step:
            paintPath(a, in: ctx, stroke: false) { $0.addEllipse(in: a.bounds) }
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

    /// Strokes or fills the path added by `build`. Solid colours use the context colours directly.
    /// Gradients clip to the path (expanding the stroke outline first) and fill the clip with a CGGradient.
    private func paintPath(_ a: Annotation, in ctx: CGContext, stroke: Bool, _ build: (CGContext) -> Void) {
        let g = a.gradient ?? .solid(a.color)
        if g.isSolid {
            ctx.setStrokeColor(g.from.cgColor)
            ctx.setFillColor(g.from.cgColor)
            build(ctx)
            if stroke { ctx.strokePath() } else { ctx.fillPath() }
            return
        }
        ctx.saveGState()
        build(ctx)
        if stroke { ctx.replacePathWithStrokedPath() }
        ctx.clip()
        drawGradient(g, in: a.bounds, ctx)
        ctx.restoreGState()
    }

    private func drawGradient(_ g: Gradient, in rect: CGRect, _ ctx: CGContext) {
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [g.from.cgColor, g.to.cgColor] as CFArray, locations: nil) else { return }
        let t: CGFloat = CGFloat(g.angle) * .pi / 180
        let dx: CGFloat = cos(t), dy: CGFloat = sin(t)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let half: CGFloat = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
        let p0 = CGPoint(x: c.x - dx * half, y: c.y - dy * half)
        let p1 = CGPoint(x: c.x + dx * half, y: c.y + dy * half)
        ctx.drawLinearGradient(grad, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func strokePath(_ a: Annotation, in ctx: CGContext) {
        let pts = a.points
        guard let first = pts.first else { return }
        if pts.count == 1 {
            let r = a.lineWidth / 2
            paintPath(a, in: ctx, stroke: false) { $0.addEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)) }
            return
        }
        // Quadratic smoothing through segment midpoints removes mouse-sampling jaggies.
        paintPath(a, in: ctx, stroke: true) { c in
            c.move(to: first)
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                c.addQuadCurve(to: mid, control: pts[i - 1])
            }
            c.addLine(to: pts[pts.count - 1])
        }
    }

    /// Brush: smoothed centreline, width tapering slightly towards both ends, round caps.
    /// Filled as one outline plus two cap discs, so gradients and solid colours share `paintPath`.
    private func drawBrush(_ a: Annotation, in ctx: CGContext) {
        let pts = a.points
        guard let first = pts.first else { return }
        let w = a.lineWidth
        if pts.count == 1 {
            paintPath(a, in: ctx, stroke: false) { $0.addEllipse(in: CGRect(x: first.x - w / 2, y: first.y - w / 2, width: w, height: w)) }
            return
        }
        var s: [CGPoint] = [first]
        for i in 1..<pts.count { s.append(CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)) }
        s.append(pts[pts.count - 1])
        let n = s.count
        func width(_ i: Int) -> CGFloat {
            let t = CGFloat(i) / CGFloat(n - 1)
            return w * (1 - 0.3 * pow(abs(2 * t - 1), 3))
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<n {
            let p0 = s[max(i - 1, 0)], p1 = s[min(i + 1, n - 1)]
            var tx = p1.x - p0.x, ty = p1.y - p0.y
            let len = hypot(tx, ty)
            if len > 0 { tx /= len; ty /= len } else { tx = 1; ty = 0 }
            let h = width(i) / 2
            let nx = -ty * h, ny = tx * h
            left.append(CGPoint(x: s[i].x + nx, y: s[i].y + ny))
            right.append(CGPoint(x: s[i].x - nx, y: s[i].y - ny))
        }
        paintPath(a, in: ctx, stroke: false) { c in
            c.move(to: left[0])
            for p in left.dropFirst() { c.addLine(to: p) }
            for p in right.reversed() { c.addLine(to: p) }
            c.closePath()
        }
        for (p, r) in [(s[0], width(0) / 2), (s[n - 1], width(n - 1) / 2)] {
            paintPath(a, in: ctx, stroke: false) { $0.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)) }
        }
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
