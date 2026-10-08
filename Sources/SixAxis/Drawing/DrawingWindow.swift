import SwiftUI
import SixAxisCore

/// The technical drawing editor (separate window). Opens via "Zeichnung" (⇧⌘D).
struct DrawingWindow: View {
    @Bindable var editor: Editor
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var zoomStart: CGFloat = 1
    @State private var showTitleBlock = false

    private var controller: DrawingController { editor.drawing }

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
            if let page = controller.page {
                sheetCanvas(page)
            } else {
                ProgressView("Zeichnung wird erstellt …")
            }
        }
        .overlay(alignment: .bottomLeading) { status.padding(12) }
        .overlay(alignment: .bottomTrailing) { zoomControls.padding(12) }
        .toolbar { toolbar }
        .navigationTitle("Zeichnung – " + (editor.fileURL?.deletingPathExtension().lastPathComponent ?? "Unbenannt"))
        .onAppear {
            controller.isOpen = true
            controller.regenerate(editor)
        }
        .onDisappear { controller.isOpen = false }
        .onChange(of: editor.modelRevision) { controller.schedule(editor) }
        .onChange(of: editor.command == nil) { controller.schedule(editor) }
        .onChange(of: editor.doc.drawing) { controller.schedule(editor, delay: 0.05) }
    }

    // MARK: Sheet

    private func sheetCanvas(_ page: DrawingPage) -> some View {
        GeometryReader { geo in
            let fit = min((geo.size.width - 48) / page.sheet.width, (geo.size.height - 48) / page.sheet.height)
            let k = max(0.2, fit * zoom)
            let w = page.sheet.width * k, h = page.sheet.height * k
            let origin = CGPoint(x: (geo.size.width - w) / 2 + pan.width, y: (geo.size.height - h) / 2 + pan.height)
            Canvas { ctx, _ in
                let rect = CGRect(origin: origin, size: CGSize(width: w, height: h))
                var shadow = ctx
                shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 10, y: 4))
                shadow.fill(Path(rect), with: .color(.white))
                ctx.withCGContext { cg in
                    cg.translateBy(x: origin.x, y: origin.y + h)
                    cg.scaleBy(x: 1, y: -1)
                    DrawingRenderer.draw(page, in: cg, pointsPerMM: k)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in pan = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height) }
                    .onEnded { _ in dragStart = pan }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in zoom = max(0.3, min(12, zoomStart * v.magnification)) }
                    .onEnded { _ in zoomStart = zoom }
            )
            .onTapGesture(count: 2) { resetView() }
        }
    }

    private func resetView() {
        withAnimation(.snappy) {
            zoom = 1; zoomStart = 1
            pan = .zero; dragStart = .zero
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "minus.magnifyingglass", help: "Verkleinern") { zoom = max(0.3, zoom / 1.25); zoomStart = zoom }
            Text("\(Int((zoom * 100).rounded())) %").font(.system(size: 11, design: .rounded)).monospacedDigit().frame(width: 46)
            IconButton(symbol: "plus.magnifyingglass", help: "Vergrößern") { zoom = min(12, zoom * 1.25); zoomStart = zoom }
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Blatt einpassen (Doppelklick)") { resetView() }
        }
        .padding(4)
        .floatingPanel(radius: 9)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if controller.isUpdating {
                ProgressView().controlSize(.small)
                Text("Aktualisiere …")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Synchron mit dem Modell")
            }
            if let page = controller.page, !page.isEmpty {
                Text("· \(page.sheet.name) quer · Maßstab \(page.scale.label)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .floatingPanel(radius: 13)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Picker("Blatt", selection: Binding(get: { editor.drawingSettings.sheet },
                                               set: { v in editor.updateDrawingSettings { $0.sheet = v } })) {
                ForEach(DrawingSettings.SheetChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("Blattgröße")
            Picker("Maßstab", selection: Binding(get: { editor.drawingSettings.scale ?? "" },
                                                 set: { v in editor.updateDrawingSettings { $0.scale = v.isEmpty ? nil : v } })) {
                Text("Maßstab automatisch").tag("")
                ForEach(DrawingScale.all, id: \.label) { Text($0.label).tag($0.label) }
            }
            .help("Maßstab (ISO 5455)")
        }
        ToolbarItemGroup {
            Toggle(isOn: settingBinding(\.showDimensions)) { Label("Bemaßung", systemImage: "ruler") }
                .help("Bemaßung anzeigen")
            Toggle(isOn: settingBinding(\.showHidden)) { Label("Verdeckte Kanten", systemImage: "square.dashed") }
                .help("Verdeckte Kanten anzeigen")
            Toggle(isOn: settingBinding(\.showIso)) { Label("Isometrie", systemImage: "cube") }
                .help("Isometrische Ansicht anzeigen")
            Button { showTitleBlock = true } label: { Label("Schriftfeld", systemImage: "list.bullet.rectangle") }
                .help("Schriftfeld ausfüllen")
                .popover(isPresented: $showTitleBlock) { TitleBlockEditor(editor: editor) }
            Button { editor.printDrawing() } label: { Label("Drucken", systemImage: "printer") }
                .help("Drucken (⌘P)")
                .keyboardShortcut("p")
            Button { editor.exportDrawingPDF() } label: { Label("PDF", systemImage: "arrow.down.doc") }
                .help("Als PDF exportieren (maßstabsgetreu)")
        }
    }

    private func settingBinding(_ key: WritableKeyPath<DrawingSettings, Bool>) -> Binding<Bool> {
        Binding(get: { editor.drawingSettings[keyPath: key] },
                set: { v in editor.updateDrawingSettings { $0[keyPath: key] = v } })
    }
}

/// Title block fields (ISO 7200). Changes are committed when a field loses focus or on ↩.
private struct TitleBlockEditor: View {
    @Bindable var editor: Editor
    @State private var title = ""
    @State private var number = ""
    @State private var author = ""
    @State private var material = ""

    var body: some View {
        Form {
            TextField("Benennung", text: $title, prompt: Text(editor.fileURL?.deletingPathExtension().lastPathComponent ?? "Unbenannt"))
            TextField("Zeichnungsnummer", text: $number)
            TextField("Material", text: $material, prompt: Text("z. B. Eiche massiv"))
            TextField("Erstellt von", text: $author)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .onAppear {
            let s = editor.drawingSettings
            title = s.title; number = s.drawingNumber; author = s.author; material = s.material
        }
        .onSubmit(apply)
        .onDisappear(perform: apply)
    }

    private func apply() {
        editor.updateDrawingSettings {
            $0.title = title
            $0.drawingNumber = number
            $0.author = author
            $0.material = material
        }
    }
}
