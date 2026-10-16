import SwiftUI
import SixAxisCore

/// Right-hand panel for the view tools: measuring and the section view (nothing here changes the model).
struct InspectPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        if editor.command == nil, editor.sketchId == nil, editor.measuring || editor.section != nil {
            VStack(alignment: .leading, spacing: 0) {
                if editor.measuring { measure }
                if editor.measuring && editor.section != nil { Divider().opacity(0.5) }
                if let s = editor.section { section(s) }
            }
            .frame(width: 290)
            .floatingPanel()
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func header(_ title: String, _ symbol: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            IconButton(symbol: "xmark", help: String(localized: "Schließen (Esc)"), size: 22, action: close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Measure

    private var measure: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(String(localized: "Messen"), "ruler") { editor.endMeasure() }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                if let r = editor.measureResult, !r.rows.isEmpty {
                    ForEach(Array(r.rows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.label).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.format(row)).font(.system(size: 13, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                Text(editor.measurePicks.isEmpty ? String(localized: "Fläche oder Kante anklicken – eine zweite für Abstand und Winkel.")
                                                 : String(localized: "Klick auf ein drittes Element beginnt neu · Esc beendet"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    static func format(_ row: Measure.Row) -> String {
        switch row.unit {
        case .length: return formatValue(row.value, kind: .length)
        case .angle: return formatValue(row.value, kind: .angle)
        case .area:
            let v = row.value >= 10_000 ? row.value / 100 : row.value
            let unit = row.value >= 10_000 ? "cm²" : "mm²"
            return v.formatted(.number.precision(.fractionLength(0...2))) + " " + unit
        }
    }

    // MARK: Section

    private func section(_ s: SectionView) -> some View {
        let range = editor.modelRange(axis: s.axis)
        let pad = max((range.upperBound - range.lowerBound) * 0.02, 1)
        return VStack(alignment: .leading, spacing: 0) {
            header(String(localized: "Schnittansicht"), "square.split.diagonal.2x2") { editor.toggleSection() }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: Binding(get: { s.axis }, set: { editor.setSectionAxis($0) })) {
                    Text("X").tag(0)
                    Text("Y").tag(1)
                    Text("Z").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                Slider(value: Binding(get: { s.offset }, set: { v in editor.section?.offset = v }),
                       in: (range.lowerBound - pad)...(range.upperBound + pad))
                LabeledRow(String(localized: "Position")) {
                    TextField("", value: Binding(get: { s.offset }, set: { v in editor.section?.offset = v }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("mm").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle(String(localized: "Andere Seite zeigen"), isOn: Binding(get: { s.flip }, set: { v in editor.section?.flip = v }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Text("Nur Ansicht – das Modell bleibt unverändert.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }
}
