import AppKit
import Foundation
import simd
import SixAxisCore

/// Autosave and session restore: the current design (including unsaved changes), its file name
/// and the camera survive quitting, crashes and rebuilds. Stored in ~/Library/Application Support/6axis.
extension Editor {
    struct SessionInfo: Codable {
        var filePath: String?
        var isDirty: Bool
        var camera: CameraInfo?
    }

    struct CameraInfo: Codable {
        var target: [Float]
        var distance: Float
        var orientation: [Float]
        var orthographic: Bool
    }

    /// Automated runs (any SIXAXIS_* variable: demos, session test, CI) use a separate folder so they
    /// never overwrite the user's autosave and session.
    static var isAutomatedRun: Bool { ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("SIXAXIS_") } }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(isAutomatedRun ? "6axis-test" : "6axis", isDirectory: true)
    }

    private static var autosaveURL: URL { supportDirectory.appendingPathComponent("Autosave.6axis") }
    private static var sessionURL: URL { supportDirectory.appendingPathComponent("Session.json") }

    /// Demo/CI runs must never touch the user's session.
    static var sessionEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["SIXAXIS_DEMO"] == nil && env["SIXAXIS_EXAMPLES_DEMO"] == nil
    }

    /// Debounced: saves one second after the last change.
    func scheduleAutosave() {
        guard Self.sessionEnabled else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosaveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The document as it should be persisted: without uncommitted command previews or temporary rollbacks.
    private var persistableDocument: CADDocument {
        if let cmd = command { return cmd.snapshot }
        var d = doc
        if sketchId != nil { d.rollback = sketchRollbackBefore }
        return d
    }

    func autosaveNow() {
        guard Self.sessionEnabled else { return }
        autosaveWork?.cancel()
        autosaveWork = nil
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try persistableDocument.encoded().write(to: Self.autosaveURL, options: .atomic)
            try writeSession(isDirty: isDirty)
        } catch {
            NSLog("6axis: autosave failed: \(error)")
        }
    }

    private func writeSession(isDirty: Bool) throws {
        let o = camera.orientation.vector
        let info = SessionInfo(
            filePath: fileURL?.path,
            isDirty: isDirty,
            camera: CameraInfo(target: [camera.target.x, camera.target.y, camera.target.z], distance: camera.distance,
                               orientation: [o.x, o.y, o.z, o.w], orthographic: camera.orthographic))
        try JSONEncoder().encode(info).write(to: Self.sessionURL, options: .atomic)
    }

    /// Called on quit. If the user explicitly chose "Nicht sichern", unsaved work is dropped
    /// and the next launch reopens the file as it is on disk.
    func finishSession(discardChanges: Bool) {
        guard Self.sessionEnabled else { return }
        if discardChanges {
            try? FileManager.default.removeItem(at: Self.autosaveURL)
            try? writeSession(isDirty: false)
        } else {
            autosaveNow()
        }
    }

    /// Restores the last session. Returns true if something was restored.
    @discardableResult
    func restoreSession() -> Bool {
        guard Self.sessionEnabled,
              let data = try? Data(contentsOf: Self.sessionURL),
              let info = try? JSONDecoder().decode(SessionInfo.self, from: data) else { return false }
        let fileURL = info.filePath.map { URL(fileURLWithPath: $0) }
        let fileExists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        if let autosave = try? Data(contentsOf: Self.autosaveURL), let restored = try? CADDocument.decode(autosave) {
            doc = restored
            self.fileURL = fileExists ? fileURL : nil
            rebuild()
            isDirty = info.isDirty || (fileURL != nil && !fileExists)
        } else if let fileURL, fileExists {
            open(url: fileURL)
        } else {
            return false
        }

        if let c = info.camera, c.target.count == 3, c.orientation.count == 4 {
            camera.target = SIMD3(c.target[0], c.target[1], c.target[2])
            camera.distance = c.distance
            camera.orientation = simd_quatf(vector: SIMD4(c.orientation[0], c.orientation[1], c.orientation[2], c.orientation[3]))
            camera.orthographic = c.orthographic
        }
        return true
    }
}
