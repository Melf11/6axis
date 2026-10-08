import AppKit
import SwiftUI
import Foundation
import simd
import VibeCore

/// Scripted UI walkthrough for development and CI:
///   VIBE360_DEMO=1 VIBE360_SNAPSHOTS=/tmp/shots open build/Vibe360.app
/// Drives the editor through real mouse-event code paths and writes PNG snapshots.
@MainActor
enum DemoScript {
    static func runIfRequested(_ editor: Editor) {
        let env = ProcessInfo.processInfo.environment
        guard env["VIBE360_DEMO"] != nil else { return }
        let dir = URL(fileURLWithPath: env["VIBE360_SNAPSHOTS"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(editor, dir: dir, keepOpen: env["VIBE360_KEEP_OPEN"] != nil)
        }
    }

    static func pause(_ s: Double = 0.6) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    static func snap(_ editor: Editor, _ name: String, _ dir: URL) async {
        await pause(0.7)
        guard let img = editor.snapshotProvider(), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("DEMO: snapshot \(name) failed")
            return
        }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
        print("DEMO: wrote \(name)")
    }

    /// Clicks at a sketch-plane coordinate through the normal hover/mouse pipeline.
    static func clickSketch(_ editor: Editor, _ uv: Vec2, count: Int = 1) {
        guard let plane = editor.activePlane, let pt = editor.camera.project(plane.point(uv)) else { return }
        clickScreen(editor, pt, count: count)
    }

    static func clickScreen(_ editor: Editor, _ pt: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        editor.updateHover(at: pt)
        editor.mouseDown(at: pt, modifiers: modifiers, clickCount: count)
        editor.mouseUp(at: pt, modifiers: modifiers, clickCount: count)
    }

    static func key(_ chars: String, _ keyCode: UInt16) {
        guard let w = NSApp.windows.first(where: { $0.isVisible }) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) {
                w.sendEvent(e)
            }
        }
    }

    static func type(_ text: String) {
        for ch in text { key(String(ch), 0) }
    }

    /// Renders each settings tab offscreen (the Settings window itself is a separate scene).
    static func renderSettings(_ dir: URL) {
        let tabs: [(String, AnyView)] = [
            ("12-settings-navigation", AnyView(NavigationSettings())),
            ("13-settings-display", AnyView(DisplaySettings())),
            ("14-settings-print", AnyView(PrintSettings())),
        ]
        for (name, view) in tabs {
            let host = NSHostingView(rootView: view.frame(width: 520).fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            print("DEMO: wrote \(name)")
        }
    }

    static func run(_ editor: Editor, dir: URL, keepOpen: Bool) async {
        await pause(1.0)
        await snap(editor, "01-start", dir)

        // Sketch on XY: rectangle + dimensions via the real tools.
        editor.beginCommand(.sketchPlane)
        await snap(editor, "02-choose-plane", dir)
        editor.commit { $0.parameters = [UserParameter(name: "breite", expression: "70 mm")] }
        editor.beginSketch(on: .xy)
        await pause(0.8)
        editor.camera.distance = 160
        editor.camera.target = SIMD3(30, 20, 0)
        editor.setSketchTool(.rectangle)
        editor.updateHover(at: editor.camera.project(editor.activePlane!.point(Vec2(12.3, 7.7)))!)
        print("DEMO: snapped cursor \(editor.cursor.map { "\($0.position)" } ?? "nil") grid \(editor.gridSpacing.minor)")
        await snap(editor, "03a-cursor-grid", dir)
        clickSketch(editor, Vec2(0, 0))
        editor.updateHover(at: editor.camera.project(editor.activePlane!.point(Vec2(58, 38)))!)
        await pause(0.5)
        // Real keyboard path: type into the width field, Tab to height, type, Return.
        type("breite")
        key("\t", 48)
        type("40")
        await snap(editor, "03-rect-inputs", dir)
        key("\r", 36)
        await pause(0.3)
        editor.setSketchTool(.circle)
        clickSketch(editor, Vec2(35, 20))
        clickSketch(editor, Vec2(43, 20))
        editor.setSketchTool(.select)
        await snap(editor, "04-sketch", dir)

        editor.finishSketch()
        editor.homeView()
        await pause(0.6)

        // Extrude: click the outer profile.
        editor.beginCommand(.extrude)
        if let sid = editor.doc.features.first?.id, let sb = editor.state.sketches[sid],
           let outer = sb.regions.max(by: { $0.area < $1.area }),
           let pt = editor.camera.project(sb.plane.point(outer.sample)) {
            clickScreen(editor, pt)
        }
        editor.setExtrudeDistance(15)
        await snap(editor, "05-extrude-preview", dir)
        editor.commitCommand()
        editor.fitAll()
        await snap(editor, "06-body", dir)

        // Fillet the four vertical edges.
        editor.beginCommand(.fillet)
        if let body = editor.state.orderedBodies.first {
            for (i, e) in body.edgeInfos.enumerated() {
                guard let e, e.kind == .line, abs(e.end.z - e.start.z) > 1 else { continue }
                let ref = body.edgeRef(i)!
                editor.updateCommandFeature { k in
                    if case var .fillet(f) = k { f.edges.append(BodyEdgeRef(body: body.id, edge: ref)); k = .fillet(f) }
                }
            }
        }
        editor.updateCommandFeature { k in if case var .fillet(f) = k { f.radius = "5"; k = .fillet(f) } }
        await snap(editor, "07-fillet", dir)
        editor.commitCommand()

        // Shell from the top face.
        editor.beginCommand(.shell)
        if let body = editor.state.orderedBodies.first,
           let top = body.faceInfos.compactMap({ $0 }).filter({ $0.normal.z > 0.99 }).max(by: { $0.centroid.z < $1.centroid.z }),
           let pt = editor.camera.project(top.centroid + Vec3(20, 0, 0)) {
            clickScreen(editor, pt)
        }
        await snap(editor, "08-shell", dir)
        editor.commitCommand()
        editor.selection = []
        await snap(editor, "09-final", dir)

        editor.showCommandPalette = true
        await snap(editor, "10-palette", dir)
        editor.showCommandPalette = false
        let mc = CGPoint(x: editor.camera.viewSize.width / 2, y: editor.camera.viewSize.height / 2)
        editor.markingMenu = mc
        await pause(0.4)
        editor.markingMenuPointer = CGPoint(x: mc.x + 70, y: mc.y - 55)   // towards "Extrusion" (upper right)
        await snap(editor, "11-marking", dir)
        editor.markingMenu = nil

        if let sk = editor.doc.features.first?.kind.sketch {
            print("DEMO: sketch dims \(sk.constraints.compactMap { $0.kind.dimensionValue })")
        }
        renderSettings(dir)
        print("DEMO: errors \(editor.state.errors)")
        print("DEMO: done")
        if !keepOpen {
            editor.isDirty = false
            NSApp.terminate(nil)
        }
    }
}
