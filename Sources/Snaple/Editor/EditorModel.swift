import AppKit
import Combine

@MainActor
final class EditorModel: ObservableObject {
    let capture: CapturedImage
    let renderer: AnnotationRenderer

    @Published var annotations: [Annotation] = []
    @Published var cropRect: CGRect?
    @Published var tool: Tool = .pen
    /// Active style. `color` is its first stop (used by text and as the solid fallback).
    @Published var gradient: Gradient = Gradient.palette[0].gradient
    /// Last option chosen in each toolbar category, shown on the category button.
    @Published var groupPick: [ToolGroup: Tool] = [:]
    var color: RGBAColor { gradient.from }
    /// Stroke width and text size are edited in points and stored in image pixels.
    @Published var lineWidthPt: Double = 3
    @Published var fontSizePt: Double = 18
    @Published var selection: UUID?
    @Published var editingTextID: UUID?

    private struct Snapshot { var annotations: [Annotation]; var cropRect: CGRect? }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(capture: CapturedImage, state: DocumentState? = nil) {
        self.capture = capture
        self.renderer = AnnotationRenderer(base: capture.image, scale: capture.scale)
        if let state { annotations = state.annotations; cropRect = state.cropRect }
    }

    var state: DocumentState { DocumentState(annotations: annotations, cropRect: cropRect) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selected: Annotation? { annotations.first { $0.id == selection } }
    var lineWidthPx: CGFloat { CGFloat(lineWidthPt) * capture.scale }
    var fontSizePx: CGFloat { CGFloat(fontSizePt) * capture.scale }
    var nextStepNumber: Int { (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1 }

    // MARK: Undo / redo (whole-state snapshots: annotation arrays are small value types)

    func beginChange() {
        undoStack.append(Snapshot(annotations: annotations, cropRect: cropRect))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, cropRect: cropRect))
        annotations = s.annotations; cropRect = s.cropRect
        if selected == nil { selection = nil }
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, cropRect: cropRect))
        annotations = s.annotations; cropRect = s.cropRect
    }

    // MARK: Mutations

    func choose(_ t: Tool) {
        tool = t
        if let g = ToolGroup.allCases.first(where: { $0.tools.contains(t) }) { groupPick[g] = t }
    }

    func makeAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> Annotation {
        var width = lineWidthPx
        if kind == .highlighter { width *= Annotation.brushWidthFactor }
        var g = gradient
        if kind == .highlighter, g == .solid(.black) { g = .solid(.yellow) }
        return Annotation(kind: kind, start: p, end: p, points: (kind == .pen || kind == .highlighter) ? [p] : [],
                          color: g.from, lineWidth: width, fontSize: fontSizePx, gradient: g)
    }

    func commit(_ a: Annotation) {
        beginChange()
        annotations.append(a)
        selection = nil
    }

    func replace(_ a: Annotation) {
        if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
    }

    func deleteSelection() {
        guard let id = selection else { return }
        beginChange()
        annotations.removeAll { $0.id == id }
        selection = nil
    }

    func setColor(_ c: RGBAColor) { setGradient(.solid(c)) }

    func setGradient(_ g: Gradient) {
        gradient = g
        guard var a = selected else { return }
        beginChange(); a.color = g.from; a.gradient = g; replace(a)
    }

    func setLineWidth(_ pt: Double) {
        lineWidthPt = pt
        guard var a = selected, a.kind != .text, a.kind != .step else { return }
        beginChange(); a.lineWidth = CGFloat(pt) * capture.scale * (a.kind == .highlighter ? Annotation.brushWidthFactor : 1); replace(a)
    }

    func setFontSize(_ pt: Double) {
        fontSizePt = pt
        guard var a = selected, a.kind == .text || a.kind == .step else { return }
        beginChange(); a.fontSize = CGFloat(pt) * capture.scale; replace(a)
    }

    func resetCrop() { guard cropRect != nil else { return }; beginChange(); cropRect = nil }

    // MARK: Output

    func exportImage() -> CGImage? { renderer.export(annotations, crop: cropRect) }
}
