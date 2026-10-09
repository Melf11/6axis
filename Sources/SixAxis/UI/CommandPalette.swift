import AppKit
import SwiftUI
import SixAxisCore

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
            EditorCommand(id: "sketch", title: String(localized: "Skizze erstellen"), symbol: "pencil.and.outline", keywords: "sketch zeichnen", available: !inSketch) { self.beginCommand(.sketchPlane) },
            EditorCommand(id: "extrude", title: String(localized: "Extrusion"), symbol: "square.stack.3d.up.fill", shortcut: "E", keywords: "extrude ziehen press pull", available: true) { self.beginCommand(.extrude) },
            EditorCommand(id: "revolve", title: String(localized: "Drehung"), symbol: "arrow.trianglehead.2.clockwise.rotate.90", keywords: "revolve rotation", available: true) { self.beginCommand(.revolve) },
            EditorCommand(id: "fillet", title: String(localized: "Abrundung"), symbol: "button.roundedtop.horizontal", shortcut: "F", keywords: "fillet radius runden", available: hasBodies) { self.beginCommand(.fillet) },
            EditorCommand(id: "chamfer", title: String(localized: "Fase"), symbol: "triangle.bottomhalf.filled", keywords: "chamfer", available: hasBodies) { self.beginCommand(.chamfer) },
            EditorCommand(id: "shell", title: String(localized: "Wandstärke"), symbol: "shippingbox", keywords: "shell aushöhlen hohl", available: hasBodies) { self.beginCommand(.shell) },
            EditorCommand(id: "line", title: String(localized: "Linie"), symbol: "line.diagonal", shortcut: "L", keywords: "line", available: true) { self.setSketchTool(.line) },
            EditorCommand(id: "rect", title: String(localized: "Rechteck"), symbol: "rectangle", shortcut: "R", keywords: "rectangle", available: true) { self.setSketchTool(.rectangle) },
            EditorCommand(id: "crect", title: String(localized: "Mittelpunkt-Rechteck"), symbol: "rectangle.center.inset.filled", keywords: "center rectangle", available: true) { self.setSketchTool(.centerRectangle) },
            EditorCommand(id: "circle", title: String(localized: "Kreis"), symbol: "circle", shortcut: "C", keywords: "circle", available: true) { self.setSketchTool(.circle) },
            EditorCommand(id: "offset", title: String(localized: "Versatz"), symbol: "square.on.square.dashed", shortcut: "O", keywords: "offset versatz parallel wandstärke kontur", available: sketchId != nil) { self.setSketchTool(.offset) },
            EditorCommand(id: "mirror", title: String(localized: "Spiegeln"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", shortcut: nil, keywords: "mirror spiegeln symmetrie", available: sketchId != nil) { self.setSketchTool(.mirror) },
            EditorCommand(id: "rectPattern", title: String(localized: "Rechteckmuster"), symbol: "square.grid.3x1.below.line.grid.1x2", shortcut: nil, keywords: "pattern muster reihe lochreihe system 32", available: sketchId != nil) { self.setSketchTool(.rectPattern) },
            EditorCommand(id: "circularPattern", title: String(localized: "Kreismuster"), symbol: "circle.hexagongrid", shortcut: nil, keywords: "pattern muster kreis lochkreis", available: sketchId != nil) { self.setSketchTool(.circularPattern) },
            EditorCommand(id: "trim", title: String(localized: "Trimmen"), symbol: "scissors", shortcut: "T", keywords: "trim schneiden kürzen", available: sketchId != nil) { self.setSketchTool(.trim) },
            EditorCommand(id: "extend", title: String(localized: "Verlängern"), symbol: "arrow.right.to.line", shortcut: nil, keywords: "extend verlängern", available: sketchId != nil) { self.setSketchTool(.extend) },
            EditorCommand(id: "sketchFillet", title: String(localized: "Ecke abrunden"), symbol: "button.roundedtop.horizontal", shortcut: nil, keywords: "skizze abrundung radius fillet corner", available: sketchId != nil) { self.setSketchTool(.sketchFillet) },
            EditorCommand(id: "sketchChamfer", title: String(localized: "Ecke fasen"), symbol: "triangle.bottomhalf.filled", shortcut: nil, keywords: "skizze fase chamfer corner", available: sketchId != nil) { self.setSketchTool(.sketchChamfer) },
            EditorCommand(id: "spline", title: String(localized: "Spline"), symbol: "scribble.variable", shortcut: nil, keywords: "spline kurve curve freiform", available: true) { self.setSketchTool(.spline) },
            EditorCommand(id: "arc", title: String(localized: "Bogen (3 Punkte)"), symbol: "point.topleft.down.to.point.bottomright.curvepath", shortcut: "A", keywords: "arc", available: true) { self.setSketchTool(.arc) },
            EditorCommand(id: "dim", title: String(localized: "Bemaßung"), symbol: "ruler", shortcut: "D", keywords: "dimension maß", available: inSketch) { self.setSketchTool(.dimension) },
            EditorCommand(id: "finish", title: String(localized: "Skizze fertigstellen"), symbol: "checkmark.circle", keywords: "finish", available: inSketch) { self.finishSketch() },
            EditorCommand(id: "settings", title: String(localized: "Einstellungen"), symbol: "gearshape", shortcut: "⌘,", keywords: "settings preferences maus scroll invertieren", available: true) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            EditorCommand(id: "params", title: String(localized: "Parameter ändern"), symbol: "function", keywords: "parameters variablen", available: true) { self.showParameters = true },
            EditorCommand(id: "drawing", title: String(localized: "Technische Zeichnung"), symbol: "doc.richtext", shortcut: "⇧⌘D", keywords: "zeichnung drawing 3-tafel ansicht bemaßung pdf", available: hasBodies) { self.openDrawingWindow() },
            EditorCommand(id: "stl", title: String(localized: "Als STL exportieren"), symbol: "square.and.arrow.up", keywords: "export 3d druck print", available: hasBodies) { self.exportSTL() },
            EditorCommand(id: "step", title: String(localized: "Als STEP exportieren"), symbol: "square.and.arrow.up.on.square", keywords: "export cad", available: hasBodies) { self.exportSTEP() },
            EditorCommand(id: "slicer", title: String(localized: "Im Slicer öffnen"), symbol: "printer.fill", keywords: "print druck prusa bambu orca cura", available: hasBodies) { self.openInSlicer() },
            EditorCommand(id: "import", title: "STEP importieren", symbol: "square.and.arrow.down", keywords: "import", available: true) { self.importSTEP() },
            EditorCommand(id: "fit", title: String(localized: "Alles einpassen"), symbol: "arrow.up.left.and.arrow.down.right", keywords: "zoom fit", available: true) { self.fitAll() },
            EditorCommand(id: "home", title: String(localized: "Ausgangsansicht"), symbol: "house", keywords: "home view", available: true) { self.homeView() },
            EditorCommand(id: "ortho", title: String(localized: "Orthografisch / Perspektive"), symbol: "perspective", shortcut: "O", keywords: "projection", available: true) { self.toggleProjection() },
            EditorCommand(id: "undo", title: String(localized: "Widerrufen"), symbol: "arrow.uturn.backward", shortcut: "⌘Z", keywords: "undo", available: canUndo) { self.undo() },
            EditorCommand(id: "redo", title: String(localized: "Wiederholen"), symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", keywords: "redo", available: canRedo) { self.redo() },
        ]
        for ct in ConstraintTool.allCases {
            c.append(EditorCommand(id: "c-\(ct.rawValue)", title: String(localized: "Abhängigkeit: \(ct.name)"), symbol: ct.symbol, keywords: "constraint", available: inSketch) {
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

/// Fusion-style radial (marking) menu on right click. Selection works by *direction*:
/// a line runs from the center ring to the pointer and the item in that direction lights up,
/// so a click anywhere in that direction picks it.
struct MarkingMenu: View {
    @Bindable var editor: Editor
    let center: CGPoint
    @State private var appeared = false

    private var mouse: CGPoint? {
        get { editor.markingMenuPointer }
        nonmutating set { editor.markingMenuPointer = newValue }
    }

    private let ringRadius: CGFloat = 17
    private let deadZone: CGFloat = 24
    private let radiusX: CGFloat = 150
    private let radiusY: CGFloat = 118

    var body: some View {
        let items = editor.markingMenuCommands
        let positions = itemPositions(items.count)
        let active = highlighted(items, positions)
        ZStack {
            Color.black.opacity(0.001)

            Canvas { ctx, _ in drawGuide(ctx, items: items, positions: positions, active: active) }
                .allowsHitTesting(false)

            ForEach(Array(items.enumerated()), id: \.element.id) { i, cmd in
                itemView(cmd, isActive: active == i)
                    .position(appeared ? positions[i] : center)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case let .active(p) = phase { mouse = p }
        }
        .onTapGesture { p in
            mouse = p
            let pick = highlighted(items, positions)
            editor.markingMenu = nil
            if let pick { items[pick].run() }
        }
        .animation(.snappy(duration: 0.12), value: active)
        .onAppear {
            mouse = center
            withAnimation(.spring(duration: 0.22, bounce: 0.25)) { appeared = true }
        }
    }

    private func itemView(_ cmd: EditorCommand, isActive: Bool) -> some View {
        let fill: AnyShapeStyle = isActive ? AnyShapeStyle(Color.accentColor) : PanelStyle.fill
        return HStack(spacing: 6) {
            Image(systemName: cmd.symbol)
                .foregroundStyle(isActive ? Color.white : Color.accentColor)
            Text(cmd.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(isActive ? 0 : 0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(isActive ? 0.25 : 0.12), radius: isActive ? 8 : 6, y: 2)
        .scaleEffect(isActive ? 1.06 : 1)
        .opacity(cmd.available ? 1 : 0.4)
        .allowsHitTesting(false)
    }

    /// Items on an ellipse, starting at the top, clockwise.
    private func itemPositions(_ n: Int) -> [CGPoint] {
        let step: CGFloat = 2 * .pi / CGFloat(max(n, 1))
        return (0..<n).map { i -> CGPoint in
            let a: CGFloat = -.pi / 2 + CGFloat(i) * step
            return CGPoint(x: center.x + cos(a) * radiusX, y: center.y + sin(a) * radiusY)
        }
    }

    /// Item whose direction (seen from the center) is closest to the pointer's direction.
    private func highlighted(_ items: [EditorCommand], _ positions: [CGPoint]) -> Int? {
        guard let m = mouse, hypot(m.x - center.x, m.y - center.y) > deadZone else { return nil }
        let a = atan2(m.y - center.y, m.x - center.x)
        var best: (Int, CGFloat)?
        for (i, p) in positions.enumerated() {
            var d = abs(atan2(p.y - center.y, p.x - center.x) - a)
            if d > .pi { d = 2 * .pi - d }
            if best == nil || d < best!.1 { best = (i, d) }
        }
        guard let (i, _) = best, items[i].available else { return nil }
        return i
    }

    private func drawGuide(_ ctx: GraphicsContext, items: [EditorCommand], positions: [CGPoint], active: Int?) {
        let ring = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
        ctx.fill(ring, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        ctx.stroke(ring, with: .color(.primary.opacity(0.25)), lineWidth: 1.5)

        guard let m = mouse else { return }
        let dx = m.x - center.x, dy = m.y - center.y
        let dist = hypot(dx, dy)
        guard dist > deadZone else {
            // Small cross in the dead zone: clicking here closes the menu.
            var x = Path()
            x.move(to: CGPoint(x: center.x - 4, y: center.y - 4)); x.addLine(to: CGPoint(x: center.x + 4, y: center.y + 4))
            x.move(to: CGPoint(x: center.x + 4, y: center.y - 4)); x.addLine(to: CGPoint(x: center.x - 4, y: center.y + 4))
            ctx.stroke(x, with: .color(.secondary), lineWidth: 1.5)
            return
        }
        let ux = dx / dist, uy = dy / dist
        let color: Color = active != nil ? .accentColor : .secondary

        // Highlighted wedge on the ring, pointing towards the selection.
        let angle = atan2(uy, ux)
        let half = Double.pi / Double(max(items.count, 1))
        var wedge = Path()
        wedge.addArc(center: center, radius: ringRadius, startAngle: .radians(angle - half), endAngle: .radians(angle + half), clockwise: false)
        ctx.stroke(wedge, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        // Connection line from the ring to the pointer.
        var line = Path()
        line.move(to: CGPoint(x: center.x + ux * (ringRadius + 3), y: center.y + uy * (ringRadius + 3)))
        line.addLine(to: m)
        ctx.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: m.x - 3.5, y: m.y - 3.5, width: 7, height: 7)), with: .color(color))
    }
}
