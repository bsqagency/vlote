import AppKit

struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let red = RGBAColor(r: 1.0, g: 0.23, b: 0.19)
    static let orange = RGBAColor(r: 1.0, g: 0.58, b: 0.0)
    static let yellow = RGBAColor(r: 1.0, g: 0.84, b: 0.04)
    static let green = RGBAColor(r: 0.20, g: 0.78, b: 0.35)
    static let blue = RGBAColor(r: 0.04, g: 0.52, b: 1.0)
    static let purple = RGBAColor(r: 0.69, g: 0.32, b: 0.87)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Two-stop linear gradient. `from == to` is a solid colour. Angle in degrees: 0 runs left to right, 90 top to bottom.
struct Gradient: Codable, Equatable, Hashable {
    var from: RGBAColor
    var to: RGBAColor
    var angle: Double = 45

    static func solid(_ c: RGBAColor) -> Gradient { Gradient(from: c, to: c, angle: 0) }
    var isSolid: Bool { from == to }

    static let palette: [(name: String, gradient: Gradient)] = [
        ("Blue", Gradient(from: RGBAColor(r: 0.204, g: 0.447, b: 0.933), to: RGBAColor(r: 0.471, g: 0.788, b: 0.980))),
        ("Purple to pink", Gradient(from: RGBAColor(r: 0.49, g: 0.23, b: 0.93), to: RGBAColor(r: 0.96, g: 0.36, b: 0.73))),
        ("Orange to pink", Gradient(from: RGBAColor(r: 1.0, g: 0.55, b: 0.20), to: RGBAColor(r: 0.98, g: 0.31, b: 0.60))),
        ("Green to teal", Gradient(from: RGBAColor(r: 0.13, g: 0.77, b: 0.45), to: RGBAColor(r: 0.07, g: 0.67, b: 0.67))),
        ("Sunset", Gradient(from: RGBAColor(r: 1.0, g: 0.60, b: 0.15), to: RGBAColor(r: 0.93, g: 0.22, b: 0.19))),
        ("Dark neutral", Gradient(from: RGBAColor(r: 0.25, g: 0.25, b: 0.27), to: RGBAColor(r: 0.04, g: 0.04, b: 0.05))),
        ("Black", .solid(.black)),
        ("White", .solid(.white)),
    ]
}

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, roundedRectangle, ellipse, triangle, star, pen, highlighter, text, step, blur, pixelate, spotlight, crop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Straight"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded rectangle"
        case .ellipse: return "Ellipse"
        case .triangle: return "Triangle"
        case .star: return "Star"
        case .pen: return "Pen"
        case .highlighter: return "Brush"
        case .text: return "Text"
        case .step: return "Numbered step"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "app"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .star: return "star"
        case .pen: return "pencil.tip"
        case .highlighter: return "paintbrush.pointed"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "square.grid.3x3"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .roundedRectangle: return "u"
        case .triangle: return "g"
        case .star: return "y"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .step: return "n"
        case .blur: return "b"
        case .pixelate: return "x"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }

    var kind: Annotation.Kind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .line: return .line
        case .rectangle: return .rectangle
        case .roundedRectangle: return .roundedRectangle
        case .ellipse: return .ellipse
        case .triangle: return .triangle
        case .star: return .star
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .text: return .text
        case .step: return .step
        case .blur: return .blur
        case .pixelate: return .pixelate
        case .spotlight: return .spotlight
        }
    }

    /// Tools whose active width is set by the Stroke slider and by scroll-wheel thickness.
    var usesStroke: Bool {
        switch self {
        case .arrow, .line, .rectangle, .roundedRectangle, .ellipse, .triangle, .star, .pen, .highlighter: return true
        default: return false
        }
    }
}

/// A single editable mark. All coordinates are in **image pixels, top-left origin**, so a document is
/// independent of view zoom and display scale and round-trips through JSON for later re-editing.
struct Annotation: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate, spotlight
        case roundedRectangle, triangle, star
    }

    /// Brush width as a multiple of the Stroke setting.
    static let brushWidthFactor: CGFloat = 3

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBAColor
    /// Stroke width in image pixels.
    var lineWidth: CGFloat
    /// Text size in image pixels (also drives the numbered-step diameter).
    var fontSize: CGFloat = 0
    var text: String = ""
    var number: Int = 0
    /// nil = solid `color`. Optional, so annotations saved before gradients still decode.
    /// When set, `color` always equals `gradient.from`.
    var gradient: Gradient? = nil

    var isTwoPoint: Bool {
        switch kind {
        case .arrow, .line, .rectangle, .roundedRectangle, .ellipse, .triangle, .star, .blur, .pixelate, .spotlight: return true
        default: return false
        }
    }

    var normalizedRect: CGRect { CGRect(from: start, to: end) }

    /// Outline of the shapes defined by their bounding box (nil for other kinds).
    var shapePath: CGPath? {
        let r = normalizedRect
        switch kind {
        case .roundedRectangle:
            let c = min(r.width, r.height) * 0.22
            return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
        case .triangle:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        case .star:
            let p = CGMutablePath()
            let c = CGPoint(x: r.midX, y: r.midY), rx = r.width / 2, ry = r.height / 2
            for i in 0..<10 {
                let k: CGFloat = i % 2 == 0 ? 1 : 0.45
                let angle = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
                let pt = CGPoint(x: c.x + cos(angle) * rx * k, y: c.y + sin(angle) * ry * k)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        default:
            return nil
        }
    }
    var stepDiameter: CGFloat { fontSize * 1.6 }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color.nsColor]
    }

    var textSize: CGSize { (text as NSString).size(withAttributes: textAttributes) }

    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: textSize)
        case .step:
            let d = stepDiameter
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        case .pen, .highlighter:
            guard let first = points.first else { return CGRect(origin: start, size: .zero) }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        default:
            return normalizedRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        let reach = lineWidth / 2 + t
        switch kind {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= reach
        case .rectangle:
            let r = normalizedRect
            return r.insetBy(dx: -reach, dy: -reach).contains(p) && !r.insetBy(dx: reach, dy: reach).contains(p)
        case .ellipse:
            let r = normalizedRect
            guard r.width > 0, r.height > 0 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let k = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            return abs(k - 1) * min(rx, ry) <= reach
        case .roundedRectangle, .triangle, .star:
            guard let path = shapePath else { return false }
            return path.copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p)
        case .blur, .pixelate, .spotlight:
            return normalizedRect.insetBy(dx: -t, dy: -t).contains(p)
        case .pen, .highlighter:
            guard points.count > 1 else { return points.first.map { $0.distance(to: p) <= reach } ?? false }
            for i in 1..<points.count where distance(from: p, toSegment: points[i - 1], points[i]) <= reach { return true }
            return false
        case .text, .step:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        for i in points.indices { points[i].x += dx; points[i].y += dy }
    }
}

/// Everything needed to re-open an edit later: the original pixels are stored separately and never modified.
struct DocumentState: Codable, Equatable {
    var annotations: [Annotation] = []
    var cropRect: CGRect?
}
