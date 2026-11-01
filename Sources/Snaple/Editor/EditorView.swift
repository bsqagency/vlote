import SwiftUI

// Toolbar category mapping. Every existing Tool is reachable from exactly one group:
//   Line:   pen (Pen), line (Straight), highlighter (Brush)
//   Shapes: rectangle, roundedRectangle, ellipse, triangle, star, arrow
//   Text:   text (Text), step (Numbered step)
//   Color:  gradient palette, solid black and white, custom colour, gradient angle
//   More:   select, blur, pixelate, spotlight, crop (Reset Crop stays on the toolbar)
enum ToolGroup: String, CaseIterable, Identifiable {
    case line, shapes, text, color, more
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "Line"
        case .shapes: return "Shapes"
        case .text: return "Text"
        case .color: return "Colour"
        case .more: return "More"
        }
    }

    var tools: [Tool] {
        switch self {
        case .line: return [.pen, .line, .highlighter]
        case .shapes: return [.rectangle, .roundedRectangle, .ellipse, .triangle, .star, .arrow]
        case .text: return [.text, .step]
        case .color: return []
        case .more: return [.select, .blur, .pixelate, .spotlight, .crop]
        }
    }

    var defaultTool: Tool { tools.first ?? .select }
}

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
        .frame(minWidth: 900, minHeight: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ToolGroupButton(model: model, group: .line)
                    ToolGroupButton(model: model, group: .shapes)
                    ToolGroupButton(model: model, group: .text)
                    ColorGroupButton(model: model)
                    ToolGroupButton(model: model, group: .more)

                    if usesStroke {
                        Slider(value: Binding(get: { model.lineWidthPt }, set: { model.setLineWidth($0) }), in: 1...40)
                            .frame(width: 90).help("Stroke width")
                    }
                    if usesText {
                        Slider(value: Binding(get: { model.fontSizePt }, set: { model.setFontSize($0) }), in: 10...72)
                            .frame(width: 90).help("Text size")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 36)

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
        .frame(height: 44)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.controlActiveState, .active)
    }

    private var usesStroke: Bool {
        switch model.tool {
        case .select: return model.selected.map { $0.kind != .text && $0.kind != .step } ?? false
        default: return model.tool.usesStroke
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

/// A category button. Shows the active option of its group (or the last one picked) and opens a popover listing the group's tools.
private struct ToolGroupButton: View {
    @ObservedObject var model: EditorModel
    let group: ToolGroup
    @State private var open = false

    private var shown: Tool {
        group.tools.contains(model.tool) ? model.tool : (model.groupPick[group] ?? group.defaultTool)
    }

    private var active: Bool { group.tools.contains(model.tool) }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: shown.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    if active {
                        Text(model.tool.title)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .frame(minWidth: 64, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 6)
            .background(active ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("\(group.title): \(shown.title)")
        .accessibilityLabel(group.title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.tools) { tool in
                    Button {
                        model.choose(tool)
                        open = false
                    } label: {
                        Label(tool.title, systemImage: tool.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                }
            }
            .padding(8)
            .frame(width: 180)
        }
    }
}

/// The Color category: shows the active gradient and opens the gradient palette, custom colour and angle.
private struct ColorGroupButton: View {
    @ObservedObject var model: EditorModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(gradientFill(model.gradient))
                    .frame(width: 28, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.3), lineWidth: 1))
                Text("Colour")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(minWidth: 64, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .help("Colour")
        .accessibilityLabel("Colour")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Array(Gradient.palette.enumerated()), id: \.offset) { _, item in
                        let selected = model.gradient.from == item.gradient.from && model.gradient.to == item.gradient.to
                        Button { model.setGradient(item.gradient) } label: {
                            Circle().fill(gradientFill(item.gradient))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(.primary.opacity(selected ? 0.9 : 0.25), lineWidth: selected ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                    }
                }
                ColorPicker("Custom", selection: Binding(
                    get: { Color(nsColor: model.color.nsColor) },
                    set: { model.setColor(RGBAColor(NSColor($0))) }
                ), supportsOpacity: false)
                if !model.gradient.isSolid {
                    HStack {
                        Text("Angle")
                        Slider(value: Binding(get: { model.gradient.angle }, set: { a in
                            var g = model.gradient; g.angle = a; model.setGradient(g)
                        }), in: 0...360)
                    }
                }
            }
            .padding(10)
            .frame(width: 220)
        }
    }
}

private func gradientFill(_ g: Gradient) -> LinearGradient {
    let t = g.angle * .pi / 180
    return LinearGradient(colors: [Color(nsColor: g.from.nsColor), Color(nsColor: g.to.nsColor)],
                          startPoint: UnitPoint(x: 0.5 - 0.5 * cos(t), y: 0.5 - 0.5 * sin(t)),
                          endPoint: UnitPoint(x: 0.5 + 0.5 * cos(t), y: 0.5 + 0.5 * sin(t)))
}
