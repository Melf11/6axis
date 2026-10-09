import AppKit
import Foundation
import Observation
import simd
import SixAxisCore

/// Something under the cursor that can be hovered or selected.
enum Pick: Hashable {
    case face(UUID, Int)
    case edge(UUID, Int)
    case profile(UUID, Int)          // sketch feature, region index
    case sketchPoint(UUID, Int)
    case sketchCurve(UUID, Int)
    case constraint(UUID, Int)
    case originPlane(PlaneRef)
    case originAxis(AxisRef)
    case body(UUID)

    /// Lower wins when several candidates are under the cursor.
    var priority: Int {
        switch self {
        case .sketchPoint, .constraint: return 0
        case .sketchCurve, .edge, .originAxis: return 1
        case .profile, .face, .originPlane, .body: return 2
        }
    }

    var bodyId: UUID? {
        switch self {
        case let .face(b, _), let .edge(b, _), let .body(b): return b
        default: return nil
        }
    }
}

enum SketchTool: Equatable {
    case select
    case line
    case rectangle
    case centerRectangle
    case circle
    case arc
    case spline
    case dimension
    case constraint(ConstraintTool)

    var name: String {
        switch self {
        case .select: return String(localized: "Auswählen")
        case .line: return String(localized: "Linie")
        case .rectangle: return String(localized: "Rechteck")
        case .centerRectangle: return String(localized: "Mittelpunkt-Rechteck")
        case .circle: return String(localized: "Kreis")
        case .arc: return String(localized: "Bogen")
        case .spline: return String(localized: "Spline")
        case .dimension: return String(localized: "Bemaßung")
        case let .constraint(c): return c.name
        }
    }
}

enum ConstraintTool: String, CaseIterable, Identifiable {
    case horizontal, vertical, coincident, tangent, equal, parallel, perpendicular, concentric, midpoint, collinear, symmetric, fix

    var id: String { rawValue }

    var name: String {
        switch self {
        case .horizontal: return String(localized: "Horizontal")
        case .vertical: return String(localized: "Vertikal")
        case .coincident: return String(localized: "Deckungsgleich")
        case .tangent: return String(localized: "Tangential")
        case .equal: return String(localized: "Gleich")
        case .parallel: return String(localized: "Parallel")
        case .perpendicular: return String(localized: "Senkrecht")
        case .concentric: return String(localized: "Konzentrisch")
        case .midpoint: return String(localized: "Mittelpunkt")
        case .collinear: return String(localized: "Kollinear")
        case .symmetric: return String(localized: "Symmetrisch")
        case .fix: return String(localized: "Fixieren")
        }
    }

    var symbol: String {
        switch self {
        case .horizontal: return "arrow.left.and.right"
        case .vertical: return "arrow.up.and.down"
        case .coincident: return "smallcircle.filled.circle"
        case .tangent: return "circle.and.line.horizontal"
        case .equal: return "equal"
        case .parallel: return "pause"
        case .perpendicular: return "angle"
        case .concentric: return "circle.circle"
        case .midpoint: return "arrow.right.and.line.vertical.and.arrow.left"
        case .collinear: return "line.diagonal"
        case .symmetric: return "arrow.left.and.line.vertical.and.arrow.right"
        case .fix: return "lock"
        }
    }
}

enum CommandKind: String {
    case extrude, revolve, fillet, chamfer, shell, sketchPlane

    var title: String {
        switch self {
        case .extrude: return String(localized: "Extrusion")
        case .revolve: return String(localized: "Drehung")
        case .fillet: return String(localized: "Abrundung")
        case .chamfer: return String(localized: "Fase")
        case .shell: return String(localized: "Wandstärke")
        case .sketchPlane: return String(localized: "Skizze erstellen")
        }
    }
}

