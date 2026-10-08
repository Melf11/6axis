import SwiftUI
import VibeCore

/// A command available from the search palette and the marking menu.
struct EditorCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var keywords: String = ""
    let available: Bool
    let run: () -> Void
}

extension Editor {
    var allCommands: [EditorCommand] {
        let inSketch = sketchId != nil
        let hasBodies = !state.bodyOrder.isEmpty
        var c: [EditorCommand] = [
            EditorCommand(id: "sketch", title: "Skizze erstellen", symbol: "pencil.and.outline", keywords: "sketch zeichnen", available: !inSketch) { self.beginCommand(.sketchPlane) },
            EditorCommand(id: "extrude", title: "Extrusion", symbol: "square.stack.3d.up.fill", shortcut: "E", keywords: "extrude ziehen press pull", available: true) { self.beginCommand(.extrude) },
            EditorCommand(id: "revolve", title: "Drehung", symbol: "arrow.trianglehead.2.clockwise.rotate.90", keywords: "revolve rotation", available: true) { self.beginCommand(.revolve) },
            EditorCommand(id: "fillet", title: "Abrundung", symbol: "button.roundedtop.horizontal", shortcut: "F", keywords: "fillet radius runden", available: hasBodies) { self.beginCommand(.fillet) },
            EditorCommand(id: "chamfer", title: "Fase", symbol: "triangle.bottomhalf.filled", keywords: "chamfer", available: hasBodies) { self.beginCommand(.chamfer) },
            EditorCommand(id: "shell", title: "Wandstärke", symbol: "shippingbox", keywords: "shell aushöhlen hohl", available: hasBodies) { self.beginCommand(.shell) },
            EditorCommand(id: "line", title: "Linie", symbol: "line.diagonal", shortcut: "L", keywords: "line", available: true) { self.setSketchTool(.line) },
            EditorCommand(id: "rect", title: "Rechteck", symbol: "rectangle", shortcut: "R", keywords: "rectangle", available: true) { self.setSketchTool(.rectangle) },
            EditorCommand(id: "crect", title: "Mittelpunkt-Rechteck", symbol: "rectangle.center.inset.filled", keywords: "center rectangle", available: true) { self.setSketchTool(.centerRectangle) },
            EditorCommand(id: "circle", title: "Kreis", symbol: "circle", shortcut: "C", keywords: "circle", available: true) { self.setSketchTool(.circle) },
            EditorCommand(id: "arc", title: "Bogen (3 Punkte)", symbol: "point.topleft.down.to.point.bottomright.curvepath", shortcut: "A", keywords: "arc", available: true) { self.setSketchTool(.arc) },
            EditorCommand(id: "dim", title: "Bemaßung", symbol: "ruler", shortcut: "D", keywords: "dimension maß", available: inSketch) { self.setSketchTool(.dimension) },
            EditorCommand(id: "finish", title: "Skizze fertigstellen", symbol: "checkmark.circle", keywords: "finish", available: inSketch) { self.finishSketch() },
            EditorCommand(id: "params", title: "Parameter ändern", symbol: "function", keywords: "parameters variablen", available: true) { self.showParameters = true },
            EditorCommand(id: "stl", title: "Als STL exportieren", symbol: "square.and.arrow.up", keywords: "export 3d druck print", available: hasBodies) { self.exportSTL() },
            EditorCommand(id: "step", title: "Als STEP exportieren", symbol: "square.and.arrow.up.on.square", keywords: "export cad", available: hasBodies) { self.exportSTEP() },
            EditorCommand(id: "slicer", title: "Im Slicer öffnen", symbol: "printer.fill", keywords: "print druck prusa bambu orca cura", available: hasBodies) { self.openInSlicer() },
            EditorCommand(id: "import", title: "STEP importieren", symbol: "square.and.arrow.down", keywords: "import", available: true) { self.importSTEP() },
            EditorCommand(id: "fit", title: "Alles einpassen", symbol: "arrow.up.left.and.arrow.down.right", keywords: "zoom fit", available: true) { self.fitAll() },
            EditorCommand(id: "home", title: "Ausgangsansicht", symbol: "house", keywords: "home view", available: true) { self.homeView() },
            EditorCommand(id: "ortho", title: "Orthografisch / Perspektive", symbol: "perspective", shortcut: "O", keywords: "projection", available: true) { self.toggleProjection() },
            EditorCommand(id: "undo", title: "Widerrufen", symbol: "arrow.uturn.backward", shortcut: "⌘Z", keywords: "undo", available: canUndo) { self.undo() },
            EditorCommand(id: "redo", title: "Wiederholen", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", keywords: "redo", available: canRedo) { self.redo() },
        ]
        for ct in ConstraintTool.allCases {
            c.append(EditorCommand(id: "c-\(ct.rawValue)", title: "Abhängigkeit: \(ct.name)", symbol: ct.symbol, keywords: "constraint", available: inSketch) {
                self.setSketchTool(.constraint(ct))
            })
        }
        return c
    }

    /// Eight context-dependent entries for the right-click marking menu.
    var markingMenuCommands: [EditorCommand] {
        let all = Dictionary(uniqueKeysWithValues: allCommands.map { ($0.id, $0) })
        let ids = sketchId != nil
            ? ["line", "rect", "circle", "dim", "finish", "arc", "undo", "c-coincident"]
            : ["sketch", "extrude", "fillet", "undo", "shell", "revolve", "chamfer", "fit"]
        return ids.compactMap { all[$0] }
    }
}

/// "S" key command search, like Fusion's shortcut box.
struct CommandPalette: View {
    @Bindable var editor: Editor
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [EditorCommand] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let available = editor.allCommands.filter(\.available)
        guard !q.isEmpty else { return Array(available.prefix(9)) }
        return available.filter { ($0.title + " " + $0.keywords).lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Befehl suchen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit(run)
                    .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                    .onExitCommand { editor.showCommandPalette = false }
                    .onChange(of: query) { index = 0 }
            }
            .padding(12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, cmd in
                        HStack(spacing: 10) {
                            Image(systemName: cmd.symbol).frame(width: 20).foregroundStyle(i == index ? .white : Color.accentColor)
                            Text(cmd.title).font(.system(size: 13))
                            Spacer()
                            if let s = cmd.shortcut {
                                Text(s).font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(i == index ? .white.opacity(0.85) : .secondary)
                            }
                        }
                        .foregroundStyle(i == index ? .white : .primary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(i == index ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { index = i; run() }
                        .onHover { if $0 { index = i } }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .floatingPanel(radius: 14)
        .onAppear {
            query = ""
            index = 0
            DispatchQueue.main.async { focused = true }
        }
    }

    private func run() {
        guard index < results.count else { return }
        let cmd = results[index]
        editor.showCommandPalette = false
        DispatchQueue.main.async { cmd.run() }
    }
}

/// Fusion-style radial menu on right click.
struct MarkingMenu: View {
    @Bindable var editor: Editor
    let center: CGPoint

    var body: some View {
        let items = editor.markingMenuCommands
        ZStack {
            Color.black.opacity(0.001)
                .onTapGesture { editor.markingMenu = nil }
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary))
                .position(center)
                .onTapGesture { editor.markingMenu = nil }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, cmd in
                let angle = -Double.pi / 2 + Double(i) / Double(items.count) * 2 * .pi
                let r: Double = 92
                Button {
                    editor.markingMenu = nil
                    cmd.run()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: cmd.symbol).foregroundStyle(Color.accentColor)
                        Text(cmd.title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .floatingPanel(radius: 14)
                }
                .buttonStyle(.plain)
                .disabled(!cmd.available)
                .opacity(cmd.available ? 1 : 0.45)
                .position(x: center.x + cos(angle) * r * 1.35, y: center.y + sin(angle) * r)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
