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
            Text(editor.sketchId != nil ? "SKIZZE" : "KONSTRUKTION")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 78)
    }

    // MARK: Model

    private var modelTools: some View {
        HStack(alignment: .top, spacing: 2) {
            group("Erstellen") {
                ToolButton(title: "Skizze", symbol: "pencil.and.outline", shortcut: "L/R/C",
                           active: editor.command?.kind == .sketchPlane) { editor.beginCommand(.sketchPlane) }
                ToolButton(title: "Extrusion", symbol: "square.stack.3d.up.fill", shortcut: "E",
                           active: editor.command?.kind == .extrude) { editor.beginCommand(.extrude) }
                ToolButton(title: "Drehung", symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                           active: editor.command?.kind == .revolve) { editor.beginCommand(.revolve) }
            }
            RibbonDivider()
            group("Ändern") {
                ToolButton(title: "Abrundung", symbol: "button.roundedtop.horizontal", shortcut: "F",
                           active: editor.command?.kind == .fillet, enabled: hasBodies) { editor.beginCommand(.fillet) }
                ToolButton(title: "Fase", symbol: "triangle.bottomhalf.filled",
                           active: editor.command?.kind == .chamfer, enabled: hasBodies) { editor.beginCommand(.chamfer) }
                ToolButton(title: "Wand", symbol: "shippingbox",
                           active: editor.command?.kind == .shell, enabled: hasBodies) { editor.beginCommand(.shell) }
            }
            RibbonDivider()
            group("Verwalten") {
                ToolButton(title: "Parameter", symbol: "function", shortcut: "⌥⌘P") { editor.showParameters = true }
                ToolButton(title: "Import", symbol: "square.and.arrow.down", shortcut: "⌘I") { editor.importSTEP() }
            }
            RibbonDivider()
            group("3D-Druck") {
                ToolButton(title: "STL", symbol: "square.and.arrow.up", shortcut: "⌘E", enabled: hasBodies) { editor.exportSTL() }
                ToolButton(title: "Slicer", symbol: "printer.fill", shortcut: "⇧⌘P", enabled: hasBodies) { editor.openInSlicer() }
            }
        }
    }

    private var hasBodies: Bool { !editor.state.bodyOrder.isEmpty }

    // MARK: Sketch

    private var sketchTools: some View {
        HStack(alignment: .top, spacing: 2) {
            group("Erstellen") {
                tool(.line, "Linie", "line.diagonal", "L")
                tool(.rectangle, "Rechteck", "rectangle", "R")
                tool(.centerRectangle, "Mittig", "rectangle.center.inset.filled")
                tool(.circle, "Kreis", "circle", "C")
                tool(.arc, "Bogen", "point.topleft.down.to.point.bottomright.curvepath", "A")
            }
            RibbonDivider()
            group("Bemaßung") {
                tool(.dimension, "Bemaßung", "ruler", "D")
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
                GroupLabel(text: "Abhängigkeiten")
            }
            RibbonDivider()
            group("Ändern") {
                ToolButton(title: "Hilfslinie", symbol: "line.diagonal.arrow", shortcut: "X") { editor.toggleConstruction() }
                ToolButton(title: "Löschen", symbol: "trash", shortcut: "⌫") { editor.deleteSketchSelection() }
            }
            RibbonDivider()
            VStack(spacing: 4) {
                Button {
                    editor.finishSketch()
                } label: {
                    Label("Skizze fertig", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.green.gradient))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Skizze fertigstellen (⌘↩)")
                GroupLabel(text: "Beenden")
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
