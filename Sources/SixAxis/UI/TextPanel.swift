import SwiftUI
import SixAxisCore

/// Small floating dialog for sketch text, with live preview in the viewport.
struct TextPanel: View {
    @Bindable var editor: Editor
    @FocusState private var focused: Bool

    var body: some View {
        if let request = editor.textRequest {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat").foregroundStyle(Color.accentColor)
                    Text(request.editing == nil ? String(localized: "Text") : String(localized: "Text bearbeiten"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    IconButton(symbol: "xmark", help: String(localized: "Abbrechen (Esc)"), size: 22) { editor.cancelText() }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().opacity(0.5)
                Form {
                    TextField("Text", text: binding(\.text))
                        .focused($focused)
                    TextField("Höhe", text: binding(\.height))
                    Picker("Schrift", selection: binding(\.font)) {
                        ForEach(TextRequest.fonts, id: \.name) { Text($0.title).tag($0.name) }
                    }
                }
                .formStyle(.columns)
                .font(.system(size: 12))
                .padding(14)
                Text("Die Höhe ist die Höhe der Großbuchstaben.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                Divider().opacity(0.5).padding(.top, 10)
                HStack {
                    Spacer()
                    Button("Abbrechen") { editor.cancelText() }
                    Button("OK") { editor.commitText() }.keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
            .frame(width: 290)
            .floatingPanel()
            .onAppear { focused = true }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<TextRequest, T>) -> Binding<T> {
        Binding(get: { editor.textRequest![keyPath: key] },
                set: { editor.textRequest?[keyPath: key] = $0; editor.requestRedraw() })
    }
}
