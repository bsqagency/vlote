import AppKit
import Combine
import SwiftUI

/// The interactive surface. Owns hit-testing, drafts and the inline text field; all document state
/// lives in `EditorModel`. View space is flipped (top-left) to match annotation coordinates.
final class CanvasView: NSView, NSTextFieldDelegate {
    private let model: EditorModel
    private var bag = Set<AnyCancellable>()

    private var draft: Annotation?
    private var dragStartImage: CGPoint = .zero
    private var movingSelection = false
    private var movedSinceDown = false
    private var activeHandle: Handle?
    private var textField: NSTextField?
    private var textOriginal: Annotation?

    private enum Handle { case start, end }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        model.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Geometry

    private var imageSize: CGSize { CGSize(width: model.capture.image.width, height: model.capture.image.height) }

    private var fit: (scale: CGFloat, origin: CGPoint) {
        let backing = window?.backingScaleFactor ?? 2
        let pad: CGFloat = 16
        let avail = CGSize(width: max(1, bounds.width - pad * 2), height: max(1, bounds.height - pad * 2))
        let s = min(avail.width / imageSize.width, avail.height / imageSize.height, 1 / backing)
        let w = imageSize.width * s, h = imageSize.height * s
        return (s, CGPoint(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2))
    }

    private func toImage(_ v: CGPoint) -> CGPoint {
        let f = fit
        return CGPoint(x: (v.x - f.origin.x) / f.scale, y: (v.y - f.origin.y) / f.scale)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let f = fit
        return CGPoint(x: p.x * f.scale + f.origin.x, y: p.y * f.scale + f.origin.y)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), imageSize.width), y: min(max(0, p.y), imageSize.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = fit
        ctx.saveGState()
        ctx.translateBy(x: f.origin.x, y: f.origin.y)
        ctx.scaleBy(x: f.scale, y: f.scale)
        ctx.interpolationQuality = .high
        var shown = model.annotations
        if let draft, draft.kind != .text, model.tool != .crop { shown.append(draft) }
        model.renderer.draw(shown, in: ctx, hiding: model.editingTextID)
        ctx.restoreGState()

        drawCropOverlay(ctx)
        drawSelection(ctx)
    }

    private func drawCropOverlay(_ ctx: CGContext) {
        guard let crop = model.cropRect else { return }
        let a = toView(crop.origin), b = toView(CGPoint(x: crop.maxX, y: crop.maxY))
        let r = CGRect(from: a, to: b)
        let image = CGRect(origin: toView(.zero), size: CGSize(width: imageSize.width * fit.scale, height: imageSize.height * fit.scale))
        ctx.saveGState()
        ctx.addRect(image); ctx.addRect(r)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let a = model.selected, model.editingTextID == nil else { return }
        let b = a.bounds
        let r = CGRect(from: toView(b.origin), to: toView(CGPoint(x: b.maxX, y: b.maxY))).insetBy(dx: -3, dy: -3)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        if a.isTwoPoint {
            for p in [toView(a.start), toView(a.end)] {
                let h = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillEllipse(in: h)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: h)
            }
        }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .select ? .arrow : .crosshair)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let p = toImage(convert(event.locationInWindow, from: nil))
        dragStartImage = p
        movedSinceDown = false
        movingSelection = false
        activeHandle = nil

        switch model.tool {
        case .select:
            let tolerance = 6 / fit.scale
            if let a = model.selected, a.isTwoPoint {
                let v = convert(event.locationInWindow, from: nil)
                if toView(a.start).distance(to: v) <= 9 { activeHandle = .start; model.beginChange(); return }
                if toView(a.end).distance(to: v) <= 9 { activeHandle = .end; model.beginChange(); return }
            }
            if let hit = model.annotations.last(where: { $0.hitTest(p, tolerance: tolerance) }) {
                model.selection = hit.id
                movingSelection = true
                if event.clickCount == 2, hit.kind == .text { beginTextEditing(existing: hit) }
            } else {
                model.selection = nil
            }

        case .crop:
            draft = model.makeAnnotation(.rectangle, at: clampToImage(p))

        case .text:
            let tolerance = 4 / fit.scale
            if let hit = model.annotations.last(where: { $0.kind == .text && $0.hitTest(p, tolerance: tolerance) }) {
                beginTextEditing(existing: hit)
            } else {
                beginTextEditing(existing: nil, at: p)
            }

        case .step:
            var a = model.makeAnnotation(.step, at: p)
            a.number = model.nextStepNumber
            model.commit(a)

        default:
            if let kind = model.tool.kind { draft = model.makeAnnotation(kind, at: p) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        if let handle = activeHandle, var a = model.selected {
            let moved = constrain(raw, from: handle == .start ? a.end : a.start, kind: a.kind, shift: shift)
            if handle == .start { a.start = moved } else { a.end = moved }
            model.replace(a)
            return
        }

        if movingSelection, var a = model.selected {
            if !movedSinceDown { model.beginChange(); movedSinceDown = true }
            a.translate(dx: raw.x - dragStartImage.x, dy: raw.y - dragStartImage.y)
            dragStartImage = raw
            model.replace(a)
            return
        }

        guard var d = draft else { return }
        switch d.kind {
        case .pen, .highlighter:
            if model.tool == .crop { break }
            d.points.append(raw)
        default:
            let target = model.tool == .crop ? clampToImage(raw) : raw
            d.end = constrain(target, from: d.start, kind: d.kind, shift: shift)
        }
        draft = d
        if model.tool == .crop { model.cropRect = d.normalizedRect }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { draft = nil; movingSelection = false; activeHandle = nil; needsDisplay = true }
        guard let d = draft else { return }
        if model.tool == .crop {
            if d.normalizedRect.width < 4 || d.normalizedRect.height < 4 { model.cropRect = nil; return }
            // The live rect was already written during the drag; record one undo step for the final result.
            let final = d.normalizedRect
            model.cropRect = nil
            model.beginChange()
            model.cropRect = final
            return
        }
        switch d.kind {
        case .pen, .highlighter: model.commit(d)
        default:
            if hypot(d.end.x - d.start.x, d.end.y - d.start.y) >= 3 / fit.scale { model.commit(d) }
        }
    }

    /// Shift: snap lines/arrows to 45° steps and force rectangles/ellipses/redactions square.
    private func constrain(_ p: CGPoint, from o: CGPoint, kind: Annotation.Kind, shift: Bool) -> CGPoint {
        guard shift else { return p }
        let dx = p.x - o.x, dy = p.y - o.y
        switch kind {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: o.x + cos(angle) * len, y: o.y + sin(angle) * len)
        case .rectangle, .ellipse, .blur, .pixelate, .spotlight:
            let m = max(abs(dx), abs(dy))
            return CGPoint(x: o.x + (dx < 0 ? -m : m), y: o.y + (dy < 0 ? -m : m))
        default: return p
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { super.keyDown(with: event); return }

        switch event.keyCode {
        case 51, 117: model.deleteSelection(); return             // delete / forward delete
        case 53:                                                   // escape
            if model.selection != nil { model.selection = nil } else { model.tool = .select }
            return
        case 123, 124, 125, 126:                                   // arrows nudge the selection
            guard var a = model.selected else { break }
            let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) * model.capture.scale
            model.beginChange()
            switch event.keyCode {
            case 123: a.translate(dx: -step, dy: 0)
            case 124: a.translate(dx: step, dy: 0)
            case 125: a.translate(dx: 0, dy: step)
            default: a.translate(dx: 0, dy: -step)
            }
            model.replace(a)
            return
        default: break
        }

        if let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.shortcut == ch }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func undo(_ sender: Any?) { commitTextEditing(); model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func copy(_ sender: Any?) { Output.copyToPasteboard(model.exportImage(), scale: model.capture.scale) }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { model.tool = .select }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        default: return true
        }
    }

    // MARK: Inline text editing

    private func beginTextEditing(existing: Annotation?, at point: CGPoint? = nil) {
        commitTextEditing()
        var a = existing ?? model.makeAnnotation(.text, at: point ?? .zero)
        if existing != nil { model.selection = a.id }
        a.kind = .text
        textOriginal = existing
        draft = a
        model.editingTextID = a.id

        let f = fit
        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: a.fontSize * f.scale, weight: .semibold)
        field.textColor = a.color.nsColor
        field.delegate = self
        field.placeholderString = "Text"
        let origin = toView(a.start)
        field.frame = CGRect(x: origin.x, y: origin.y, width: 200, height: ceil(a.fontSize * f.scale * 1.3))
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        field.sizeToFit()
        field.frame.size.width = max(80, field.frame.width + 12)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitTextEditing(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelTextEditing(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    private func commitTextEditing() {
        guard let field = textField, var a = draft, a.kind == .text else { return }
        textField = nil
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        draft = nil
        model.editingTextID = nil
        window?.makeFirstResponder(self)
        if let original = textOriginal {
            textOriginal = nil
            if value.isEmpty { model.selection = original.id; model.deleteSelection() }
            else if value != original.text { model.beginChange(); a = original; a.text = value; model.replace(a) }
        } else if !value.isEmpty {
            a.text = value
            model.commit(a)
        }
        needsDisplay = true
    }

    private func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil; draft = nil; textOriginal = nil
        model.editingTextID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ nsView: CanvasView, context: Context) { nsView.needsDisplay = true }
}
