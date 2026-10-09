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
            }
            RibbonDivider()
            group(String(localized: "Ändern")) {
                ToolButton(title: String(localized: "Abrundung"), symbol: "button.roundedtop.horizontal", shortcut: "F",
                           active: editor.command?.kind == .fillet, enabled: hasBodies) { editor.beginCommand(.fillet) }
                ToolButton(title: String(localized: "Fase"), symbol: "triangle.bottomhalf.filled",
                           active: editor.command?.kind == .chamfer, enabled: hasBodies) { editor.beginCommand(.chamfer) }
                ToolButton(title: String(localized: "Wand"), symbol: "shippingbox",
                           active: editor.command?.kind == .shell, enabled: hasBodies) { editor.beginCommand(.shell) }
            }
            RibbonDivider()
            group(String(localized: "Verwalten")) {
                ToolButton(title: String(localized: "Parameter"), symbol: "function", shortcut: "⌥⌘P") { editor.showParameters = true }
                ToolButton(title: String(localized: "Import"), symbol: "square.and.arrow.down", shortcut: "⌘I") { editor.importSTEP() }
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
            }
            RibbonDivider()
            group(String(localized: "Bemaßung")) {
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
                tool(.mirror, String(localized: "Spiegeln"), "arrow.left.and.right.righttriangle.left.righttriangle.right")
                tool(.rectPattern, String(localized: "Muster"), "square.grid.3x1.below.line.grid.1x2")
                tool(.circularPattern, String(localized: "Kreismuster"), "circle.hexagongrid")
                tool(.sketchFillet, String(localized: "Abrunden"), "button.roundedtop.horizontal")
                tool(.sketchChamfer, String(localized: "Fase"), "triangle.bottomhalf.filled")
                ToolButton(title: String(localized: "Hilfslinie"), symbol: "line.diagonal.arrow", shortcut: "X") { editor.toggleConstruction() }
                ToolButton(title: String(localized: "Löschen"), symbol: "trash", shortcut: "⌫") { editor.deleteSketchSelection() }
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
