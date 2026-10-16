import SwiftUI
import SixAxisCore

/// Right-hand panel in the milling workspace: the edited operation, the setup, or an overview with checks.
struct CAMPanel: View {
    @Bindable var editor: Editor

    var body: some View {
        if editor.workspace == .cam, editor.command == nil, editor.sketchId == nil {
            VStack(alignment: .leading, spacing: 0) {
                if let op = editor.editedOperation {
                    operation(op)
                } else if editor.showCAMSetup {
                    setup
                } else {
                    overview
                }
            }
            .frame(width: 290)
            .floatingPanel()
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func header(_ title: String, _ symbol: String, close: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.green)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            if let close { IconButton(symbol: "xmark", help: String(localized: "Schließen (Esc)"), size: 22, action: close) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func field(_ label: String, _ text: String, kind: ValueKind = .length, _ set: @escaping (String) -> Void) -> some View {
        ExpressionField(label: label, text: text, kind: kind, editor: editor, onChange: set)
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(String(localized: "Fräsen"), "gearshape.2.fill")
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                if let r = editor.camResult {
                    let s = r.stockMax - r.stockMin
                    LabeledContent(String(localized: "Rohteil"), value: "\(Int(s.x.rounded())) × \(Int(s.y.rounded())) × \(Int(s.z.rounded())) mm")
                    LabeledContent(String(localized: "Laufzeit"), value: String(localized: "ca. \(Int((r.time() / 60).rounded(.up))) min"))
                    if !r.warnings.isEmpty {
                        Text("Hinweise").font(.system(size: 11, weight: .semibold)).padding(.top, 4)
                        ForEach(Array(r.warnings.enumerated()), id: \.offset) { _, w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if editor.cam.operations.isEmpty {
                    Text("Oberseite eines Teils anklicken und „Kontur“ wählen – oder einen Taschenboden und „Tasche“.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if editor.camPlanning { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Berechne Bahnen …").font(.system(size: 11)) } }
            }
            .font(.system(size: 12))
            .padding(14)
        }
    }

    // MARK: Setup

    private var setup: some View {
        let c = editor.cam
        return VStack(alignment: .leading, spacing: 0) {
            header(String(localized: "Einrichtung"), "square.stack.3d.up") { editor.showCAMSetup = false }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow(String(localized: "Nullpunkt")) {
                    Picker("", selection: Binding(get: { c.origin }, set: { v in editor.updateCAM { $0.origin = v } })) {
                        ForEach(WorkOrigin.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                field(String(localized: "Rand"), c.margin) { v in editor.updateCAM { $0.margin = v } }
                field(String(localized: "Aufmaß oben"), c.topExtra) { v in editor.updateCAM { $0.topExtra = v } }
                field(String(localized: "Sicherheit"), c.safeZ) { v in editor.updateCAM { $0.safeZ = v } }
                LabeledRow(String(localized: "Steuerung")) {
                    Picker("", selection: Binding(get: { c.post }, set: { v in editor.updateCAM { $0.post = v } })) {
                        ForEach(PostProcessor.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                Text("Rohteil = alle sichtbaren Teile plus Rand. Teile liegen flach, gefräst wird von oben.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    // MARK: Operation

    private func operation(_ op: CAMOperation) -> some View {
        let set: (@escaping (inout CAMOperation) -> Void) -> Void = { change in editor.updateOperation(op.id, change) }
        let tools = editor.cam.tools
        return VStack(alignment: .leading, spacing: 0) {
            header(op.name, op.kind.symbol) { editor.editOperation(nil) }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow(String(localized: "Flächen")) {
                    HStack {
                        Text(op.faces.isEmpty ? String(localized: "Anklicken") : String(localized: "\(op.faces.count) ausgewählt"))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if !op.faces.isEmpty {
                            Button { set { $0.faces = [] } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.green, lineWidth: 1.2))
                }
                Text(hint(op.kind)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledRow(String(localized: "Werkzeug")) {
                    Picker("", selection: Binding(get: { op.tool ?? UUID() }, set: { v in set { $0.tool = v } })) {
                        ForEach(tools) { t in Text("T\(t.number) \(t.name)").tag(t.id) }
                    }
                    .labelsHidden()
                }
                if op.kind == .contour {
                    Picker("", selection: Binding(get: { op.side }, set: { v in set { $0.side = v } })) {
                        ForEach(ContourSide.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    field(String(localized: "Übertiefe"), op.overcut) { v in set { $0.overcut = v } }
                    LabeledRow(String(localized: "Haltestege")) {
                        Stepper(value: Binding(get: { op.tabs }, set: { v in set { $0.tabs = max(0, min(12, v)) } }), in: 0...12) {
                            Text(op.tabs == 0 ? String(localized: "keine") : "\(op.tabs)").font(.system(size: 12, design: .monospaced))
                        }
                    }
                    if op.tabs > 0 {
                        field(String(localized: "Stegbreite"), op.tabWidth) { v in set { $0.tabWidth = v } }
                        field(String(localized: "Steghöhe"), op.tabHeight) { v in set { $0.tabHeight = v } }
                    }
                }
                if op.kind != .drill {
                    Toggle(String(localized: "Gleichlauf"), isOn: Binding(get: { op.climb }, set: { v in set { $0.climb = v } }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                if let warnings = editor.camResult?.warnings.filter({ $0.hasPrefix("„\(op.name)“") }), !warnings.isEmpty {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            Divider().opacity(0.5)
            HStack {
                Button(role: .destructive) { editor.deleteOperation(op.id) } label: { Text("Löschen") }
                Spacer()
                Button("Fertig") { editor.editOperation(nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func hint(_ k: CAMOperationKind) -> String {
        switch k {
        case .contour: return String(localized: "Oberseite der Teile anklicken. Außen schneidet das Teil aus, Innen die Aussparungen.")
        case .pocket: return String(localized: "Boden der Tasche anklicken – Inseln bleiben stehen.")
        case .drill: return String(localized: "Bohrungen anklicken – oder die Oberseite eines Teils für alle seine Bohrungen.")
        }
    }
}

/// Tool library of the document (sheet).
struct ToolLibraryView: View {
    @Bindable var editor: Editor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Werkzeuge").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    editor.updateCAM { c in
                        let n = (c.tools.map(\.number).max() ?? 0) + 1
                        c.tools.append(CAMTool(number: n, name: String(localized: "Schaftfräser Ø6"), kind: .flat, diameter: 6, fluteLength: 22,
                                               rpm: 18000, feed: 1500, plunge: 400, stepdown: 3))
                    }
                } label: { Label("Werkzeug hinzufügen", systemImage: "plus") }
            }
            .padding(16)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(editor.cam.tools) { t in row(t) }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Text("Schnittwerte für Holz als Vorschlag – je nach Material und Maschine anpassen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 760, height: 520)
    }

    private func row(_ t: CAMTool) -> some View {
        func set(_ change: @escaping (inout CAMTool) -> Void) {
            editor.updateCAM { c in if let i = c.tools.firstIndex(where: { $0.id == t.id }) { change(&c.tools[i]) } }
        }
        func num(_ label: String, _ v: Double, _ unit: String, _ apply: @escaping (inout CAMTool, Double) -> Void) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    TextField("", value: Binding(get: { v }, set: { x in set { apply(&$0, x) } }), format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                    Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        return HStack(alignment: .bottom, spacing: 10) {
            Text("T\(t.number)").font(.system(size: 13, weight: .semibold, design: .monospaced)).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Name").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("", text: Binding(get: { t.name }, set: { x in set { $0.name = x } })).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            Picker("", selection: Binding(get: { t.kind }, set: { x in set { $0.kind = x } })) {
                ForEach(ToolKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            num("Ø", t.diameter, "mm") { $0.diameter = max(0.1, $1) }
            num(String(localized: "Schneide"), t.fluteLength, "mm") { $0.fluteLength = $1 }
            num(String(localized: "Drehzahl"), t.rpm, "") { $0.rpm = $1 }
            num(String(localized: "Vorschub"), t.feed, "") { $0.feed = $1 }
            num(String(localized: "Zustellung"), t.stepdown, "mm") { $0.stepdown = max(0.05, $1) }
            Button(role: .destructive) { editor.updateCAM { $0.tools.removeAll { $0.id == t.id } } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }
}