struct ActiveCommand {
    var kind: CommandKind
    var featureId: UUID?
    var isNew: Bool
    var snapshot: CADDocument
    /// Revolve: 0 = profile input, 1 = axis input.
    var activeInput = 0
    /// Sketch tool to activate after the sketch plane was chosen (e.g. pressing "L" in model mode).
    var pendingTool: SketchTool?
}

/// Where the cursor snaps to while sketching.
struct SnapTarget: Equatable {
    var position: Vec2
    var point: Int?
    var curve: Int?
    var onGrid = false
}

enum Inference: Equatable { case horizontal, vertical }

@Observable
final class Editor {
    // Document
    var doc = CADDocument()
    var fileURL: URL?
    var isDirty = false
    private(set) var state = ModelState()
    @ObservationIgnored let builder = ModelBuilder()
    /// True while a slow rebuild runs in the background (the UI shows "Berechne …").
    private(set) var isRebuilding = false
    @ObservationIgnored private let rebuildQueue = DispatchQueue(label: "app.6axis.rebuild", qos: .userInitiated)
    @ObservationIgnored private var rebuildGeneration = 0
    @ObservationIgnored private var appliedGeneration = 0
    @ObservationIgnored private let latestRequested = LatestGeneration()
    @ObservationIgnored private var undoStack: [CADDocument] = []
    @ObservationIgnored private var redoStack: [CADDocument] = []
    var canUndo = false
    var canRedo = false

    // View
    /// Camera changes on every navigation event – keep views and menus from depending on it as a whole.
    var camera = Camera() {
        didSet { if camera.orthographic != isOrthographic { isOrthographic = camera.orthographic } }
    }
    /// Mirrors `camera.orthographic`; changes only when the projection changes (menus observe this).
    private(set) var isOrthographic = false
    @ObservationIgnored var cameraAnimation: CameraAnimation?
    var showOriginPlanes = false
    var darkMode = false
    /// Increments whenever GPU scene data must be rebuilt.
    var sceneVersion = 0
    /// Increments whenever the model geometry may have changed (drives the drawing window).
    var modelRevision = 0
    @ObservationIgnored let drawing = DrawingController()
    @ObservationIgnored var openDrawingWindow: () -> Void = {}

    // Interaction
    var selection: [Pick] = []
    var hover: Pick?
    /// Hover coming from SwiftUI overlay elements (constraint glyphs, dimension labels).
    var overlayHover: Pick?
    var command: ActiveCommand?
    var sketchId: UUID?
    var sketchTool: SketchTool = .select
    var toolPoints: [SnapTarget] = []
    /// Typed values for the active drawing tool (e.g. width/height). Empty = follow the mouse.
    var toolInputs: [String] = ["", ""]
    /// Index of the focused tool input field, nil when the viewport has keyboard focus.
    var toolInputFocus: Int?
    var cursor: SnapTarget?
    var inference: Inference?
    var lastSolve: SolveResult?
    var editingDimension: Int?
    var dimensionFirst: Pick?
    var dimensionSecond: Pick?
    @ObservationIgnored var chainStart: Int?
    @ObservationIgnored var sketchRollbackBefore: Int?
    var constraintPicks: [Pick] = []
    var timelineSelection: UUID?

    // Chrome
    var toast: String?
    @ObservationIgnored private var toastToken = 0
    var showCommandPalette = false
    var showParameters = false
    var markingMenu: CGPoint?
    /// Pointer position while the marking menu is open (drives the direction guide).
    var markingMenuPointer: CGPoint?
    var browserVisible = true

