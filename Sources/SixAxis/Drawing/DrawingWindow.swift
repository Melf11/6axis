import SwiftUI
import SixAxisCore
import simd

/// The technical drawing editor (separate window). Opens via "Zeichnung" (⇧⌘D).
///
/// Editing: hover highlights dimensions and views; drag a dimension to move its line (and the value
/// along it), drag a view to move it (projection alignment is kept), drag empty paper to pan.
/// ⌫ hides an automatic dimension or deletes a user dimension. "Maß hinzufügen" (D): click two
/// points (they snap to corners and hole centres), then place the line.
struct DrawingWindow: View {
    @Bindable var editor: Editor

    enum Tool { case select, addDimension }

    private enum Drag {
        case pan(start: CGSize)
        case dimension(id: String, start: Vec2, offset: DimensionOffset, normal: Vec2, along: Vec2)
        case custom(id: UUID, start: Vec2, offset: Double, normal: Vec2)
        case view(id: String, start: Vec2, offset: Vec2, constraint: PlacedView.Constraint)
    }

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var zoomStart: CGFloat = 1
    @State private var tool: Tool = .select
    @State private var hover: String?
    @State private var hoverView: String?
    @State private var selected: String?
    @State private var mouse: Vec2?
    @State private var picks: [DrawingSnapPoint] = []
    @State private var drag: Drag?
    @State private var dragSnapshot: CADDocument?
    @State private var showTitleBlock = false
    @State private var pageIndex = 0
    @FocusState private var focused: Bool

    private var controller: DrawingController { editor.drawing }

