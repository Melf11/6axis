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

    static func run(_ editor: Editor) async {
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        editor.camera.distance = 200
        editor.camera.target = SIMD3(40, 25, 0)
        await pause(0.3)

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
    }
}