    // Viewport hooks (set by the Metal view)
    @ObservationIgnored var requestRedraw: () -> Void = {}
    @ObservationIgnored var snapshotProvider: () -> NSImage? = { nil }
    @ObservationIgnored var focusViewport: () -> Void = {}
    @ObservationIgnored var autosaveWork: DispatchWorkItem?
    /// Set when the user chose "Nicht sichern" (so quitting does not keep the unsaved state).
    @ObservationIgnored var discardedChanges = false
    @ObservationIgnored var pickProvider: (CGPoint, CGFloat) -> [UInt32] = { _, _ in [] }
    @ObservationIgnored var pickTable: [Pick] = []
    @ObservationIgnored var pickIds: [Pick: UInt32] = [:]
    @ObservationIgnored var dragState: DragState?
    @ObservationIgnored var lastMouse: CGPoint = .zero
    /// Sketch-plane point the rendered grid is centered on (to recenter after long pans).
    @ObservationIgnored var gridCenter: Vec2 = .zero
    /// Increments when only the grid/axes layer must follow the camera (cheap; no body re-upload).
    @ObservationIgnored var gridVersion = 0

    struct DragState {
        var start: CGPoint
        var snapshot: CADDocument
        var pick: Pick?
        var startSketchPos: Vec2?
        var original: Sketch?
        var moved = false
    }

    init() {
        camera.orthographic = AppSettings.shared.defaultOrthographic
        rebuild()
        restoreSession()
    }

    // MARK: - Document & undo

    var evaluator: Evaluator { Evaluator(parameters: doc.parameters) }

