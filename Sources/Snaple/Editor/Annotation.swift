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

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate, spotlight, crop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
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
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
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
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .text: return .text
        case .step: return .step
        case .blur: return .blur
        case .pixelate: return .pixelate
        case .spotlight: return .spotlight
        }
    }
}

/// A single editable mark. All coordinates are in **image pixels, top-left origin**, so a document is
/// independent of view zoom and display scale and round-trips through JSON for later re-editing.
struct Annotation: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case arrow, line, rectangle, ellipse, pen, highlighter, text, step, blur, pixelate, spotlight
    }

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

    var isTwoPoint: Bool {
        switch kind {
        case .arrow, .line, .rectangle, .ellipse, .blur, .pixelate, .spotlight: return true
        default: return false
        }
    }

    var normalizedRect: CGRect { CGRect(from: start, to: end) }
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
