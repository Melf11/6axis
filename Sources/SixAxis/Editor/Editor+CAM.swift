import AppKit
import Foundation
import UniformTypeIdentifiers
import simd
import SixAxisCore

enum Workspace: String { case design, cam }

/// Milling (2.0): setup, operations, toolpath preview and G-code (see docs/cam.md).
extension Editor {
    var cam: CAMSetup { doc.cam ?? CAMSetup() }

    func setWorkspace(_ w: Workspace) {
        if command != nil { commitCommand() }
        if sketchId != nil { finishSketch() }
        if measuring { endMeasure() }
        camEdit = nil
        workspace = w
        if w == .cam && doc.cam == nil { doc.cam = CAMSetup() }
        if w == .cam { scheduleCAMPlan() }
        sceneVersion &+= 1
        requestRedraw()
    }

    /// Undoable change of the machining setup.
    func updateCAM(_ change: (inout CAMSetup) -> Void) {
        commit { d in
            var c = d.cam ?? CAMSetup()
            change(&c)
            d.cam = c
        }
        scheduleCAMPlan()
    }

    // MARK: Operations

    func addOperation(_ kind: CAMOperationKind) {
        var op = CAMOperation(name: nextOperationName(kind), kind: kind)
        let tools = cam.tools
        // Sensible default tool: Ø6 end mill for contours and pockets, a drill matching the first hole for drilling.
        op.tool = kind == .drill ? (tools.first { $0.kind == .drill } ?? tools.first)?.id
                                 : (tools.first { $0.kind == .flat && abs($0.diameter - 6) < 0.01 } ?? tools.first)?.id
        op.faces = selection.compactMap { p in
            guard case let .face(b, i) = p, let ref = state.bodies[b]?.faceRef(i) else { return nil }
            return BodyFaceRef(body: b, face: ref)
        }
        let id = op.id
        updateCAM { $0.operations.append(op) }
        selection.removeAll()
        editOperation(id)
    }

    private func nextOperationName(_ kind: CAMOperationKind) -> String {
        let names = Set(cam.operations.map(\.name))
        var n = 1
        while names.contains("\(kind.displayName)\(n)") { n += 1 }
        return "\(kind.displayName)\(n)"
    }

    func editOperation(_ id: UUID?) {
        camEdit = id
        sceneVersion &+= 1
        requestRedraw()
    }

    var editedOperation: CAMOperation? { camEdit.flatMap { id in cam.operations.first { $0.id == id } } }

    func updateOperation(_ id: UUID, _ change: @escaping (inout CAMOperation) -> Void) {
        updateCAM { c in if let i = c.operations.firstIndex(where: { $0.id == id }) { change(&c.operations[i]) } }
    }

    func deleteOperation(_ id: UUID) {
        if camEdit == id { camEdit = nil }
        updateCAM { $0.operations.removeAll { $0.id == id } }
    }

    func moveOperation(_ id: UUID, by delta: Int) {
        updateCAM { c in
            guard let i = c.operations.firstIndex(where: { $0.id == id }) else { return }
            let j = max(0, min(c.operations.count - 1, i + delta))
            c.operations.swapAt(i, j)
        }
    }

    /// Faces the edited operation accepts: horizontal planar faces facing up, or holes for drilling.
    func acceptsCAMPick(_ p: Pick) -> Bool {
        guard let op = editedOperation, case let .face(b, i) = p, let info = state.bodies[b]?.faceInfo(at: i) else { return false }
        if op.kind == .drill && info.surface == .cylinder { return abs(info.axisDir.z) > 0.999 }
        return info.isPlanar && info.normal.z > 0.999
    }

    func camClick(_ p: Pick) {
        guard let id = camEdit, case let .face(b, i) = p, let ref = state.bodies[b]?.faceRef(i) else { return }
        updateOperation(id) { op in
            if let j = op.faces.firstIndex(where: { $0.body == b && $0.face.index == i }) { op.faces.remove(at: j) }
            else { op.faces.append(BodyFaceRef(body: b, face: ref)) }
        }
    }

    // MARK: Toolpaths

    /// Recomputes the toolpaths in the background (debounced); the preview follows.
    func scheduleCAMPlan() {
        guard workspace == .cam, let setup = doc.cam else { return }
        camToken &+= 1
        let token = camToken
        let state = self.state
        let evaluator = self.evaluator
        let visible = state.bodyOrder.filter { doc.isBodyVisible($0) }
        camPlanning = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let result = CAMPlanner.plan(setup, state: state, evaluator: evaluator, bodies: visible)
            DispatchQueue.main.async {
                guard let self, token == self.camToken else { return }
                self.camResult = result
                self.camPlanning = false
                self.sceneVersion &+= 1
                self.requestRedraw()
            }
        }
    }

    /// Saves the G-code after showing the checks; the user confirms responsibility for the machine run.
    func exportGCode() {
        guard let setup = doc.cam else { return }
        let result = CAMPlanner.plan(setup, state: state, evaluator: evaluator, bodies: state.bodyOrder.filter { doc.isBodyVisible($0) })
        guard !result.paths.isEmpty else {
            showToast(result.warnings.first ?? String(localized: "Keine Fräsbahnen – erst Bearbeitungen anlegen"))
            return
        }
        if !Self.isAutomatedRun {
            let alert = NSAlert()
            alert.messageText = String(localized: "G-Code sichern?")
            var info = String(localized: "Laufzeit ca. \(Int((result.time() / 60).rounded(.up))) min. Nullpunkt: \(setup.origin.displayName).")
            if !result.warnings.isEmpty { info += "\n\n" + String(localized: "Hinweise:") + "\n• " + result.warnings.joined(separator: "\n• ") }
            info += "\n\n" + String(localized: "Prüfe Werkzeuge und Nullpunkt und fahre das Programm zuerst „in der Luft“ (Z hoch genullt). Für den Betrieb der Maschine bist du verantwortlich.")
            alert.informativeText = info
            alert.addButton(withTitle: String(localized: "Sichern …"))
            alert.addButton(withTitle: String(localized: "Abbrechen"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nc") ?? .plainText, UTType(filenameExtension: "gcode") ?? .plainText]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Design")) + ".nc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Unbenannt")
        do {
            try GCodeWriter.write(result, setup: setup, title: title).write(to: url, atomically: true, encoding: .ascii)
            showToast(String(localized: "G-Code gesichert: \(url.lastPathComponent)"))
        } catch {
            showToast(error.localizedDescription)
        }
    }
}
