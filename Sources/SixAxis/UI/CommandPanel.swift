import SwiftUI
import SixAxisCore

/// Floating dialog for the active modeling command (Fusion's command dialog).
struct CommandPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        if let cmd = editor.command {
            VStack(alignment: .leading, spacing: 0) {
                header(cmd)
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 12) {
                    content(cmd)
                    if let err = editor.commandError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                if cmd.kind != .sketchPlane {
                    Divider().opacity(0.5)
                    footer
                }
            }
            .frame(width: 290)
            .floatingPanel()
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func header(_ cmd: ActiveCommand) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(cmd.kind)).foregroundStyle(Color.accentColor)
            Text(cmd.isNew ? cmd.kind.title : String(localized: "\(cmd.kind.title) bearbeiten"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            IconButton(symbol: "xmark", help: String(localized: "Abbrechen (Esc)"), size: 22) { editor.cancelCommand() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Abbrechen") { editor.cancelCommand() }
                .keyboardShortcut(.cancelAction)
            Button("OK") { editor.commitCommand() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func symbol(_ k: CommandKind) -> String {
        switch k {
        case .extrude: return "square.stack.3d.up.fill"
        case .revolve: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .fillet: return "button.roundedtop.horizontal"
        case .chamfer: return "triangle.bottomhalf.filled"
        case .shell: return "shippingbox"
        case .sketchPlane: return "pencil.and.outline"
        }
    }

    @ViewBuilder
    private func content(_ cmd: ActiveCommand) -> some View {
        switch (cmd.kind, editor.commandFeature?.kind) {
        case (.sketchPlane, _):
            sketchPlaneContent
        case let (.extrude, .extrude(e)?):
            extrudeContent(e)
        case let (.revolve, .revolve(r)?):
            revolveContent(r, cmd)
        case let (.fillet, .fillet(f)?):
            selectionRow(String(localized: "Kanten"), count: f.edges.count, symbol: "line.diagonal", active: true) {
                editor.updateCommandFeature { k in if case var .fillet(x) = k { x.edges = []; k = .fillet(x) } }
            }
            ExpressionField(label: String(localized: "Radius"), text: f.radius, kind: .length, editor: editor) { v in
                editor.updateCommandFeature { k in if case var .fillet(x) = k { x.radius = v; k = .fillet(x) } }
            }
        case let (.chamfer, .chamfer(c)?):
            selectionRow(String(localized: "Kanten"), count: c.edges.count, symbol: "line.diagonal", active: true) {
                editor.updateCommandFeature { k in if case var .chamfer(x) = k { x.edges = []; k = .chamfer(x) } }
            }
            ExpressionField(label: String(localized: "Abstand"), text: c.distance, kind: .length, editor: editor) { v in
                editor.updateCommandFeature { k in if case var .chamfer(x) = k { x.distance = v; k = .chamfer(x) } }
            }
        case let (.shell, .shell(s)?):
            selectionRow(String(localized: "Offene Flächen"), count: s.faces.count, symbol: "square.dashed", active: true) {
                editor.updateCommandFeature { k in if case var .shell(x) = k { x.faces = []; k = .shell(x) } }
            }
            if s.faces.isEmpty {
                Text(s.body == nil ? String(localized: "Klicke Flächen an, die offen sein sollen.") : String(localized: "Ohne offene Fläche wird der Körper innen hohl."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ExpressionField(label: String(localized: "Wandstärke"), text: s.thickness, kind: .length, editor: editor) { v in
                editor.updateCommandFeature { k in if case var .shell(x) = k { x.thickness = v; k = .shell(x) } }
            }
        default:
            EmptyView()
        }
    }

    private var sketchPlaneContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wähle eine Ursprungsebene oder eine ebene Fläche im Ansichtsfenster.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach([PlaneRef.xy, .xz, .yz], id: \.self) { p in
                    Button(p.displayName) { editor.beginSketch(on: p, tool: editor.command?.pendingTool) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func extrudeContent(_ e: ExtrudeFeature) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionRow(String(localized: "Profile"), count: e.profiles.count + e.faces.count, symbol: "square.on.square.dashed", active: true) {
                editor.updateCommandFeature { k in if case var .extrude(x) = k { x.profiles = []; x.faces = []; k = .extrude(x) } }
            }
            LabeledRow(String(localized: "Richtung")) {
                Picker("", selection: Binding(get: { e.extent }, set: { v in
                    editor.updateCommandFeature { k in if case var .extrude(x) = k { x.extent = v; k = .extrude(x) } }
                })) {
                    ForEach(ExtrudeExtent.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            ExpressionField(label: e.extent == .twoSides ? String(localized: "Abstand 1") : String(localized: "Abstand"), text: e.distance, kind: .length, editor: editor) { v in
                editor.updateCommandFeature { k in if case var .extrude(x) = k { x.distance = v; k = .extrude(x) } }
            }
            if e.extent == .twoSides {
                ExpressionField(label: String(localized: "Abstand 2"), text: e.distance2, kind: .length, editor: editor) { v in
                    editor.updateCommandFeature { k in if case var .extrude(x) = k { x.distance2 = v; k = .extrude(x) } }
                }
            }
            operationPicker(e.operation) { op in
                editor.updateCommandFeature { k in if case var .extrude(x) = k { x.operation = op; k = .extrude(x) } }
            }
        }
    }

    private func revolveContent(_ r: RevolveFeature, _ cmd: ActiveCommand) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionRow(String(localized: "Profile"), count: r.profiles.count, symbol: "square.on.square.dashed", active: cmd.activeInput == 0) {
                editor.updateCommandFeature { k in if case var .revolve(x) = k { x.profiles = []; k = .revolve(x) } }
            } activate: { editor.command?.activeInput = 0; editor.sceneVersion &+= 1 }
            selectionRow(String(localized: "Achse"), count: r.axis == nil ? 0 : 1, symbol: "line.diagonal", active: cmd.activeInput == 1,
                         detail: r.axis?.displayName) {
                editor.updateCommandFeature { k in if case var .revolve(x) = k { x.axis = nil; k = .revolve(x) } }
            } activate: { editor.command?.activeInput = 1; editor.sceneVersion &+= 1 }
            HStack(spacing: 6) {
                ForEach([AxisRef.x, .y, .z], id: \.self) { a in
                    Button(a.displayName) {
                        editor.updateCommandFeature { k in if case var .revolve(x) = k { x.axis = a; k = .revolve(x) } }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            ExpressionField(label: String(localized: "Winkel"), text: r.angle, kind: .angle, editor: editor) { v in
                editor.updateCommandFeature { k in if case var .revolve(x) = k { x.angle = v; k = .revolve(x) } }
            }
            operationPicker(r.operation) { op in
                editor.updateCommandFeature { k in if case var .revolve(x) = k { x.operation = op; k = .revolve(x) } }
            }
        }
    }

    private func operationPicker(_ current: BodyOperation, set: @escaping (BodyOperation) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vorgang").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(BodyOperation.allCases, id: \.self) { op in
                    Button { set(op) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: op.symbol).font(.system(size: 14))
                            Text(op.displayName).font(.system(size: 9.5, weight: .medium)).lineLimit(1).fixedSize()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(current == op ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(current == op ? Color.accentColor : .clear, lineWidth: 1.2))
                        .foregroundStyle(current == op ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func selectionRow(_ title: String, count: Int, symbol: String, active: Bool, detail: String? = nil,
                              clear: @escaping () -> Void, activate: (() -> Void)? = nil) -> some View {
        LabeledRow(title) {
            Button {
                activate?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11))
                    Text(count == 0 ? String(localized: "Auswählen") : (detail ?? String(localized: "\(count) ausgewählt")))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    if count > 0 {
                        Button(action: clear) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Auswahl leeren")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(count > 0 ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct LabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            content
        }
    }
}

/// Text field for values that accept expressions and parameters ("2 * wand + 1 mm").
struct ExpressionField: View {
    let label: String
    let text: String
    let kind: ValueKind
    let editor: Editor
    let onChange: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledRow(label) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { onChange(draft); editor.commitCommand() }
                    .onChange(of: draft) { _, new in
                        if (try? editor.evaluator.value(new, kind: kind)) != nil, new != text { onChange(new) }
                    }
                if let v = try? editor.evaluator.value(draft, kind: kind) {
                    if Double(draft.replacingOccurrences(of: ",", with: ".")) == nil {
                        Text("= " + formatValue(v, kind: kind)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else if !draft.isEmpty {
                    Text("Ungültiger Ausdruck").font(.system(size: 10)).foregroundStyle(.red)
                }
            }
        }
        .onAppear { draft = text }
        .onChange(of: text) { _, new in if !focused || (try? editor.evaluator.value(draft, kind: kind)) == nil { draft = new } }
        .onChange(of: focused) { _, f in if !f { draft = text } }
    }
}