    /// The sheet shown in the editor (clamped when the number of sheets changes).
    private var currentPage: DrawingPage? {
        let pages = controller.pages
        return pages.isEmpty ? nil : pages[min(pageIndex, pages.count - 1)]
    }

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
            if let page = currentPage {
                sheetCanvas(page)
            } else {
                ProgressView("Zeichnung wird erstellt …")
            }
        }
        .overlay(alignment: .bottomLeading) { status.padding(12) }
        .overlay(alignment: .bottomTrailing) { zoomControls.padding(12) }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                sheetTabs
                selectionBar
            }
            .padding(.top, 10)
        }
        .toolbar { toolbar }
        .navigationTitle("Zeichnung – " + (editor.fileURL?.deletingPathExtension().lastPathComponent ?? "Unbenannt"))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.delete) { deleteSelection(); return .handled }
        .onKeyPress(.deleteForward) { deleteSelection(); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "dD")) { _ in setTool(.addDimension); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "vV")) { _ in setTool(.select); return .handled }
        .onAppear {
            controller.isOpen = true
            controller.regenerate(editor)
            focused = true
        }
        .onDisappear { controller.isOpen = false }
        .onChange(of: editor.modelRevision) { controller.schedule(editor) }
        .onChange(of: editor.command == nil) { controller.schedule(editor) }
        .onChange(of: editor.doc.drawing) { controller.schedule(editor, delay: 0.01) }
    }

    // MARK: - Geometry

    private struct Transform {
        var origin: CGPoint   // top-left of the sheet in view coordinates
        var k: CGFloat        // points per paper mm
        var height: CGFloat   // sheet height in points

        func toPaper(_ p: CGPoint) -> Vec2 { Vec2(Double((p.x - origin.x) / k), Double((origin.y + height - p.y) / k)) }
        func toView(_ p: Vec2) -> CGPoint { CGPoint(x: origin.x + CGFloat(p.x) * k, y: origin.y + height - CGFloat(p.y) * k) }
    }

    private func transform(_ page: DrawingPage, _ size: CGSize) -> Transform {
        let fit = min((size.width - 48) / page.sheet.width, (size.height - 48) / page.sheet.height)
        let k = max(0.2, fit * zoom)
        let w = page.sheet.width * k, h = page.sheet.height * k
        return Transform(origin: CGPoint(x: (size.width - w) / 2 + pan.width, y: (size.height - h) / 2 + pan.height), k: k, height: h)
    }

    // MARK: - Hit testing (paper mm)

    private func distance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let d = b - a
        let t = max(0, min(1, simd_dot(p - a, d) / max(simd_length_squared(d), 1e-12)))
        return simd_distance(p, a + t * d)
    }

    private func hitDimension(_ page: DrawingPage, _ p: Vec2, tolerance: Double) -> PlacedDimension? {
        page.dimensions.compactMap { d -> (PlacedDimension, Double)? in
            let dSeg = d.segments.map { distance(p, $0.0, $0.1) }.min() ?? .infinity
            let dText = max(0, simd_distance(p, d.textCenter) - Double(d.text.count) * 1.1)
            let best = min(dSeg, dText)
            return best < tolerance ? (d, best) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private func hitView(_ page: DrawingPage, _ p: Vec2) -> PlacedView? {
        page.views.first { p.x >= $0.min.x - 2 && p.x <= $0.max.x + 2 && p.y >= $0.min.y - 2 && p.y <= $0.max.y + 2 }
    }

    private func nearestSnap(_ page: DrawingPage, _ p: Vec2, tolerance: Double, view: String? = nil) -> DrawingSnapPoint? {
        page.snapPoints.filter { view == nil || $0.view == view }
            .min { simd_distance($0.paper, p) < simd_distance($1.paper, p) }
            .flatMap { simd_distance($0.paper, p) < tolerance ? $0 : nil }
    }

    /// Orientation and offset of a user dimension from the placement point (same rule as in sketches).
    private func customDimension(_ a: DrawingSnapPoint, _ b: DrawingSnapPoint, placement c: Vec2) -> CustomDimension {
        let lo = simd_min(a.paper, b.paper), hi = simd_max(a.paper, b.paper)
        let outsideY = c.y > hi.y + 1 || c.y < lo.y - 1
        let outsideX = c.x > hi.x + 1 || c.x < lo.x - 1
        if outsideY && !outsideX {
            return CustomDimension(view: a.view, a: a.model, b: b.model, orientation: .horizontal, offset: c.y - a.paper.y)
        } else if outsideX && !outsideY {
            return CustomDimension(view: a.view, a: a.model, b: b.model, orientation: .vertical, offset: c.x - a.paper.x)
        }
        let d = b.paper - a.paper
        let u = simd_length(d) > 1e-9 ? simd_normalize(d) : Vec2(1, 0)
        return CustomDimension(view: a.view, a: a.model, b: b.model, orientation: .aligned, offset: simd_dot(c - a.paper, Vec2(-u.y, u.x)))
    }

    // MARK: - Sheet

    private func sheetCanvas(_ page: DrawingPage) -> some View {
        GeometryReader { geo in
            let t = transform(page, geo.size)
            let shown = previewPage(page) ?? page
            Canvas { ctx, _ in
                let rect = CGRect(x: t.origin.x, y: t.origin.y, width: page.sheet.width * t.k, height: t.height)
                var shadow = ctx
                shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 10, y: 4))
                shadow.fill(Path(rect), with: .color(.white))
                var highlight: [String: CGColor] = [:]
                if let hover { highlight[hover] = NSColor.systemBlue.withAlphaComponent(0.65).cgColor }
                if let selected { highlight[selected] = NSColor.systemBlue.cgColor }
                ctx.withCGContext { cg in
                    cg.translateBy(x: t.origin.x, y: t.origin.y + t.height)
                    cg.scaleBy(x: 1, y: -1)
                    DrawingRenderer.draw(shown, in: cg, pointsPerMM: t.k, highlight: highlight)
                }
                drawOverlays(ctx, page, t)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(p): updateHover(page, t, p)
                case .ended: hover = nil; hoverView = nil; mouse = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in dragChanged(page, t, v) }
                    .onEnded { _ in dragEnded() }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in zoom = max(0.3, min(12, zoomStart * v.magnification)) }
                    .onEnded { _ in zoomStart = zoom }
            )
            .onTapGesture(count: 2) { if tool == .select { resetView() } }
            .onTapGesture { p in click(page, t, p) }
        }
    }

    /// While placing a user dimension, show it live.
    private func previewPage(_ page: DrawingPage) -> DrawingPage? {
        guard tool == .addDimension, picks.count == 2, let m = mouse else { return nil }
        return controller.preview(customDimension(picks[0], picks[1], placement: m), page: min(pageIndex, max(controller.pages.count - 1, 0)))
    }

    private func drawOverlays(_ ctx: GraphicsContext, _ page: DrawingPage, _ t: Transform) {
        // Hovered view: dashed frame with its name.
        if tool == .select, hover == nil, let id = hoverView, let v = page.views.first(where: { $0.id == id }) {
            let a = t.toView(v.min - Vec2(3, 3)), b = t.toView(v.max + Vec2(3, 3))
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            let label = ctx.resolve(Text(v.title).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor))
            ctx.draw(label, at: CGPoint(x: r.minX + 4, y: r.minY - 8), anchor: .leading)
        }
        guard tool == .addDimension else { return }
        // Snap markers of the view under the cursor, the nearest one emphasised.
        let viewId = picks.first?.view ?? hoverView
        let nearest = mouse.flatMap { nearestSnap(page, $0, tolerance: 10 / Double(t.k), view: picks.first?.view) }
        for sp in page.snapPoints where sp.view == viewId {
            let c = t.toView(sp.paper)
            let isNear = nearest.map { simd_distance($0.paper, sp.paper) < 1e-9 } ?? false
            let r: CGFloat = isNear ? 5 : 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(isNear ? .accentColor : .accentColor.opacity(0.45)))
        }
        for sp in picks {
            let c = t.toView(sp.paper)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.accentColor), lineWidth: 2)
        }
        if picks.count == 1, let m = mouse {
            var p = Path()
            p.move(to: t.toView(picks[0].paper))
            p.addLine(to: t.toView(nearest?.paper ?? m))
            ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: - Mouse

    private func updateHover(_ page: DrawingPage, _ t: Transform, _ p: CGPoint) {
        let pp = t.toPaper(p)
        mouse = pp
        if tool == .select {
            hover = hitDimension(page, pp, tolerance: 6 / Double(t.k))?.id
        } else {
            hover = nil
        }
        hoverView = hitView(page, pp)?.id
    }

    private func click(_ page: DrawingPage, _ t: Transform, _ p: CGPoint) {
        focused = true
        let pp = t.toPaper(p)
        switch tool {
        case .select:
            selected = hitDimension(page, pp, tolerance: 6 / Double(t.k))?.id
        case .addDimension:
            if picks.count < 2 {
                guard let sp = nearestSnap(page, pp, tolerance: 10 / Double(t.k), view: picks.first?.view) else { return }
                if let first = picks.first, simd_distance(first.paper, sp.paper) < 1e-6 { return }
                picks.append(sp)
            } else {
                let c = customDimension(picks[0], picks[1], placement: pp)
                editor.updateDrawingSettings { $0.customDimensions.append(c) }
                selected = c.key
                picks.removeAll()
            }
        }
    }

    private func dragChanged(_ page: DrawingPage, _ t: Transform, _ v: DragGesture.Value) {
        let start = t.toPaper(v.startLocation), now = t.toPaper(v.location)
        if drag == nil {
            dragSnapshot = editor.doc
            if tool == .select, let d = hitDimension(page, start, tolerance: 6 / Double(t.k)) {
                selected = d.id
                if d.isCustom, let c = editor.drawingSettings.customDimensions.first(where: { $0.key == d.id }) {
                    drag = .custom(id: c.id, start: start, offset: c.offset, normal: d.normal)
                } else {
                    drag = .dimension(id: d.id, start: start, offset: editor.drawingSettings.dimensionOffsets[d.id] ?? DimensionOffset(),
                                      normal: d.normal, along: d.along)
                }
            } else if tool == .select, let view = hitView(page, start) {
                drag = .view(id: view.id, start: start, offset: editor.drawingSettings.viewOffsets[view.id] ?? .zero, constraint: view.constraint)
            } else {
                drag = .pan(start: pan)
            }
        }
        let delta = now - start
        switch drag {
        case let .pan(s):
            pan = CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height)
        case let .dimension(id, _, offset, normal, along):
            let isLeader = id.contains(".hole.") || id.hasPrefix("balloon.")
            editor.setDrawingSettingsLive { s in
                var o = offset
                if isLeader {
                    o.along += delta.x
                    o.distance += delta.y
                } else {
                    o.distance += simd_dot(delta, normal)
                    o.along += simd_dot(delta, along)
                }
                s.dimensionOffsets[id] = o
            }
        case let .custom(id, _, offset, normal):
            editor.setDrawingSettingsLive { s in
                if let i = s.customDimensions.firstIndex(where: { $0.id == id }) {
                    // The stored offset grows along the dimension's own normal regardless of its sign.
                    let sgn: Double = offset >= 0 ? 1 : -1
                    s.customDimensions[i].offset = offset + simd_dot(delta, normal) * sgn
                }
            }
        case let .view(id, _, offset, constraint):
            var d = delta
            if constraint == .horizontal { d.y = 0 }
            if constraint == .vertical { d.x = 0 }
            editor.setDrawingSettingsLive { $0.viewOffsets[id] = offset + d }
        case nil:
            break
        }
    }

    private func dragEnded() {
        if let snap = dragSnapshot { editor.finishDrawingEdit(from: snap) }
        drag = nil
        dragSnapshot = nil
    }

    // MARK: - Commands

    private func setTool(_ t: Tool) {
        tool = t
        picks.removeAll()
        if t == .addDimension { selected = nil }
    }

    private func cancel() {
        if !picks.isEmpty { picks.removeAll() } else if tool != .select { tool = .select } else { selected = nil }
    }

    private func deleteSelection() {
        guard let id = selected else { return }
        editor.updateDrawingSettings { s in
            if id.hasPrefix("custom.") {
                s.customDimensions.removeAll { $0.key == id }
            } else {
                s.hiddenDimensions.insert(id)
                s.dimensionOffsets[id] = nil
            }
        }
        selected = nil
        hover = nil
    }

    private func resetSelected() {
        guard let id = selected else { return }
        editor.updateDrawingSettings { $0.dimensionOffsets[id] = nil }
    }

    private func resetView() {
        withAnimation(.snappy) {
            zoom = 1; zoomStart = 1
            pan = .zero
        }
    }

    // MARK: - Chrome

    /// Sheet tabs ("Gesamtansicht", "Einzelteile 1", …), shown when there is more than one sheet.
    @ViewBuilder
    private var sheetTabs: some View {
        let pages = controller.pages
        if pages.count > 1 {
            HStack(spacing: 2) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    let active = i == min(pageIndex, pages.count - 1)
                    Button {
                        pageIndex = i
                        selected = nil
                        picks.removeAll()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: i == 0 ? "square.3.layers.3d" : "square.grid.2x2")
                            Text(p.name)
                        }
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(active ? Color.accentColor : .clear))
                        .foregroundStyle(active ? Color.white : .primary)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Blatt \(i + 1)")
                }
            }
            .padding(3)
            .floatingPanel(radius: 16)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let id = selected, let d = currentPage?.dimensions.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                Image(systemName: d.isCustom ? "ruler.fill" : "ruler").foregroundStyle(Color.accentColor)
                Text(d.isCustom ? "Eigenes Maß \(d.text)" : "Maß \(d.text)").font(.system(size: 12, weight: .medium))
                Divider().frame(height: 16)
                if !d.isCustom, editor.drawingSettings.dimensionOffsets[id] != nil {
                    Button("Position zurücksetzen", action: resetSelected)
                }
                Button(d.isCustom ? "Löschen" : "Ausblenden", role: .destructive, action: deleteSelection)
                    .help("⌫")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .floatingPanel(radius: 16)
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

    private var hint: String {
        switch tool {
        case .select:
            return "Maß oder Ansicht ziehen · ⌫ blendet aus · D neues Maß"
        case .addDimension:
            switch picks.count {
            case 0: return "Ersten Punkt wählen (Ecke oder Bohrungsmitte)"
            case 1: return "Zweiten Punkt wählen"
            default: return "Maßlinie platzieren · Esc bricht ab"
            }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if controller.isUpdating {
                ProgressView().controlSize(.small)
                Text("Aktualisiere …")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Synchron")
            }
            if let page = currentPage, !page.isEmpty {
                Text("· \(page.sheet.name) quer · \(page.scaleText ?? page.scale.label)").foregroundStyle(.secondary)
            }
            Text("· " + hint).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .floatingPanel(radius: 13)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Werkzeug", selection: Binding(get: { tool }, set: { setTool($0) })) {
                Label("Auswählen", systemImage: "cursorarrow").tag(Tool.select)
                Label("Maß hinzufügen", systemImage: "ruler").tag(Tool.addDimension)
            }
            .pickerStyle(.segmented)
            .help("Auswählen (V) · Maß hinzufügen (D)")
        }
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
                .help("Automatische Bemaßung anzeigen")
            Toggle(isOn: settingBinding(\.showHidden)) { Label("Verdeckte Kanten", systemImage: "square.dashed") }
                .help("Verdeckte Kanten anzeigen")
            Toggle(isOn: settingBinding(\.showIso)) { Label("Isometrie", systemImage: "cube") }
                .help("Isometrische Ansicht anzeigen")
            sheetsMenu
            resetMenu
            Button { showTitleBlock = true } label: { Label("Schriftfeld", systemImage: "list.bullet.rectangle") }
                .help("Schriftfeld ausfüllen")
                .popover(isPresented: $showTitleBlock) { TitleBlockEditor(editor: editor) }
            Button { editor.printDrawing() } label: { Label("Drucken", systemImage: "printer") }
                .help("Drucken (⌘P)")
                .keyboardShortcut("p")
            Menu {
                Button("PDF (alle Blätter, maßstabsgetreu) …") { editor.exportDrawingPDF() }
                Button("DXF – aktuelles Blatt …") { editor.exportDrawingDXF(sheet: pageIndex) }
                Button("DXF – Einzelteile 1:1 für CNC/Laser …") { editor.exportPartsDXF() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Als PDF oder DXF exportieren")
        }
    }

    /// Content for several bodies: balloons, parts list, part sheets.
    private var sheetsMenu: some View {
        Menu {
            Toggle("Positionsnummern", isOn: settingBinding(\.showBalloons))
            Toggle("Stückliste / Zuschnittliste", isOn: settingBinding(\.showPartsList))
            Toggle("Einzelteilzeichnungen", isOn: settingBinding(\.showPartSheets))
        } label: {
            Label("Blätter", systemImage: "doc.on.doc")
        }
        .help("Positionsnummern, Stückliste und Einzelteilzeichnungen (bei mehreren Körpern)")
    }

    private var resetMenu: some View {
        let s = editor.drawingSettings
        return Menu {
            Button("Ausgeblendete Maße einblenden (\(s.hiddenDimensions.count))") {
                editor.updateDrawingSettings { $0.hiddenDimensions.removeAll() }
            }
            .disabled(s.hiddenDimensions.isEmpty)
            Button("Maßpositionen zurücksetzen") { editor.updateDrawingSettings { $0.dimensionOffsets.removeAll() } }
                .disabled(s.dimensionOffsets.isEmpty)
            Button("Ansichten zurücksetzen") { editor.updateDrawingSettings { $0.viewOffsets.removeAll() } }
                .disabled(s.viewOffsets.isEmpty)
            Button("Eigene Maße löschen (\(s.customDimensions.count))") { editor.updateDrawingSettings { $0.customDimensions.removeAll() } }
                .disabled(s.customDimensions.isEmpty)
            Divider()
            Button("Alle Anpassungen zurücksetzen") {
                editor.updateDrawingSettings {
                    $0.hiddenDimensions.removeAll()
                    $0.dimensionOffsets.removeAll()
                    $0.viewOffsets.removeAll()
                    $0.customDimensions.removeAll()
                }
            }
            .disabled(!s.hasManualEdits)
        } label: {
            Label("Zurücksetzen", systemImage: "arrow.counterclockwise")
        }
        .help("Manuelle Anpassungen zurücksetzen")
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
