import SwiftUI
import SixAxisCore

/// Small floating dialog for sketch patterns (rectangular or circular), with live preview in the viewport.
struct PatternPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        if let request = editor.patternRequest {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: request.kind == .rectangular ? "square.grid.3x1.below.line.grid.1x2" : "circle.hexagongrid")
                        .foregroundStyle(Color.accentColor)
                    Text(request.kind == .rectangular ? String(localized: "Rechteckmuster") : String(localized: "Kreismuster"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    IconButton(symbol: "xmark", help: String(localized: "Abbrechen (Esc)"), size: 22) { editor.cancelPattern() }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().opacity(0.5)
                Form {
                    TextField("Anzahl", text: binding(\.count))
                    if request.kind == .rectangular {
                        TextField("Abstand", text: binding(\.spacing))
                        Picker("Richtung", selection: binding(\.horizontal)) {
                            Text("Waagerecht").tag(true)
                            Text("Senkrecht").tag(false)
                        }
                        .pickerStyle(.segmented)
                        TextField("Reihen", text: binding(\.count2))
                        if Int(request.count2) ?? 1 > 1 { TextField("Reihenabstand", text: binding(\.spacing2)) }
                    } else {
                        TextField("Gesamtwinkel", text: binding(\.angle))
                    }
                }
                .formStyle(.columns)
                .font(.system(size: 12))
                .padding(14)
                Divider().opacity(0.5)
                HStack {
                    Spacer()
                    Button("Abbrechen") { editor.cancelPattern() }
                    Button("OK") { editor.commitPattern() }.keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
            .frame(width: 290)
            .floatingPanel()
        }
    }

    private func binding<T>(_ key: WritableKeyPath<PatternRequest, T>) -> Binding<T> {
        Binding(get: { editor.patternRequest![keyPath: key] },
                set: { editor.patternRequest?[keyPath: key] = $0; editor.requestRedraw() })
    }
}