    /// Rebuilds the model on a background queue. Results that arrive within a short budget are applied
    /// immediately (small models behave synchronously, e.g. live previews while dragging); slower
    /// rebuilds keep the UI responsive and are applied when done. Superseded rebuilds are skipped.
    func rebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let snapshot = doc
        let builder = self.builder
        let latest = latestRequested
        latest.set(generation)
        let result = RebuildResult()
        rebuildQueue.async {
            if latest.get() == generation {
                let state = builder.build(snapshot)
                state.prepareForDisplay()
                result.state = state
            }
            result.done.signal()
            DispatchQueue.main.async { [weak self] in
                guard let self, let state = result.state else { return }
                self.apply(state, generation: generation)
            }
        }
        if result.done.wait(timeout: .now() + .milliseconds(80)) == .success, let state = result.state {
            apply(state, generation: generation)
        } else {
            isRebuilding = true
        }
    }

    private func apply(_ newState: ModelState, generation: Int) {
        // Only the newest request counts; each generation is applied once.
        guard generation == rebuildGeneration, generation != appliedGeneration else { return }
        appliedGeneration = generation
        isRebuilding = false
        state = newState
        assignBodyNames()
        sceneVersion &+= 1
        modelRevision &+= 1
        requestRedraw()
        scheduleAutosave()
    }

    private func assignBodyNames() {
        var n = doc.bodies.count
        for id in state.bodyOrder where doc.bodies[id] == nil {
            n += 1
            doc.bodies[id] = BodyMeta(name: String(localized: "Körper\(n)"))
        }
    }

    /// Applies a change as one undoable step.
    func commit(_ change: (inout CADDocument) -> Void) {
        let before = doc
        change(&doc)
        guard doc != before else { return }
        pushUndo(before)
        rebuild()
    }

    func pushUndo(_ snapshot: CADDocument) {
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
        discardedChanges = false
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        if command != nil { cancelCommand(); return }
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = prev
        afterHistoryJump()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = next
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        isDirty = true
        updateUndoFlags()
        if let sid = sketchId, doc.feature(sid) == nil { sketchId = nil }
        selection.removeAll()
        toolPoints.removeAll()
        rebuild()
        if sketchId != nil { solveActiveSketch(store: false) }
    }

    func newDocument() {
        guard confirmDiscard() else { return }
        doc = CADDocument()
        fileURL = nil
        camera.orthographic = AppSettings.shared.defaultOrthographic
        resetSession()
    }

    /// Opens a bundled example as an unsaved copy (Sichern asks for a location).
    func openExample(_ example: Examples.Example) {
        guard confirmDiscard() else { return }
        doc = example.document
        fileURL = nil
        resetSession()
        homeView()
        showToast(String(localized: "Beispiel „\(example.title)“ geöffnet – Parameter unter Ändern → Parameter"))
    }

    private func resetSession() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoFlags()
        isDirty = false
        command = nil
        sketchId = nil
        selection.removeAll()
        hover = nil
        toolPoints.removeAll()
        rebuild()
        fitAll(animated: false)
    }

    func confirmDiscard() -> Bool {
        // Automated runs must never wait for a click on a modal dialog.
        if Self.isAutomatedRun && ProcessInfo.processInfo.environment["SIXAXIS_SESSION_TEST"] == nil { return true }
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Änderungen sichern?")
        alert.informativeText = String(localized: "Das aktuelle Design hat ungesicherte Änderungen.")
        alert.addButton(withTitle: String(localized: "Sichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        alert.addButton(withTitle: String(localized: "Nicht sichern"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn:
            discardedChanges = true
            return true
        default: return false
        }
    }

    // MARK: - Files

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.sixAxisDocument, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            doc = try CADDocument.decode(data)
            fileURL = url
            resetSession()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showToast(String(localized: "Datei konnte nicht geöffnet werden: \(error.localizedDescription)"))
        }
    }

    @discardableResult
    func save() -> Bool {
        if command != nil { commitCommand() }
        guard let url = fileURL else { return saveAs() }
        do {
            try doc.encoded().write(to: url, options: .atomic)
            isDirty = false
            discardedChanges = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            autosaveNow()
            return true
        } catch {
            showToast(String(localized: "Sichern fehlgeschlagen: \(error.localizedDescription)"))
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.sixAxisDocument]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Design.6axis"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        fileURL = url
        return save()
    }

    var documentTitle: String {
        (fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Unbenannt")) + (isDirty ? String(localized: " — bearbeitet") : "")
    }

    // MARK: - Toasts

    func showToast(_ text: String) {
        toast = text
        toastToken += 1
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toastToken == token { self?.toast = nil }
        }
    }

    // MARK: - Camera

    func animateCamera(to target: Camera) {
        cameraAnimation = CameraAnimation(from: camera, to: target, start: CACurrentMediaTime())
        requestRedraw()
    }

    /// Advances a running animation; returns true while animating.
    func stepAnimation() -> Bool {
        guard let anim = cameraAnimation else { return false }
        let (cam, done) = anim.camera(at: CACurrentMediaTime())
        var c = cam
        c.viewSize = camera.viewSize
        c.orthographic = camera.orthographic
        camera = c
        if done { cameraAnimation = nil }
        return !done
    }

    func modelBounds() -> (SIMD3<Float>, SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        var any = false
        for b in state.orderedBodies where doc.isBodyVisible(b.id) {
            if let bb = b.shape.boundingBox {
                lo = simd_min(lo, bb.min.float)
                hi = simd_max(hi, bb.max.float)
                any = true
            }
        }
        for (id, sb) in state.sketches where !doc.hiddenSketches.contains(id) || id == sketchId {
            for p in sb.sketch.points {
                let w = sb.plane.point(p.position).float
                lo = simd_min(lo, w)
                hi = simd_max(hi, w)
                any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    func fitAll(animated: Bool = true) {
        var c = camera
        if let (lo, hi) = modelBounds(), simd_length(hi - lo) > 1e-3 {
            c.fit(min: lo, max: hi)
        } else {
            c.target = .zero
            c.distance = 220
        }
        if animated { animateCamera(to: c) } else { camera = c; requestRedraw() }
    }

    func setView(direction: SIMD3<Float>, up: SIMD3<Float>) {
        var c = camera
        c.orientation = Camera.lookOrientation(direction: direction, up: up)
        animateCamera(to: c)
    }

    func homeView() {
        var c = camera
        c.orientation = Camera.homeOrientation
        if let (lo, hi) = modelBounds(), simd_length(hi - lo) > 1e-3 { c.fit(min: lo, max: hi) }
        animateCamera(to: c)
    }

    func toggleProjection() {
        camera.orthographic.toggle()
        requestRedraw()
    }

    // MARK: - Body & sketch visibility

    func toggleBodyVisibility(_ id: UUID) {
        commit { $0.bodies[id, default: BodyMeta(name: String(localized: "Körper"))].visible.toggle() }
    }

    func renameBody(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        commit { $0.bodies[id, default: BodyMeta(name: trimmed)].name = trimmed }
    }

    func toggleSketchVisibility(_ id: UUID) {
        commit { d in
            if d.hiddenSketches.contains(id) { d.hiddenSketches.remove(id) } else { d.hiddenSketches.insert(id) }
        }
    }

    // MARK: - Timeline

    func moveMarker(to count: Int) {
        guard command == nil, sketchId == nil else { return }
        let c = max(0, min(doc.features.count, count))
        commit { $0.rollback = c == $0.features.count ? nil : c }
    }

    func deleteFeature(_ id: UUID) {
        if sketchId == id { finishSketch() }
        commit { d in
            guard let i = d.index(of: id) else { return }
            d.features.remove(at: i)
            if let r = d.rollback, i < r { d.rollback = r - 1 }
        }
        selection.removeAll()
    }

    func toggleSuppressed(_ id: UUID) {
        commit { $0.update(id) { $0.suppressed.toggle() } }
    }

    func renameFeature(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        commit { $0.update(id) { $0.name = trimmed } }
    }

    func editFeature(_ id: UUID) {
        guard let f = doc.feature(id) else { return }
        if command != nil { commitCommand() }
        if sketchId != nil { finishSketch() }
        switch f.kind {
        case .sketch: editSketch(id)
        case .extrude: beginCommand(.extrude, editing: id)
        case .revolve: beginCommand(.revolve, editing: id)
        case .fillet: beginCommand(.fillet, editing: id)
        case .chamfer: beginCommand(.chamfer, editing: id)
        case .shell: beginCommand(.shell, editing: id)
        case .importStep: showToast(String(localized: "Importierte Körper haben keine Parameter"))
        }
    }

    // MARK: - Measurements

    /// Volume/mass summary for the selection (or all visible bodies) — handy for 3D printing.
    /// Volume, area and – when every body has a material with known density – the mass in grams
    /// and a material label (single material name, or "gemischt").
    var physicalSummary: (title: String, volume: Double, area: Double, mass: Double?, material: String?)? {
        let selectedBodies = Set(selection.compactMap(\.bodyId))
        let bodies = state.orderedBodies.filter {
            selectedBodies.isEmpty ? doc.isBodyVisible($0.id) : selectedBodies.contains($0.id)
        }
        guard !bodies.isEmpty else { return nil }
        let title = bodies.count == 1 ? doc.bodyName(bodies[0].id) : String(localized: "\(bodies.count) Körper")
        let materials = bodies.map { doc.bodies[$0.id]?.material ?? "" }
        let densities = materials.map { MaterialDensity.lookup($0) }
        var mass: Double?
        var label: String?
        if densities.allSatisfy({ $0 != nil }) {
            mass = zip(bodies, densities).reduce(0) { $0 + $1.0.shape.volume / 1000 * $1.1! }
            label = Set(materials).count == 1 ? materials[0] : "gemischt"
        }
        return (title, bodies.reduce(0) { $0 + $1.shape.volume }, bodies.reduce(0) { $0 + $1.shape.area }, mass, label)
    }
}

import UniformTypeIdentifiers

extension UTType {
    static let sixAxisDocument = UTType(filenameExtension: "6axis", conformingTo: .json) ?? .json
}

/// Hand-over box between the rebuild queue and the main thread (the semaphore orders the accesses).
private final class RebuildResult: @unchecked Sendable {
    var state: ModelState?
    let done = DispatchSemaphore(value: 0)
}

/// Newest requested rebuild, read by the queue to skip superseded work.
private final class LatestGeneration: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
