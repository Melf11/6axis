import SwiftUI
import VibeCore

/// User parameter table ("Parameter ändern" in Fusion). Any value field can reference these names.
struct ParametersSheet: View {
    @Bindable var editor: Editor
    @State private var params: [UserParameter] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parameter").font(.title3.weight(.semibold))
                    Text("Namen kannst du in jedem Wertfeld verwenden, z. B. „breite / 2“ oder „wand + 0,2 mm“.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var n = params.count + 1
                    while params.contains(where: { $0.name == "param\(n)" }) { n += 1 }
                    params.append(UserParameter(name: "param\(n)", expression: "10 mm"))
                } label: {
                    Label("Parameter", systemImage: "plus")
                }
            }
            .padding(16)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Name").gridColumnAlignment(.leading)
                    Text("Ausdruck")
                    Text("Wert")
                    Text("Kommentar")
                    Text("")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                ForEach($params) { $p in
                    GridRow {
                        TextField("name", text: $p.name).textFieldStyle(.roundedBorder).frame(width: 120)
                        TextField("Ausdruck", text: $p.expression).textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced)).frame(width: 150)
                        valueText(p).frame(width: 90, alignment: .leading)
                        TextField("", text: $p.comment).textFieldStyle(.roundedBorder).frame(width: 160)
                        Button {
                            params.removeAll { $0.id == p.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            if params.isEmpty {
                Text("Noch keine Parameter. Lege z. B. „wand = 2 mm“ an.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }

            Spacer(minLength: 12)
            Divider()
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    let cleaned = params.map { p -> UserParameter in
                        var q = p
                        q.name = p.name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
                        return q
                    }
                    editor.commit { $0.parameters = cleaned }
                    if editor.sketchId != nil { editor.solveActiveSketch(store: true) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(hasErrors)
            }
            .padding(16)
        }
        .frame(width: 640, height: 420)
        .onAppear { params = editor.doc.parameters }
    }

    private var hasErrors: Bool {
        let names = params.map(\.name)
        if Set(names).count != names.count { return true }
        let ev = Evaluator(parameters: params)
        return params.contains { (try? ev.value($0.expression)) == nil || !isValidName($0.name) }
    }

    private func isValidName(_ n: String) -> Bool {
        guard let first = n.first, first.isLetter || first == "_" else { return false }
        return n.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    @ViewBuilder
    private func valueText(_ p: UserParameter) -> some View {
        let ev = Evaluator(parameters: params)
        if !isValidName(p.name) {
            Text("Ungültiger Name").font(.system(size: 11)).foregroundStyle(.red)
        } else if let v = try? ev.value(p.expression) {
            Text(formatValue(v)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        } else {
            Text("Fehler").font(.system(size: 11)).foregroundStyle(.red)
        }
    }
}
