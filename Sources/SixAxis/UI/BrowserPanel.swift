import SwiftUI
import SixAxisCore

/// Left-hand model tree: origin, bodies, sketches.
struct BrowserPanel: View {
    @Bindable var editor: Editor
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var bodiesOpen = true
    @State private var sketchesOpen = true
    @State private var materialFor: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BROWSER").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "sidebar.left", help: String(localized: "Browser ausblenden"), size: 22) { editor.browserVisible = false }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(symbol: "doc", title: editor.fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Unbenannt"), bold: true)
                    row(symbol: "move.3d", title: String(localized: "Ursprung"), indent: 1,
                        eye: editor.showOriginPlanes, onEye: {
                            editor.showOriginPlanes.toggle()
                            editor.sceneVersion &+= 1
                        })
                    section(String(localized: "Körper"), count: editor.state.bodyOrder.count, open: $bodiesOpen)
                    if bodiesOpen {
                        ForEach(editor.state.bodyOrder, id: \.self) { id in
                            bodyRow(id)
                        }
                    }
                    section(String(localized: "Skizzen"), count: sketches.count, open: $sketchesOpen)
                    if sketchesOpen {
                        ForEach(sketches) { f in
                            sketchRow(f)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 236)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .floatingPanel()
        .sheet(item: Binding(get: { materialFor.map(IdentifiedUUID.init) }, set: { materialFor = $0?.id })) { item in
            BodyMaterialSheet(editor: editor, bodyId: item.id)
        }
    }

    private var sketches: [Feature] {
        editor.doc.features.prefix(editor.doc.activeCount).filter { if case .sketch = $0.kind { return true }; return false }
    }

    private func section(_ title: String, count: Int, open: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { open.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .padding(.leading, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bodyRow(_ id: UUID) -> some View {
        let selected = editor.selection.contains(.body(id))
        return HStack(spacing: 6) {
            eyeButton(editor.doc.isBodyVisible(id)) { editor.toggleBodyVisibility(id) }
            Image(systemName: "cube.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor.opacity(0.85))
            if renaming == id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { editor.renameBody(id, to: renameText); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Text(editor.doc.bodyName(id)).font(.system(size: 12)).lineLimit(1)
                if let m = editor.doc.bodies[id]?.material, !m.isEmpty {
                    Text(m).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if editor.state.errors.isEmpty == false, let src = editor.state.bodies[id]?.sourceFeature, editor.state.errors[src] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .padding(.leading, 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { renameText = editor.doc.bodyName(id); renaming = id }
        .onTapGesture {
            editor.selection = selected ? [] : [.body(id)]
            editor.requestRedraw()
        }
        .contextMenu {
            Button("Umbenennen") { renameText = editor.doc.bodyName(id); renaming = id }
            Button("Material & Faserrichtung …") { materialFor = id }
            Button(editor.doc.isBodyVisible(id) ? String(localized: "Ausblenden") : String(localized: "Einblenden")) { editor.toggleBodyVisibility(id) }
            Divider()
            Button("Als STL exportieren …") { editor.selection = [.body(id)]; editor.exportSTL() }
            Button("Als STEP exportieren …") { editor.selection = [.body(id)]; editor.exportSTEP() }
            Button("Im Slicer öffnen") { editor.selection = [.body(id)]; editor.openInSlicer() }
        }
    }

    private func sketchRow(_ f: Feature) -> some View {
        let visible = !editor.doc.hiddenSketches.contains(f.id)
        let editing = editor.sketchId == f.id
        return HStack(spacing: 6) {
            eyeButton(visible) { editor.toggleSketchVisibility(f.id) }
            Image(systemName: "pencil.and.outline").font(.system(size: 11)).foregroundStyle(.orange)
            Text(f.name).font(.system(size: 12, weight: editing ? .semibold : .regular)).lineLimit(1)
            Spacer()
            if editor.state.errors[f.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .padding(.leading, 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(editing ? Color.orange.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editor.editFeature(f.id) }
        .contextMenu {
            Button("Skizze bearbeiten") { editor.editFeature(f.id) }
            Button(visible ? String(localized: "Ausblenden") : String(localized: "Einblenden")) { editor.toggleSketchVisibility(f.id) }
            Divider()
            Button("Löschen", role: .destructive) { editor.deleteFeature(f.id) }
        }
    }

    private func row(symbol: String, title: String, indent: Int = 0, bold: Bool = false, eye: Bool? = nil, onEye: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            if let eye, let onEye { eyeButton(eye, onEye) }
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: bold ? .semibold : .regular)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .padding(.leading, CGFloat(indent) * 12)
    }

    private func eyeButton(_ visible: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: visible ? "eye" : "eye.slash")
                .font(.system(size: 10))
                .foregroundStyle(visible ? .secondary : .tertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visible ? String(localized: "Ausblenden") : String(localized: "Einblenden"))
    }
}

private struct IdentifiedUUID: Identifiable { let id: UUID }

/// Material and grain direction of a body (used in parts lists and part drawings).
struct BodyMaterialSheet: View {
    @Bindable var editor: Editor
    let bodyId: UUID
    @State private var material = ""
    @State private var grain: GrainDirection = .none
    @Environment(\.dismiss) private var dismiss

    static let presets = [
        String(localized: "Eiche massiv"), String(localized: "Buche massiv"), String(localized: "Ahorn massiv"), String(localized: "Nussbaum massiv"), String(localized: "Kiefer massiv"), String(localized: "Fichte massiv"), String(localized: "Lärche massiv"),
        String(localized: "Birke Multiplex"), String(localized: "Buche Multiplex"), String(localized: "Sperrholz"), String(localized: "Tischlerplatte"), String(localized: "MDF"), String(localized: "MDF lackiert"), String(localized: "Spanplatte"), String(localized: "Spanplatte melaminbeschichtet"), String(localized: "OSB"), String(localized: "HPL"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editor.doc.bodyName(bodyId)).font(.title3.weight(.semibold)).padding(16)
            Form {
                HStack {
                    TextField("Material", text: $material, prompt: Text("z. B. Eiche massiv"))
                    Menu {
                        ForEach(Self.presets, id: \.self) { p in Button(p) { material = p } }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Werkstoff auswählen")
                }
                Picker("Faserrichtung", selection: $grain) {
                    ForEach(GrainDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Längs = entlang der größten Abmessung. Wird als Pfeil in der Einzelteilzeichnung und in der Stückliste gezeigt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    let m = material.trimmingCharacters(in: .whitespaces), g = grain
                    editor.commit { d in
                        var meta = d.bodies[bodyId] ?? BodyMeta(name: editor.doc.bodyName(bodyId))
                        meta.material = m
                        meta.grain = g
                        d.bodies[bodyId] = meta
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420)
        .onAppear {
            material = editor.doc.bodies[bodyId]?.material ?? ""
            grain = editor.doc.bodies[bodyId]?.grain ?? .none
        }
    }
}
