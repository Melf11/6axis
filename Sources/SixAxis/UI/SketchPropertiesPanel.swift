import SwiftUI
import SixAxisCore

/// Round (or rectangle, see `roundTitle`) or angular with a number of corners. nil = round.
struct PolygonPicker: View {
    let sides: Int?
    let roundTitle: String
    let onChange: (Int?) -> Void
    private static let defaultSides = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { sides != nil }, set: { onChange($0 ? Self.defaultSides : nil) })) {
                Text(roundTitle).tag(false)
                Text("Eckig").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if let sides {
                LabeledRow(String(localized: "Ecken")) {
                    Stepper(value: Binding(get: { sides }, set: { onChange($0) }), in: RegularPolygon.sidesRange) {
                        Text("\(sides)").font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }
}

/// Settings of what is selected in a sketch, and of the tool "Mittig". Appears only then.
struct SketchPropertiesPanel: View {
    let editor: Editor

    var body: some View {
        if editor.sketchId != nil, editor.command == nil {
            if editor.sketchTool == .centerRectangle {
                panel(String(localized: "Mittig"), symbol: "rectangle.center.inset.filled") {
                    PolygonPicker(sides: editor.centerToolSides, roundTitle: String(localized: "Rechteck")) {
                        editor.centerToolSides = $0
                        editor.resetToolInputs()
                        editor.requestRedraw()
                    }
                }
            } else if editor.sketchTool == .select, let sk = editor.shownActiveSketch {
                let curves = editor.selectedSketchCurves.compactMap { sk.curve($0) }
                if !curves.isEmpty {
                    selection(curves, sk)
                }
            }
        }
    }

    @ViewBuilder
    private func selection(_ curves: [SketchCurve], _ sk: Sketch) -> some View {
        let ids = curves.map(\.id)
        let allCircles = curves.allSatisfy { if case .circle = $0.geometry { return true }; return false }
        let allLines = curves.allSatisfy(\.isLine)
        let allArcs = curves.allSatisfy { if case .arc = $0.geometry { return true }; return false }
        panel(title(curves, allCircles: allCircles, allLines: allLines, allArcs: allArcs), symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                if allCircles, let first = curves.first {
                    PolygonPicker(sides: first.polygon?.sides, roundTitle: String(localized: "Rund")) { editor.setPolygonSides(ids, $0) }
                    size(first.polygon == nil ? String(localized: "Durchmesser") : String(localized: "Schlüsselweite"), first, ids, sk)
                    if let polygon = first.polygon {
                        ExpressionField(label: String(localized: "Drehung"), text: editor.plainNumber(polygon.rotation), kind: .angle, editor: editor) { v in
                            if let degrees = try? editor.evaluator.value(v, kind: .angle) { editor.setPolygonRotation(ids, degrees) }
                        }
                    }
                } else if allLines, let first = curves.first {
                    size(String(localized: "Länge"), first, ids, sk)
                } else if allArcs, let first = curves.first {
                    size(String(localized: "Radius"), first, ids, sk)
                }
                Toggle(String(localized: "Hilfslinie"), isOn: Binding(
                    get: { curves.allSatisfy(\.construction) },
                    set: { editor.setConstruction(ids, $0) }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
        }
    }

    private func size(_ label: String, _ curve: SketchCurve, _ ids: [Int], _ sk: Sketch) -> some View {
        ExpressionField(label: label, text: editor.sizeText(curve, in: sk), kind: .length, editor: editor) { editor.setSize(ids, $0) }
            .id(curve.id)
    }

    private func title(_ curves: [SketchCurve], allCircles: Bool, allLines: Bool, allArcs: Bool) -> String {
        if curves.count > 1 { return String(localized: "\(curves.count) Elemente") }
        if allCircles { return curves.first?.polygon == nil ? String(localized: "Kreis") : String(localized: "Vieleck") }
        if allLines { return String(localized: "Linie") }
        if allArcs { return String(localized: "Bogen") }
        return curves.first?.isText == true ? String(localized: "Text") : String(localized: "Spline")
    }

    private func panel<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().opacity(0.5)
            content().padding(14)
        }
        .frame(width: 290)
        .floatingPanel()
    }
}
