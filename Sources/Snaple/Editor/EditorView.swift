import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    var onSaveAs: () -> Void
    var onUpload: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CanvasRepresentable(model: model)
        }
        .frame(minWidth: 1040, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 28, height: 24)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                    .accessibilityLabel(tool.title)
                }
            }

            Divider().frame(height: 20)

            HStack(spacing: 5) {
                ForEach(RGBAColor.palette, id: \.self) { c in
                    Button { model.setColor(c) } label: {
                        Circle().fill(Color(nsColor: c.nsColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.primary.opacity(model.color == c ? 0.9 : 0.25), lineWidth: model.color == c ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour")
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: model.color.nsColor) },
                    set: { model.setColor(RGBAColor(NSColor($0))) }
                ), supportsOpacity: false)
                .labelsHidden()
            }

            if usesStroke {
                Slider(value: Binding(get: { model.lineWidthPt }, set: { model.setLineWidth($0) }), in: 1...16)
                    .frame(width: 90).help("Stroke width")
            }
            if usesText {
                Slider(value: Binding(get: { model.fontSizePt }, set: { model.setFontSize($0) }), in: 10...72)
                    .frame(width: 90).help("Text size")
            }

            Spacer(minLength: 8)

            if model.cropRect != nil {
                Button("Reset Crop") { model.resetCrop() }
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)")

            Divider().frame(height: 20)

            Button { Output.copyToPasteboard(model.exportImage(), scale: model.capture.scale) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button { onUpload() } label: { Label("Upload", systemImage: "icloud.and.arrow.up") }
                .help("Upload this edited image and copy a link")
            Button("Save…", action: onSaveAs)
            Button("Done", action: onDone).buttonStyle(.borderedProminent)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var usesStroke: Bool {
        switch model.tool {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter: return true
        case .select: return model.selected.map { $0.kind != .text && $0.kind != .step } ?? false
        default: return false
        }
    }

    private var usesText: Bool {
        switch model.tool {
        case .text, .step: return true
        case .select: return model.selected.map { $0.kind == .text || $0.kind == .step } ?? false
        default: return false
        }
    }
}
