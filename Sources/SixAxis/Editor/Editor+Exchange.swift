import AppKit
import Foundation
import UniformTypeIdentifiers
import SixAxisCore

extension Editor {
    /// Bodies to export: the selection if it contains bodies, otherwise all visible bodies.
    private func exportBodies() -> [BuiltBody]? {
        let selected = Set(selection.compactMap(\.bodyId))
        let bodies = state.orderedBodies.filter { selected.isEmpty ? doc.isBodyVisible($0.id) : selected.contains($0.id) }
        guard !bodies.isEmpty else {
            showToast(String(localized: "Es gibt keinen sichtbaren Körper zum Exportieren"))
            return nil
        }
        return bodies
    }

    private func exportShape() -> Shape? {
        guard let bodies = exportBodies() else { return nil }
        return bodies.count == 1 ? bodies[0].shape : Shape.compound(bodies.map { $0.shape })
    }

    /// 3MF: one named object per body, in millimetres – the better format for slicers.
    func export3MF() {
        guard let bodies = exportBodies() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "3mf") ?? .data]
        panel.nameFieldStringValue = exportBaseName + ".3mf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write3MF(bodies, to: url)
            showToast(String(localized: "3MF exportiert: \(url.lastPathComponent)"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func write3MF(_ bodies: [BuiltBody], to url: URL) throws {
        let parts = bodies.map { ThreeMF.Part(name: doc.bodyName($0.id), shape: $0.shape) }
        let compound = bodies.count == 1 ? bodies[0].shape : Shape.compound(bodies.map(\.shape))
        try ThreeMF.write(parts, to: url, linearDeflection: stlDeflection(compound))
    }

    private var exportBaseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Design")
    }

    func exportSTL() {
        guard let shape = exportShape() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        panel.nameFieldStringValue = exportBaseName + ".stl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try shape.writeSTL(to: url, linearDeflection: stlDeflection(shape))
            showToast(String(localized: "STL exportiert: \(url.lastPathComponent)"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func exportSTEP() {
        guard let shape = exportShape() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "step") ?? .data]
        panel.nameFieldStringValue = exportBaseName + ".step"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try shape.writeSTEP(to: url)
            showToast(String(localized: "STEP exportiert: \(url.lastPathComponent)"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    /// Fine tessellation for printing: ~0.01 mm on small parts, scaled for large ones.
    private func stlDeflection(_ shape: Shape) -> Double {
        guard let bb = shape.boundingBox else { return 0.01 }
        let base = max(0.005, min(0.05, simd_length(bb.max - bb.min) * 0.00005))
        return base * AppSettings.shared.stlQuality.factor
    }

    /// Exports a temporary 3MF (units and part names included) and opens it with the user's slicer
    /// (PrusaSlicer, Bambu Studio, OrcaSlicer, Cura …).
    func openInSlicer() {
        guard let bodies = exportBodies() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("6axis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(exportBaseName + ".3mf")
        do {
            try write3MF(bodies, to: url)
        } catch {
            showToast(error.localizedDescription)
            return
        }
        let known = ["com.prusa3d.slic3r", "com.bambulab.bambu-studio", "com.softfever3d.orca-slicer",
                     "nl.ultimaker.cura", "com.prusa3d.PrusaSlicer", "com.superslicer.SuperSlicer"]
        let ws = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        let preferred = AppSettings.shared.preferredSlicer
        let order = preferred.isEmpty ? known : [preferred] + known
        if let app = order.lazy.compactMap({ ws.urlForApplication(withBundleIdentifier: $0) }).first {
            ws.open([url], withApplicationAt: app, configuration: config)
            showToast(String(localized: "An Slicer übergeben"))
        } else if ws.urlForApplication(toOpen: url) != nil {
            ws.open(url)
        } else {
            showToast(String(localized: "Kein Slicer gefunden – die 3MF-Datei liegt im Finder bereit"))
            ws.activateFileViewerSelecting([url])
        }
    }

    func importSTEP() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["step", "stp"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try Shape.readSTEP(from: url)   // validate before adding to the timeline
            if command != nil { commitCommand() }
            if sketchId != nil { finishSketch() }
            let f = Feature(name: url.deletingPathExtension().lastPathComponent,
                            kind: .importStep(ImportFeature(fileName: url.lastPathComponent, stepText: text)))
            commit { d in
                d.features.insert(f, at: d.activeCount)
                if let r = d.rollback { d.rollback = r + 1 }
            }
            fitAll()
        } catch {
            showToast(String(localized: "Import fehlgeschlagen: \(error.localizedDescription)"))
        }
    }
}

import simd
