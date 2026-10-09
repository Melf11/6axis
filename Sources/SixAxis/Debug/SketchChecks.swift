import AppKit
import Foundation
import simd
import SixAxisCore

/// Scripted sketch interactions through the real input pipeline (hover, snap, click, drag).
/// Each check prints "CHECK ok <name>" or "CHECK FAIL <name>: <detail>"; scripts/ui-check.sh collects them.
@MainActor
enum SketchChecks {
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print(ok ? "CHECK ok \(name)" : "CHECK FAIL \(name): \(detail())")
    }

    /// Screen point of a sketch coordinate.
    static func screen(_ editor: Editor, _ uv: Vec2) -> CGPoint? {
        guard let plane = editor.activePlane else { return nil }
        return editor.camera.project(plane.point(uv))
    }

    static func click(_ editor: Editor, _ uv: Vec2) {
        guard let pt = screen(editor, uv) else { return }
        editor.updateHover(at: pt)
        editor.mouseDown(at: pt, modifiers: [], clickCount: 1)
        editor.mouseUp(at: pt, modifiers: [], clickCount: 1)
    }

    static func drag(_ editor: Editor, from a: Vec2, to b: Vec2) {
        guard let pa = screen(editor, a), let pb = screen(editor, b) else { return }
        editor.updateHover(at: pa)
        editor.mouseDown(at: pa, modifiers: [], clickCount: 1)
        for i in 1...10 {
            let t = CGFloat(i) / 10
            let p = CGPoint(x: pa.x + (pb.x - pa.x) * t, y: pa.y + (pb.y - pa.y) * t)
            _ = editor.mouseDragged(to: p)
        }
        editor.mouseUp(at: pb, modifiers: [], clickCount: 1)
    }

    static func pause(_ s: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Fixed zoom so pick tolerances (in pixels) map to predictable sketch distances.
    static func view(_ editor: Editor, center: Vec2 = Vec2(40, 25)) async {
        editor.cameraAnimation = nil
        editor.camera.distance = 200
        if let plane = editor.activePlane {
            // Straight onto the sketch plane (an interrupted camera animation may leave it tilted).
            editor.camera.orientation = Camera.lookOrientation(direction: -plane.normal.float, up: plane.yDir.float)
            editor.camera.target = plane.point(center).float
        }
        await pause(0.3)
    }

    static func run(_ editor: Editor) async {
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)

        // 1. Rectangle 0,0 – 60,40, then drag its corner while the rectangle tool is still active.
        editor.setSketchTool(.rectangle)
        click(editor, Vec2(0, 0))
        click(editor, Vec2(60, 40))
        await pause()
        let corner = editor.activeSketch?.points.first { simd_distance($0.position, Vec2(60, 40)) < 1e-6 }
        check("rectangle created", editor.activeSketch?.curves.count == 4, "\(editor.activeSketch?.curves.count ?? 0) curves")
        drag(editor, from: Vec2(60, 40), to: Vec2(80, 50))
        await pause()
        if let id = corner?.id, let sk = editor.activeSketch, let p = sk.point(id) {
            check("corner dragged with rectangle tool", simd_distance(p, Vec2(80, 50)) < 1e-6, "corner at \(p)")
            let xs = Set(sk.points.filter { $0.id != Sketch.originId }.map { ($0.position.x * 1000).rounded() })
            check("rectangle stays axis-aligned", xs.count == 2, "x values \(xs)")
        } else {
            check("corner dragged with rectangle tool", false, "corner not found")
        }
        editor.setSketchTool(.select)
        drag(editor, from: Vec2(80, 50), to: Vec2(70, 45))
        await pause()
        check("corner dragged with select tool", editor.activeSketch.flatMap { sk in corner.flatMap { sk.point($0.id) } }.map { simd_distance($0, Vec2(70, 45)) < 1e-6 } ?? false)
        // 2. Spline attached to two rectangle corners closes a second profile.
        let topRight = Vec2(70, 45)
        let topLeft = editor.activeSketch?.points.first { $0.id != Sketch.originId && abs($0.position.x) < 1e-6 && abs($0.position.y - 45) < 1e-6 }?.position ?? Vec2(0, 45)
        editor.setSketchTool(.spline)
        click(editor, topRight)
        click(editor, Vec2(35, 65))
        click(editor, topLeft)
        _ = editor.handleKey("\r", keyCode: 36, modifiers: [])
        await pause(0.6)
        if let sk = editor.activeSketch, let spline = sk.curves.first(where: { $0.isSpline }), case let .spline(ids, closed) = spline.geometry {
            let corners = Set(sk.curves.filter(\.isLine).flatMap(\.geometry.pointIds))
            check("spline created", ids.count == 3 && !closed, "\(ids.count) points closed=\(closed)")
            check("spline shares rectangle corners", corners.contains(ids.first!) && corners.contains(ids.last!))
            let regions = editor.activeSketchBuild?.regions.count ?? 0
            check("spline closes a profile", regions == 2, "\(regions) regions")
        } else {
            check("spline created", false, "no spline")
        }
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
            editor.setSketchTool(.select)
            await DemoScript.snap(editor, "sketch-spline", URL(fileURLWithPath: dir))
        }

        // 3. Closed spline by clicking its start point.
        editor.setSketchTool(.spline)
        for p in [Vec2(100, 0), Vec2(130, -5), Vec2(135, 25), Vec2(105, 30), Vec2(100, 0)] { click(editor, p) }
        await pause(0.6)
        let closedOK = editor.activeSketch?.curves.contains { if case let .spline(ids, true) = $0.geometry { return ids.count == 4 }; return false } ?? false
        check("closed spline", closedOK)
        check("closed spline is a profile", (editor.activeSketchBuild?.regions.count ?? 0) == 3, "\(editor.activeSketchBuild?.regions.count ?? 0) regions")
        editor.finishSketch()
        await pause()

        // 4. Corner fillet and chamfer: click a corner, type the size.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.rectangle)
        click(editor, Vec2(0, 0))
        click(editor, Vec2(60, 40))
        editor.setSketchTool(.sketchFillet)
        click(editor, Vec2(60, 40))
        if let dim = editor.editingDimension {
            check("fillet asks for radius", true)
            editor.setDimensionValue(dim, "10")
            editor.editingDimension = nil
        } else {
            check("fillet asks for radius", false, "no dimension in edit")
        }
        editor.setSketchTool(.sketchChamfer)
        click(editor, Vec2(0, 40))
        if let dim = editor.editingDimension { editor.setDimensionValue(dim, "8"); editor.editingDimension = nil }
        await pause(0.6)
        let area = editor.activeSketchBuild?.regions.first?.area ?? 0
        // The rectangle has no dimensions, so its free size may shift slightly while solving – use its real size.
        let xs = editor.activeSketch?.points.map(\.position.x) ?? [], ys = editor.activeSketch?.points.map(\.position.y) ?? []
        let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
        let expected = w * h - 100 * (1 - .pi / 4) - 32
        check("fillet + chamfer area", abs(area - expected) < 0.05, "area \(area), expected \(expected)")

        check("sketch stays solvable", editor.lastSolve?.converged == true)
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
            editor.setSketchTool(.select)
            await DemoScript.snap(editor, "sketch-fillet", URL(fileURLWithPath: dir))
        }
        editor.finishSketch()
        await pause()

        // 5. Trim: divider line across a rectangle, cut off both overhangs.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.rectangle)
        click(editor, Vec2(0, 0)); click(editor, Vec2(60, 40))
        editor.setSketchTool(.line)
        click(editor, Vec2(20, -10)); click(editor, Vec2(20, 50))
        editor.escape()
        editor.setSketchTool(.trim)
        click(editor, Vec2(20, -5))
        click(editor, Vec2(20, 45))
        await pause(0.6)
        let trimmedRegions = editor.activeSketchBuild?.regions.count ?? 0
        check("trim divides rectangle", trimmedRegions == 2, "\(trimmedRegions) regions")
        let lineEnds = editor.activeSketch.map { sk in sk.curves.filter { c in
            if case let .line(a, b) = c.geometry, let pa = sk.point(a), let pb = sk.point(b) { return abs(pa.x - 20) < 1e-6 && abs(pb.x - 20) < 1e-6 }
            return false
        }.count } ?? 0
        check("trimmed divider kept", lineEnds == 1)
        editor.finishSketch()
        await pause()

        // 6. Offset a rectangle outwards, then type the distance.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.rectangle)
        click(editor, Vec2(0, 0)); click(editor, Vec2(60, 40))
        editor.setSketchTool(.offset)
        if let pt = screen(editor, Vec2(30, -0.6)) { editor.updateHover(at: pt) }
        check("offset preview", editor.offsetPreview() != nil)
        click(editor, Vec2(30, -0.6))
        if let dim = editor.editingDimension { editor.setDimensionValue(dim, "4"); editor.editingDimension = nil }
        await pause(0.6)
        let offsetRegions = editor.activeSketchBuild?.regions.count ?? 0
        // Every offset side lies 4 from its source (the undimensioned rectangle itself may shift).
        let gaps: [Double] = editor.activeSketch.map { sk in sk.constraints.compactMap { con -> Double? in
            guard case let .offset(copy, source, _) = con.kind, let cc = sk.curve(copy), case let .line(a, _) = cc.geometry,
                  let pa = sk.point(a), let sc = sk.curve(source) else { return nil }
            return simd_distance(pa, editor.footPoint(pa, on: sc, sk))
        } } ?? []
        check("offset ring", offsetRegions == 2 && gaps.count == 4 && gaps.allSatisfy { abs($0 - 4) < 1e-6 }, "regions \(offsetRegions), gaps \(gaps)")
        editor.finishSketch()
        await pause()

        // 7. Pattern: a hole, 4 instances 32 mm apart; then a bolt circle of 6.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.circle)
        click(editor, Vec2(40, 20)); click(editor, Vec2(43, 20))
        editor.setSketchTool(.select)
        // The radius snaps to the grid – click the actual rim.
        let rim = editor.activeSketch?.curves.first.flatMap { c in editor.activeSketch.map { Vec2(40 + $0.radius(of: c), 20) } } ?? Vec2(43, 20)
        click(editor, rim)
        check("circle selected", editor.selection.count == 1)
        editor.setSketchTool(.rectPattern)
        editor.patternRequest?.count = "4"
        editor.patternRequest?.spacing = "32 mm"
        check("pattern preview", (editor.patternPreview()?.curves.count ?? 0) == 4)
        editor.commitPattern()
        await pause(0.6)
        let px = editor.activeSketch?.curves.compactMap { c -> Double? in
            if case .circle = c.geometry { return editor.activeSketch?.center(of: c)?.x }; return nil
        }.sorted() ?? []
        check("rectangular pattern", px.count == 4 && zip(px, px.dropFirst()).allSatisfy { abs($1 - $0 - 32) < 1e-6 }, "\(px)")
        editor.selection = editor.activeSketch.map { sk in sk.curves.prefix(1).map { .sketchCurve(editor.sketchId!, $0.id) } } ?? []
        editor.setSketchTool(.circularPattern)
        click(editor, Vec2(0, 0))
        editor.patternRequest?.count = "6"
        editor.commitPattern()
        await pause(0.6)
        let circles = editor.activeSketch?.curves.filter { if case .circle = $0.geometry { return true }; return false }.count ?? 0
        check("circular pattern", circles == 4 + 5, "\(circles) circles")
        check("patterns solvable", editor.lastSolve?.converged == true)
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
            editor.fitAll()
            await pause(0.6)
            await DemoScript.snap(editor, "sketch-pattern", URL(fileURLWithPath: dir))
        }
        editor.finishSketch()
        await pause()

        // 9. Arc with typed chord and radius.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.arc)
        click(editor, Vec2(0, 0))
        editor.toolInputs = ["40", "0"]
        editor.commitToolInputs()
        if let pt = screen(editor, Vec2(20, 10)) { editor.updateHover(at: pt) }
        editor.toolInputs = ["25", ""]
        editor.commitToolInputs()
        await pause(0.4)
        if let sk = editor.activeSketch, let arc = sk.curves.first(where: { if case .arc = $0.geometry { return true }; return false }),
           case let .arc(_, s, e) = arc.geometry {
            let ends = [sk.point(s)!, sk.point(e)!].sorted { $0.x < $1.x }
            check("arc chord from typed length", simd_distance(ends[0], Vec2(0, 0)) < 1e-6 && simd_distance(ends[1], Vec2(40, 0)) < 1e-6, "\(ends)")
            check("arc radius from typed value", abs(sk.radius(of: arc) - 25) < 1e-6, "\(sk.radius(of: arc))")
            check("arc bulges to the cursor side", (sk.polyline(arc, segments: 16).map(\.y).max() ?? 0) > 1)
            check("arc radius dimension", sk.constraints.contains { if case .radius(arc.id, "25") = $0.kind { return true }; return false })
        } else {
            check("arc created from typed values", false)
        }
        editor.finishSketch()
        await pause()

        // 8. Project the top face of a body into a new sketch.
        editor.newDocument()
        editor.commit { $0 = Examples.storageBox().withoutShell() }
        await pause(1.0)
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor, center: Vec2(0, 0))
        editor.camera.distance = 400
        await pause(0.3)
        editor.setSketchTool(.project)
        if let pt = screen(editor, Vec2(25, 15)) { editor.updateHover(at: pt) }
        let hovered: String = { if case .face? = editor.hover { return "face" }; return String(describing: editor.hover) }()
        check("project hovers body face", hovered == "face", hovered)
        click(editor, Vec2(25, 15))
        await pause(0.6)
        let projected = editor.activeSketch?.curves.count ?? 0
        check("projected outline", projected >= 8, "\(projected) curves")
        check("projected outline is a profile", (editor.activeSketchBuild?.regions.count ?? 0) >= 1)
        editor.finishSketch()
        await pause()
    }
}
