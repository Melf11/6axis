import SwiftUI
import SixAxisCore

/// The main toolbar. Switches between the design and sketch workspaces like Fusion's contextual tabs.
struct Ribbon: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            workspaceBadge
            RibbonDivider()
            if editor.sketchId != nil { sketchTools } else { modelTools }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .floatingPanel(radius: 14)
        .animation(.snappy(duration: 0.2), value: editor.sketchId)
    }

    private var workspaceBadge: some View {
        VStack(spacing: 4) {
            Image(systemName: editor.sketchId != nil ? "pencil.and.ruler.fill" : "cube.fill")
                .font(.system(size: 18))
                .foregroundStyle(editor.sketchId != nil ? Color.orange : Color.accentColor)
                .frame(height: 26)
            Text(editor.sketchId != nil ? String(localized: "SKIZZE") : String(localized: "KONSTRUKTION"))
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 78)
    }

    // MARK: Model

    private var modelTools: some View {
        HStack(alignment: .top, spacing: 2) {
            group(String(localized: "Erstellen")) {
                ToolButton(title: String(localized: "Skizze"), symbol: "pencil.and.outline", shortcut: "L/R/C",
                           active: editor.command?.kind == .sketchPlane) { editor.beginCommand(.sketchPlane) }
                ToolButton(title: String(localized: "Extrusion"), symbol: "square.stack.3d.up.fill", shortcut: "E",
                           active: editor.command?.kind == .extrude) { editor.beginCommand(.extrude) }
                ToolButton(title: String(localized: "Drehung"), symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                           active: editor.command?.kind == .revolve) { editor.beginCommand(.revolve) }
                ToolButton(title: String(localized: "Bohrung"), symbol: "circle.dotted.circle", shortcut: "H",
                           active: editor.command?.kind == .hole, enabled: hasBodies) { editor.beginCommand(.hole) }
                ToolMenuButton(title: String(localized: "Muster"), symbol: PatternKind.rectangular.symbol,
                               active: [.rectPattern, .circularPattern, .mirror].contains(editor.command?.kind), enabled: hasBodies) {
                    menuItem(.rectPattern)
                    menuItem(.circularPattern)
                    menuItem(.mirror)
                }
            }
            RibbonDivider()
            group(String(localized: "Ändern")) {
                ToolButton(title: String(localized: "Abrundung"), symbol: "button.roundedtop.horizontal", shortcut: "F",
                           active: editor.command?.kind == .fillet, enabled: hasBodies) { editor.beginCommand(.fillet) }
                ToolButton(title: String(localized: "Fase"), symbol: "triangle.bottomhalf.filled",
                           active: editor.command?.kind == .chamfer, enabled: hasBodies) { editor.beginCommand(.chamfer) }
                ToolButton(title: String(localized: "Wand"), symbol: "shippingbox",
                           active: editor.command?.kind == .shell, enabled: hasBodies) { editor.beginCommand(.shell) }
                ToolButton(title: String(localized: "Gewinde"), symbol: "tornado",
                           active: editor.command?.kind == .thread, enabled: hasBodies) { editor.beginCommand(.thread) }
                ToolMenuButton(title: String(localized: "Körper"), symbol: "cube.transparent",
                               active: [.move, .combine].contains(editor.command?.kind), enabled: hasBodies) {
                    menuItem(.move)
                    menuItem(.combine)
                }
            }
            RibbonDivider()
            group(String(localized: "Konstruktion")) {
                ToolMenuButton(title: String(localized: "Ebene"), symbol: "square.3.layers.3d",
                               active: [.plane, .axis].contains(editor.command?.kind)) {
                    Button { editor.beginPlane(.offset) } label: { Label("Versetzte Ebene", systemImage: "square.3.layers.3d") }
                    Button { editor.beginPlane(.angle) } label: { Label("Ebene unter Winkel", systemImage: "rotate.3d") }
                    Button { editor.beginPlane(.midplane) } label: { Label("Mittelebene", systemImage: "square.split.1x2") }
                    Divider()
                    menuItem(.axis)
                }
                ToolButton(title: String(localized: "Parameter"), symbol: "function", shortcut: "⌥⌘P") { editor.showParameters = true }
            }
            RibbonDivider()
            group(String(localized: "Dokumentation")) {
                ToolButton(title: String(localized: "Zeichnung"), symbol: "doc.richtext", shortcut: "⇧⌘D", enabled: hasBodies) { editor.openDrawingWindow() }
            }
            RibbonDivider()
            group(String(localized: "3D-Druck")) {
                ToolButton(title: "STL", symbol: "square.and.arrow.up", shortcut: "⌘E", enabled: hasBodies) { editor.exportSTL() }
                ToolButton(title: String(localized: "Slicer"), symbol: "printer.fill", shortcut: "⇧⌘P", enabled: hasBodies) { editor.openInSlicer() }
            }
        }
    }

    private var hasBodies: Bool { !editor.state.bodyOrder.isEmpty }

    private func sketchMenuItem(_ t: SketchTool, _ symbol: String) -> some View {
        Button { editor.setSketchTool(t) } label: { Label(t.name, systemImage: symbol) }
    }

    private func menuItem(_ kind: CommandKind) -> some View {
        Button { editor.beginCommand(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
    }

    // MARK: Sketch

    private var sketchTools: some View {
        HStack(alignment: .top, spacing: 2) {
            group(String(localized: "Erstellen")) {
                tool(.line, String(localized: "Linie"), "line.diagonal", "L")
                tool(.rectangle, String(localized: "Rechteck"), "rectangle", "R")
                tool(.centerRectangle, String(localized: "Mittig"), "rectangle.center.inset.filled")
                tool(.circle, String(localized: "Kreis"), "circle", "C")
                tool(.arc, String(localized: "Bogen"), "point.topleft.down.to.point.bottomright.curvepath", "A")
                tool(.spline, String(localized: "Spline"), "scribble.variable")
                tool(.text, String(localized: "Text"), "textformat")
                tool(.dimension, String(localized: "Bemaßung"), "ruler", "D")
            }
            RibbonDivider()
            VStack(spacing: 4) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 2), count: 6), spacing: 2) {
                    ForEach(ConstraintTool.allCases) { ct in
                        IconButton(symbol: ct.symbol, help: ct.name, active: editor.sketchTool == .constraint(ct), size: 24) {
                            editor.setSketchTool(.constraint(ct))
                        }
                    }
                }
                GroupLabel(text: String(localized: "Abhängigkeiten"))
            }
            RibbonDivider()
            group(String(localized: "Ändern")) {
                tool(.trim, String(localized: "Trimmen"), "scissors", "T")
                tool(.extend, String(localized: "Verlängern"), "arrow.right.to.line")
                tool(.project, String(localized: "Projizieren"), "square.3.layers.3d.down.backward", "P")
                tool(.offset, String(localized: "Versatz"), "square.on.square.dashed", "O")
                ToolMenuButton(title: String(localized: "Muster"), symbol: "square.grid.3x1.below.line.grid.1x2",
                               active: [.mirror, .rectPattern, .circularPattern].contains(editor.sketchTool)) {
                    sketchMenuItem(.mirror, "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    sketchMenuItem(.rectPattern, "square.grid.3x1.below.line.grid.1x2")
                    sketchMenuItem(.circularPattern, "circle.hexagongrid")
                }
                ToolMenuButton(title: String(localized: "Ecke"), symbol: "button.roundedtop.horizontal",
                               active: [.sketchFillet, .sketchChamfer].contains(editor.sketchTool)) {
                    sketchMenuItem(.sketchFillet, "button.roundedtop.horizontal")
                    sketchMenuItem(.sketchChamfer, "triangle.bottomhalf.filled")
                }
                ToolButton(title: String(localized: "Hilfslinie"), symbol: "line.diagonal.arrow", shortcut: "X") { editor.toggleConstruction() }
            }
            RibbonDivider()
            VStack(spacing: 4) {
                Button {
                    editor.finishSketch()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                        Text("Skizze fertig").fixedSize()
                    }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.green.gradient))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Skizze fertigstellen (⌘↩)")
                GroupLabel(text: String(localized: "Fertig"))
            }
            .padding(.leading, 4)
        }
    }

    private func tool(_ t: SketchTool, _ title: String, _ symbol: String, _ key: String? = nil) -> some View {
        ToolButton(title: title, symbol: symbol, shortcut: key, active: editor.sketchTool == t) {
            editor.setSketchTool(editor.sketchTool == t ? .select : t)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 1) { content() }
            GroupLabel(text: title)
        }
    }
}
