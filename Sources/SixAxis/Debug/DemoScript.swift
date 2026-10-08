import AppKit
import SwiftUI
import Foundation
import simd
import SixAxisCore

/// Scripted UI walkthrough for development and CI:
///   SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS=/tmp/shots open build/6axis.app
/// Drives the editor through real mouse-event code paths and writes PNG snapshots.
@MainActor
enum DemoScript {
    static func runIfRequested(_ editor: Editor) {
        let env = ProcessInfo.processInfo.environment
        // Session round-trip check: "write" builds a part and is killed, "check" reports what was restored.
        if let mode = env["SIXAXIS_SESSION_TEST"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                if mode == "write" {
                    var sk = Sketch(plane: .xy)
                    let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(30, 0)), sk.addPoint(Vec2(30, 30)), sk.addPoint(Vec2(0, 30))]
                    for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
                    let sketch = Feature(name: "Skizze1", kind: .sketch(sk))
                    var ex = ExtrudeFeature()
                    ex.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(5, 5))]
                    ex.distance = "12"
                    editor.commit { $0.features = [sketch, Feature(name: "Extrusion1", kind: .extrude(ex))] }
                    try? await Task.sleep(nanoseconds: 1_600_000_000)   // let the debounced autosave run
                    FileHandle.standardError.write(Data("SESSION written bodies=\(editor.state.bodyOrder.count)\n".utf8))
                    kill(getpid(), SIGKILL)                               // simulate a crash / hard kill
                } else {
                    let vol = editor.state.orderedBodies.first.map { String(format: "%.1f", $0.shape.volume) } ?? "-"
                    FileHandle.standardError.write(Data("SESSION restored features=\(editor.doc.features.count) volume=\(vol) dirty=\(editor.isDirty)\n".utf8))
                    exit(0)
                }
            }
            return
        }
        // Slow rebuild stays responsive: SIXAXIS_REBUILD_TEST=dir (plate with many holes)
        if let out = env["SIXAXIS_REBUILD_TEST"] {
            Task { @MainActor in
                let dir = URL(fileURLWithPath: out)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                await pause(1.0)
                var sk = Sketch(plane: .xy)
                let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(420, 0)), sk.addPoint(Vec2(420, 420)), sk.addPoint(Vec2(0, 420))]
                for i in 0..<4 { sk.addLine(c[i], c[(i + 1) % 4]) }
                let plate = Feature(name: "Platte", kind: .sketch(sk))
                var ex = ExtrudeFeature()
                ex.profiles = [ProfileRef(sketch: plate.id, sample: Vec2(1, 1))]
                ex.distance = "10 mm"
                var holes = Sketch(plane: .xy)
                var profiles: [ProfileRef] = []
                let hs = UUID()
                for i in 0..<20 { for j in 0..<20 {
                    let p = Vec2(15 + Double(i) * 20, 15 + Double(j) * 20)
                    holes.addCircle(center: holes.addPoint(p), radius: 4)
                    profiles.append(ProfileRef(sketch: hs, sample: p))
                } }
                var cut = ExtrudeFeature()
                cut.profiles = profiles
                cut.distance = "30 mm"
                cut.operation = .cut
                let start = Date()
                editor.commit { $0.features = [plate, Feature(name: "Platte", kind: .extrude(ex)),
                                               Feature(id: hs, name: "Löcher", kind: .sketch(holes)), Feature(name: "Löcher", kind: .extrude(cut))] }
                let returned = Date().timeIntervalSince(start)
                print("REBUILD commit returned after \(Int(returned * 1000)) ms, rebuilding=\(editor.isRebuilding)")
                await snap(editor, "rebuilding", dir)
                while editor.isRebuilding { await pause(0.05) }
                print("REBUILD done after \(Int(Date().timeIntervalSince(start) * 1000)) ms, bodies=\(editor.state.bodyOrder.count) errors=\(editor.state.errors.count) faces=\(editor.state.orderedBodies.first?.faceInfos.count ?? 0)")
                editor.homeView()
                await snap(editor, "done", dir)
                exit(0)
            }
            return
        }
        // One screenshot per shipped example: SIXAXIS_EXAMPLES_DEMO=dir
        if let out = env["SIXAXIS_EXAMPLES_DEMO"] {
            Task { @MainActor in
                let dir = URL(fileURLWithPath: out)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                await pause(1.0)
                for example in Examples.all {
                    editor.openExample(example)
                    await pause(0.8)
                    if !editor.state.errors.isEmpty { print("EXAMPLE \(example.fileName) errors \(editor.state.errors)") }
                    await snap(editor, example.fileName, dir)
                }
                exit(0)
            }
            return
        }
        if let out = env["SIXAXIS_DRAWING_DEMO"] {
            Task { @MainActor in
                buildCabinet(editor)
                let pages = editor.drawing.generateAllNow(editor)
                let page = pages[0]
                let dir = URL(fileURLWithPath: out)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                renderPNG(page, to: dir.appendingPathComponent("drawing.png"), pixelsPerMM: 5)
                for (i, p) in pages.enumerated() { renderPNG(p, to: dir.appendingPathComponent("sheet-\(i + 1).png"), pixelsPerMM: 5) }
                try? DrawingRenderer.writePDF(pages, to: dir.appendingPathComponent("drawing.pdf"), title: "Korpus")
                // Clean sheet for the website hero: only the three views with their dimensions.
                var heroInput = DrawingController.input(editor)
                heroInput.settings.showIso = false
                heroInput.settings.showBalloons = false
                heroInput.settings.showPartsList = false
                heroInput.settings.showPartSheets = false
                let hero = DrawingGenerator().generate(heroInput)
                try? hero.svg(cropToViews: true).write(to: dir.appendingPathComponent("hero.svg"), atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data("SHEETS \(pages.map { "\($0.name) \($0.sheet.name) \($0.scaleText ?? $0.scale.label)" })\n".utf8))
                let dims = page.texts.map(\.text).filter { Int($0) != nil || $0.hasPrefix("Ø") || $0.contains("× Ø") }
                FileHandle.standardError.write(Data("DRAWING \(page.sheet.name) \(page.scale.label) dims=\(dims)\n".utf8))
                // Stage 3 edits: hide, move, add a user dimension, move the iso view.
                editor.updateDrawingSettings { s in
                    s.hiddenDimensions.insert("front.x.481")
                    s.dimensionOffsets["front.y.290"] = DimensionOffset(distance: 6, along: 0)
                    s.customDimensions.append(CustomDimension(view: "front", a: Vec2(481, 309), b: Vec2(481, 581),
                                                              orientation: .vertical, offset: 14))
                    s.viewOffsets["iso"] = Vec2(15, 8)
                    s.sectionLeft = true
                    s.details = [DetailView(letter: "Z", view: "front", center: Vec2(19, 19), radius: 45, factor: 5)]
                }
                let editedPages = editor.drawing.generateAllNow(editor)
                let edited = editedPages[0]
                renderPNG(edited, to: dir.appendingPathComponent("edited.png"), pixelsPerMM: 5, highlight: "front.y.290")
                if editedPages.count > 1 { renderPNG(editedPages[1], to: dir.appendingPathComponent("edited-parts.png"), pixelsPerMM: 5) }
                try? edited.dxf().write(to: dir.appendingPathComponent("sheet.dxf"), atomically: true, encoding: .utf8)
                try? editor.drawing.partsDXF(editor).write(to: dir.appendingPathComponent("parts.dxf"), atomically: true, encoding: .utf8)
                let editedDims = edited.texts.map(\.text).filter { Int($0) != nil }
                FileHandle.standardError.write(Data("EDITED dims=\(editedDims) custom=\(edited.dimensions.filter(\.isCustom).map(\.text))\n".utf8))
                if let rounded = roundedBoard() {
                    let rp = DrawingGenerator().generate(.init(parts: [.init(name: "Schneidebrett", shape: rounded)], settings: DrawingSettings(), fallbackTitle: "Schneidebrett"))
                    renderPNG(rp, to: dir.appendingPathComponent("rounded.png"), pixelsPerMM: 6)
                    FileHandle.standardError.write(Data("ROUNDED \(rp.texts.map(\.text).filter { $0.contains("R") || $0.contains("Ø") })\n".utf8))
                }
                for (name, shape) in [("chamfer", chamferedShelf()), ("wedge", wedgePart())] {
                    guard let shape else { continue }
                    let pg = DrawingGenerator().generate(.init(parts: [.init(name: name, shape: shape)], settings: DrawingSettings(), fallbackTitle: name == "wedge" ? "Keil" : "Regalbrett"))
                    renderPNG(pg, to: dir.appendingPathComponent("\(name).png"), pixelsPerMM: 6)
                    FileHandle.standardError.write(Data("\(name.uppercased()) \(pg.texts.map(\.text).filter { $0.contains("°") })\n".utf8))
                }
                // Open the real drawing window and capture it.
                editor.openDrawingWindow()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let w = NSApp.windows.first(where: { $0.title.hasPrefix("Zeichnung") }), let view = w.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("window.png"))
                    FileHandle.standardError.write(Data("WINDOW captured \(w.title)\n".utf8))
                }
                exit(0)
            }
            return
        }
        guard env["SIXAXIS_DEMO"] != nil else { return }
        let dir = URL(fileURLWithPath: env["SIXAXIS_SNAPSHOTS"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            await run(editor, dir: dir, keepOpen: env["SIXAXIS_KEEP_OPEN"] != nil)
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

    /// Small cabinet (Korpus) of 19 mm boards: two sides, bottom, top, shelf, plus two dowel holes.
    /// The shipped cabinet example (Examples.cabinet).
    static func buildCabinet(_ editor: Editor) {
        editor.commit { $0 = Examples.cabinet() }
        if !editor.state.errors.isEmpty { FileHandle.standardError.write(Data("ERRORS \(editor.state.errors)\n".utf8)) }
    }

    /// Cutting board 300 × 200 × 20 with R12 corners and a Ø30 hanging hole.
    static func roundedBoard() -> SixAxisCore.Shape? {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(300, 0)), sk.addPoint(Vec2(300, 200)), sk.addPoint(Vec2(0, 200))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        sk.addCircle(center: sk.addPoint(Vec2(260, 160)), radius: 15)
        let sketch = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(5, 5))]
        ex.distance = "20"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features = [sketch, e]
        guard let body = ModelBuilder().build(doc).bodies[e.id] else { return nil }
        var fillet = FilletFeature()
        fillet.radius = "12"
        fillet.edges = body.edgeInfos.compactMap { info -> BodyEdgeRef? in
            guard let info, info.kind == .line, abs(info.end.z - info.start.z) > 1 else { return nil }
            return BodyEdgeRef(body: e.id, edge: body.edgeRef(info.index)!)
        }
        doc.features.append(Feature(name: "F", kind: .fillet(fillet)))
        return ModelBuilder().build(doc).bodies[e.id]?.shape
    }

    /// Prism from a closed polygon in a sketch plane.
    static func prism(_ plane: PlaneRef, _ pts: [Vec2], depth: Double) -> (CADDocument, UUID) {
        var doc = CADDocument()
        var sk = Sketch(plane: plane)
        let ids = pts.map { sk.addPoint($0) }
        for i in ids.indices { sk.addLine(ids[i], ids[(i + 1) % ids.count]) }
        let sketch = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: sketch.id, sample: (pts[0] + pts[1] + pts[2]) / 3)]
        ex.distance = "\(depth)"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features = [sketch, e]
        return (doc, e.id)
    }

    /// Shelf board 400 × 250 × 19 with 3 mm chamfers on the four vertical corners.
    static func chamferedShelf() -> SixAxisCore.Shape? {
        var (doc, id) = prism(.xy, [Vec2(0, 0), Vec2(400, 0), Vec2(400, 250), Vec2(0, 250)], depth: 19)
        guard let body = ModelBuilder().build(doc).bodies[id] else { return nil }
        var ch = ChamferFeature()
        ch.distance = "15"
        ch.edges = body.edgeInfos.compactMap { info -> BodyEdgeRef? in
            guard let info, info.kind == .line, abs(info.end.z - info.start.z) > 1 else { return nil }
            return BodyEdgeRef(body: id, edge: body.edgeRef(info.index)!)
        }
        doc.features.append(Feature(name: "C", kind: .chamfer(ch)))
        return ModelBuilder().build(doc).bodies[id]?.shape
    }

    /// Wedge: 300 long, 60 high on the left, 30 on the right, 80 deep.
    static func wedgePart() -> SixAxisCore.Shape? {
        let (doc, id) = prism(.xz, [Vec2(0, 0), Vec2(300, 0), Vec2(300, 30), Vec2(0, 60)], depth: 80)
        return ModelBuilder().build(doc).bodies[id]?.shape
    }

    static func renderPNG(_ page: DrawingPage, to url: URL, pixelsPerMM: CGFloat, highlight: String? = nil) {
        let w = Int(page.sheet.width * pixelsPerMM), h = Int(page.sheet.height * pixelsPerMM)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        DrawingRenderer.draw(page, in: cg, pointsPerMM: pixelsPerMM,
                             highlight: highlight.map { [$0: NSColor.systemBlue.cgColor] } ?? [:])
        guard let img = cg.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
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
