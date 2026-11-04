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

        // 10. Text: place, type, edit.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor, center: Vec2(30, 5))
        editor.setSketchTool(.text)
        click(editor, Vec2(10, 0))
        check("text dialog opens", editor.textRequest != nil)
        editor.textRequest?.text = "6axis"
        editor.textRequest?.height = "12 mm"
        editor.commitText()
        await pause(0.6)
        let textCurve = editor.activeSketch?.curves.first { $0.isText }
        check("text created", textCurve != nil)
        let textRegions = editor.activeSketchBuild?.regions.count ?? 0
        check("text gives profiles", textRegions >= 5, "\(textRegions) regions")
        if let c = textCurve, let sk = editor.activeSketch, case let .text(a, _, _, _) = c.geometry {
            editor.textRequest = TextRequest(anchor: SnapTarget(position: sk.point(a)!, point: a), editing: c.id, text: "Eiche", height: "12 mm")
            editor.commitText()
            let edited = editor.activeSketch?.curve(c.id).map { if case let .text(_, t, _, _) = $0.geometry { return t }; return "" }
            check("text edited in place", edited == "Eiche" && (editor.activeSketch?.curves.filter(\.isText).count ?? 0) == 1)
        }
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
            editor.setSketchTool(.select)
            await DemoScript.snap(editor, "sketch-text", URL(fileURLWithPath: dir))
        }
        editor.finishSketch()
        await pause()

        // 12. Spline handles: select a spline, its handles appear; a longer handle reshapes the curve.
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.spline)
        for p in [Vec2(0, 0), Vec2(40, 25), Vec2(80, 0)] { click(editor, p) }
        _ = editor.handleKey("\r", keyCode: 36, modifiers: [])
        editor.setSketchTool(.select)
        let spline = editor.activeSketch?.curves.first { $0.isSpline }
        if let spline, let sk = editor.activeSketch {
            let onCurve = sk.polyline(spline, segments: 200)[60]
            click(editor, onCurve)
            check("spline selected shows handles", editor.splinesWithHandles == [spline.id] && editor.splineHandles(spline.id).count == 3,
                  "\(editor.splinesWithHandles) \(editor.splineHandles(spline.id).count)")
            let before = sk.polyline(spline, segments: 200)
            if let mid = editor.splineHandles(spline.id).first(where: { simd_distance($0.position, Vec2(40, 25)) < 1e-6 }) {
                editor.setSplineHandle(curve: spline.id, point: mid.point, to: Vec2(35, 0))
            }
            let after = editor.activeSketch.map { $0.polyline($0.curve(spline.id)!, segments: 200) } ?? []
            let moved = zip(before, after).map { simd_distance($0, $1) }.max() ?? 0
            check("handle reshapes spline", moved > 1, "max change \(moved)")
            check("spline still through its point", after.map { simd_distance($0, Vec2(40, 25)) }.min() ?? 1 < 1e-6)
            check("handle is custom", editor.splineHandles(spline.id).contains { $0.custom })
            if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
                await DemoScript.snap(editor, "sketch-spline-handles", URL(fileURLWithPath: dir))
            }
        } else {
            check("spline for handles", false)
        }
        editor.finishSketch()
        await pause()

        // 11. Delete bodies with the ⌫ key.
        editor.newDocument()
        editor.commit { d in
            let a = SketchEdit.check_box(name: "A", x: 0), b = SketchEdit.check_box(name: "B", x: 100)
            d.features = a + b
        }
        await pause(1.0)
        let ids = editor.state.bodyOrder
        check("two bodies", ids.count == 2)
        if ids.count == 2 {
            editor.selection = [.body(ids[1])]
            _ = editor.handleKey("\u{7f}", keyCode: 51, modifiers: [])
            await pause(0.6)
            // The extrusion step goes, its sketch stays (like Fusion).
            check("⌫ deletes newest body with its step", editor.state.bodyOrder == [ids[0]] && editor.doc.features.count == 3,
                  "bodies \(editor.state.bodyOrder.count) features \(editor.doc.features.count)")
            editor.selection = [.face(ids[0], 0)]
            _ = editor.handleKey("\u{7f}", keyCode: 51, modifiers: [])
            await pause(0.6)
            let removeStep = editor.doc.features.last.map { if case .removeBodies = $0.kind { return true }; return false } ?? false
            check("⌫ on older body adds a remove step", editor.state.bodyOrder.isEmpty && removeStep)
            editor.undo()
            await pause(0.6)
            check("undo brings the body back", editor.state.bodyOrder == [ids[0]])
        }

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
        await textEnterCheck(editor)
        await polygonChecks(editor)
        await viewLockChecks(editor)
        await dimensionToolChecks(editor)
        await smartGuideChecks(editor)
        await connectChecks(editor)
    }

    /// Enter in the text field of the text dialog closes it (crashed: the field read the closed dialog's values).
    static func textEnterCheck(_ editor: Editor) async {
        func findField(_ v: NSView?) -> NSTextField? {
            guard let v else { return nil }
            if let f = v as? NSTextField, f.isEditable { return f }
            for sub in v.subviews { if let f = findField(sub) { return f } }
            return nil
        }
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        editor.setSketchTool(.text)
        click(editor, Vec2(10, 10))
        await pause(0.6)
        check("text: dialog opens", editor.textRequest != nil)
        editor.textRequest?.text = "Hallo"
        await pause(0.4)
        guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
              let field = findField(win.contentView) else { return check("text: field found", false) }
        win.makeFirstResponder(field)
        await pause(0.2)
        if let fieldEditor = field.currentEditor() as? NSTextView {
            fieldEditor.insertText("!", replacementRange: fieldEditor.selectedRange())
            await pause(0.1)
            fieldEditor.insertNewline(nil)
        } else {
            field.sendAction(field.action, to: field.target)
        }
        if editor.textRequest != nil { editor.commitText() }
        await pause(0.6)
        check("text: enter closes the dialog", editor.textRequest == nil)
        check("text: enter creates the text", editor.activeSketch?.curves.contains(where: \.isText) == true)
        editor.finishSketch()
        await pause(0.3)
    }

    /// A dragged point connects to the point or line it is let go on, on the grid or not.
    static func connectChecks(_ editor: Editor) async {
        let settings = AppSettings.shared
        let grid = settings.snapToGrid
        settings.snapToGrid = true
        settings.lockSketchView = true
        defer { settings.snapToGrid = grid; editor.freePlacementInChecks = false }
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        func line(_ a: Vec2, _ b: Vec2) {
            editor.setSketchTool(.line)
            click(editor, a)
            click(editor, b)
            editor.cancelSketchTool()
            editor.setSketchTool(.select)
        }
        line(Vec2(0, 0), Vec2(60, 0))        // target line, off to the side of the grid in the middle
        line(Vec2(20, 30), Vec2(40, 40))     // the end at 40/40 gets dragged
        await pause()
        // Let go over a point of the target line: exactly on its end.
        drag(editor, from: Vec2(40, 40), to: Vec2(60.5, 0.5))
        await pause()
        if let sk = editor.activeSketch {
            let lines = sk.curves.filter(\.isLine)
            let shared = Set(lines[0].geometry.pointIds).intersection(lines[1].geometry.pointIds)
            check("connect: lands on the other point and shares it", shared.count == 1, "\(lines)")
            check("connect: no marker afterwards", editor.dropMarker == nil)
        }
        editor.undo()
        await pause()
        check("connect: undo takes the connection back", {
            guard let sk = editor.activeSketch else { return false }
            let lines = sk.curves.filter(\.isLine)
            return lines.count == 2 && Set(lines[0].geometry.pointIds).isDisjoint(with: lines[1].geometry.pointIds)
        }())
        // Let go over the line, away from the grid: stays on it, also when the line moves later.
        let off = Vec2(33.37, 0.4)
        drag(editor, from: Vec2(40, 40), to: off)
        await pause()
        if let sk = editor.activeSketch, let moved = sk.curves.filter(\.isLine).last, case let .line(_, end) = moved.geometry, let p = sk.point(end) {
            check("connect: lands on the line, off the grid", abs(p.y) < 1e-6 && abs(p.x - 33.37) < 0.2, "\(p)")
            check("connect: stays connected", sk.constraints.contains { if case let .pointOnCurve(q, _) = $0.kind { return q == end }; return false })
        }
        editor.undo()
        await pause()
        // ⌘: no connection, on the spot.
        editor.freePlacementInChecks = true
        drag(editor, from: Vec2(40, 40), to: off)
        await pause()
        editor.freePlacementInChecks = false
        check("connect: ⌘ does not connect", editor.activeSketch?.constraints.contains { if case .pointOnCurve = $0.kind { return true }; return false } == false)
        editor.undo()
        await pause()
        // The other end of its own line is no target: the line would vanish.
        drag(editor, from: Vec2(40, 40), to: Vec2(20.5, 30.5))
        await pause()
        check("connect: not onto its own line's other end", editor.activeSketch?.curves.filter(\.isLine).count == 2
              && editor.activeSketch?.curves.last.map { Set($0.geometry.pointIds).count == 2 } == true)
        editor.finishSketch()
        await pause(0.4)

        // Lines closed by dragging become a profile; a neighbouring one stays its own.
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        line(Vec2(0, 0), Vec2(40, 0))
        line(Vec2(40, 0), Vec2(40, 30))
        line(Vec2(40, 30), Vec2(10, 30))
        line(Vec2(10, 30), Vec2(5, 10))
        await pause()
        check("profile: open lines are none", editor.activeSketchBuild?.regions.isEmpty == true, "\(editor.activeSketchBuild?.regions.count ?? -1)")
        drag(editor, from: Vec2(5, 10), to: Vec2(0.4, 0.4))
        await pause(0.6)
        check("profile: closing by dragging makes one", editor.activeSketchBuild?.regions.count == 1, "\(editor.activeSketchBuild?.regions.count ?? -1)")
        // Three more sides against the right edge: two profiles side by side, each with its own measure.
        line(Vec2(40, 0), Vec2(80, 0))
        line(Vec2(80, 0), Vec2(80, 30))
        line(Vec2(80, 30), Vec2(40, 30))
        await pause(0.6)
        let regions = editor.activeSketchBuild?.regions ?? []
        check("profile: neighbours stay separate", regions.count == 2, "\(regions.count)")
        if let id = editor.sketchId, let right = regions.first(where: { $0.center.x > 40 }) {
            editor.setSketchTool(.line)
            click(editor, Vec2(60, 15))
            check("profile: a drawing tool draws instead of selecting", editor.selection.isEmpty && editor.toolPoints.count == 1)
            editor.cancelSketchTool()
            editor.setSketchTool(.select)
            await pause(0.4)
            click(editor, Vec2(60, 15))
            await pause(0.4)
            check("profile: a click selects it", editor.selection == [.profile(id, right.index)], "\(editor.selection)")
            check("profile: a neighbour shows its own area", editor.selectionMeasure?.detail.contains("12.00 cm²") == true, "\(String(describing: editor.selectionMeasure))")
            if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] { await DemoScript.snap(editor, "sketch-neighbours", URL(fileURLWithPath: dir)) }
            // The sketch as a drawing sheet, in all three formats.
            if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"], let build = editor.activeSketchBuild,
               let page = SketchDrawing.page(build, title: "Skizze1") {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for format in [Editor.SketchDrawingFormat.pdf, .svg, .dxf] {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("sketch-drawing." + format.rawValue)
                    try? Editor.write(page, as: format, to: url, title: "Skizze1")
                    check("drawing: \(format.rawValue) written", ((try? Data(contentsOf: url))?.count ?? 0) > 200)
                }
            }
            editor.selection.removeAll()
        }
        editor.finishSketch()
        await pause(0.4)
    }

    /// Two clicks make a dimension; a line and a click place its length; the fine grid leaves a moving view.
    static func dimensionToolChecks(_ editor: Editor) async {
        let settings = AppSettings.shared
        settings.lockSketchView = true
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        func dims() -> [ConstraintKind] { editor.activeSketch?.constraints.map(\.kind).filter(\.isDimension) ?? [] }
        editor.setSketchTool(.line)
        click(editor, Vec2(0, 0))
        click(editor, Vec2(60, 0))
        editor.cancelSketchTool()
        click(editor, Vec2(10, 20))
        click(editor, Vec2(40, 35))
        editor.cancelSketchTool()
        editor.setSketchTool(.dimension)
        await pause()
        click(editor, Vec2(0, 0))
        check("dimension: one click only marks the point", dims().isEmpty && editor.dimensionFirst != nil, "\(dims())")
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] {
            if let pt = screen(editor, Vec2(50, -15)) { editor.updateHover(at: pt) }
            await DemoScript.snap(editor, "sketch-dimension-preview", URL(fileURLWithPath: dir))
        }
        click(editor, Vec2(60, 0))
        await pause()
        check("dimension: the second point makes it at once", dims().count == 1, "\(dims())")
        check("dimension: along the axis when they lie on one", { if case .horizontalDistance? = dims().last { return true }; return false }(), "\(dims())")
        check("dimension: its value can be typed at once", editor.editingDimension != nil)
        check("dimension: nothing is left pending", editor.dimensionFirst == nil)
        editor.editingDimension = nil
        await pause()
        click(editor, Vec2(10, 20))
        click(editor, Vec2(40, 35))
        await pause()
        check("dimension: slanted points give the true distance", { if case .distance? = dims().last { return true }; return false }(), "\(dims())")
        editor.editingDimension = nil
        await pause()
        // A line, then a click beside it.
        click(editor, Vec2(25, 27.5))
        check("dimension: a line waits for the place", dims().count == 2 && editor.dimensionFirst != nil, "\(dims())")
        click(editor, Vec2(10, 45))
        await pause()
        check("dimension: a line and a click give its length", { if case .length? = dims().last { return true }; return false }(), "\(dims())")
        editor.editingDimension = nil
        editor.cancelSketchTool()

        // The fine grid is off while the view moves and returns afterwards.
        editor.pan(dx: 3, dy: 0)
        check("grid: fine lines off while moving", editor.fineGridOpacity == 0, "\(editor.fineGridOpacity)")
        await pause(0.5)
        check("grid: fine lines back afterwards", editor.fineGridOpacity == 1, "\(editor.fineGridOpacity)")
        editor.finishSketch()
        await pause(0.4)
        editor.pan(dx: 3, dy: 0)
        check("grid: stays on outside a sketch", editor.fineGridOpacity == 1)
    }

    /// Resting on a point notes it, the cursor lines up with it; lines snap to the usual angles; ⌘ turns it all off.
    static func smartGuideChecks(_ editor: Editor) async {
        let settings = AppSettings.shared
        let grid = settings.snapToGrid
        settings.lockSketchView = true
        defer { settings.snapToGrid = grid; editor.freePlacementInChecks = false }
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        func hover(_ uv: Vec2) { if let pt = screen(editor, uv) { editor.updateHover(at: pt) } }
        let step = 3 * Double(editor.camera.worldPerPoint)   // about 3 points on the screen: within reach
        editor.setSketchTool(.line)
        click(editor, Vec2(40, 30))
        click(editor, Vec2(70, 30))
        editor.cancelSketchTool()
        settings.snapToGrid = false
        await pause()
        guard let noted = editor.activeSketch?.points.first(where: { simd_distance($0.position, Vec2(40, 30)) < 1e-6 })?.id else {
            return check("guides: line drawn", false)
        }

        // A quick pass over a point notes nothing, resting does.
        hover(Vec2(40, 30))
        hover(Vec2(90, 90))
        await pause(0.5)
        check("guides: passing over a point notes nothing", editor.notedPoints.isEmpty)
        hover(Vec2(40, 30))
        await pause(0.5)
        check("guides: resting on a point notes it", editor.notedPoints == [noted], "\(editor.notedPoints)")

        // Lined up below it: the X locks, the guide shows the distance.
        hover(Vec2(40 + step, 80))
        let below = editor.cursor?.position ?? .zero
        check("guides: lines up with the noted point", abs(below.x - 40) < 1e-9 && abs(below.y - 80) < 0.05, "\(below)")
        check("guides: guide from the point to the cursor", editor.smartGuides == [SmartGuide(from: Vec2(40, 30), to: below)], "\(editor.smartGuides)")
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] { await DemoScript.snap(editor, "sketch-guide", URL(fileURLWithPath: dir)) }
        hover(Vec2(55, 80))
        check("guides: away from it no guide", editor.smartGuides.isEmpty && abs((editor.cursor?.position.x ?? 0) - 55) < 0.05)
        hover(Vec2(40 + step, 80))
        editor.freePlacementInChecks = true
        hover(Vec2(40 + step, 80))
        check("guides: ⌘ places freely", editor.smartGuides.isEmpty && abs((editor.cursor?.position.x ?? 0) - (40 + step)) < 0.05, "\(String(describing: editor.cursor))")
        hover(Vec2(40, 30))
        check("guides: ⌘ ignores points too", editor.cursor?.point == nil, "\(String(describing: editor.cursor))")
        editor.freePlacementInChecks = false

        // The usual angles from the start of a line.
        settings.snapToGrid = true
        click(editor, Vec2(-50, -50))
        settings.snapToGrid = false
        for (angle, near) in [(45.0, Vec2(-20, -19.4)), (30.0, Vec2(-10, -26.4)), (60.0, Vec2(-30, -15.6))] {
            hover(near)
            let d = (editor.cursor?.position ?? .zero) - Vec2(-50, -50)
            let got = atan2(d.y, d.x) * 180 / .pi
            check("guides: line snaps to \(Int(angle))°", abs(got - angle) < 1e-6 && editor.smartAngle == angle, "\(got) \(String(describing: editor.smartAngle))")
        }
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] { await DemoScript.snap(editor, "sketch-guide-angle", URL(fileURLWithPath: dir)) }
        hover(Vec2(-20, -40))
        check("guides: another angle stays free", editor.smartAngle == nil && abs((editor.cursor?.position.y ?? 0) + 40) < 0.05, "\(String(describing: editor.cursor))")
        hover(Vec2(0, -50 + step))
        check("guides: horizontal keeps its constraint", editor.inference == .horizontal && abs((editor.cursor?.position.y ?? 0) + 50) < 1e-9)
        editor.freePlacementInChecks = true
        hover(Vec2(-20, -19.4))
        check("guides: ⌘ ignores the angles", editor.smartAngle == nil && abs((editor.cursor?.position.y ?? 0) + 19.4) < 0.05)
        editor.freePlacementInChecks = false
        editor.setSketchTool(.select)
        check("guides: leaving the tool forgets the points", editor.notedPoints.isEmpty && editor.smartGuides.isEmpty)
        editor.finishSketch()
        await pause(0.4)
    }

    /// A sketch keeps its view straight unless the lock is opened; two fingers only ever move along its axes.
    static func viewLockChecks(_ editor: Editor) async {
        guard let vp = NSApp.windows.lazy.compactMap({ findViewport($0.contentView) }).first else { return check("view lock: viewport", false) }
        func swipe(shift: Bool = false) {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: 40, wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.flags = shift ? .maskShift : []
            if let ns = NSEvent(cgEvent: e) { vp.scrollWheel(with: ns) }
        }
        func same(_ a: simd_quatf, _ b: simd_quatf) -> Bool { abs(abs(simd_dot(a, b)) - 1) < 1e-5 }
        let settings = AppSettings.shared
        let swipeSetting = settings.trackpadSwipe
        settings.lockSketchView = true
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        let straight = editor.camera.orientation
        check("view lock: on by default in a sketch", editor.isSketchViewLocked)
        editor.orbit(dx: 80, dy: 40)
        check("view lock: dragging does not turn", same(editor.camera.orientation, straight))
        editor.setView(direction: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1))
        editor.turnView(axis: SIMD3(1, 0, 0), sign: 1)
        check("view lock: cube and view keys do not turn", same((editor.cameraAnimation?.to ?? editor.camera).orientation, straight))
        editor.homeView()
        check("view lock: home stays straight", same((editor.cameraAnimation?.to ?? editor.camera).orientation, straight))
        for (setting, shift) in [(AppSettings.SwipeAction.orbit, false), (.pan, false), (.orbit, true), (.pan, true)] {
            settings.trackpadSwipe = setting
            let target = editor.camera.target
            swipe(shift: shift)
            check("view lock: two fingers move (\(setting), shift \(shift))",
                  same(editor.camera.orientation, straight) && simd_distance(target, editor.camera.target) > 1e-3 && abs(editor.camera.target.z - target.z) < 1e-4)
        }
        if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] { await DemoScript.snap(editor, "sketch-view-locked", URL(fileURLWithPath: dir)) }
        // Opened: turning works, two fingers still only move; closing it turns back straight.
        editor.toggleSketchViewLock()
        editor.orbit(dx: 80, dy: 40)
        let turned = editor.camera.orientation
        check("view lock: open, dragging turns", !same(turned, straight))
        settings.trackpadSwipe = .pan
        swipe()
        check("view lock: open, two fingers still only move", same(editor.camera.orientation, turned))
        editor.toggleSketchViewLock()
        // The goal of the animation: it only advances with frames, and those depend on the display being awake.
        check("view lock: closing turns back to the sketch", same((editor.cameraAnimation?.to ?? editor.camera).orientation, straight))
        editor.camera = editor.cameraAnimation?.to ?? editor.camera
        editor.cameraAnimation = nil
        settings.trackpadSwipe = swipeSetting
        editor.finishSketch()
        await pause(0.5)
        let before = editor.camera.orientation
        editor.orbit(dx: 80, dy: 40)
        check("view lock: free again after the sketch", !same(editor.camera.orientation, before))
    }

    private static func findViewport(_ v: NSView?) -> ViewportNSView? {
        guard let v else { return nil }
        if let vp = v as? ViewportNSView { return vp }
        for sub in v.subviews { if let f = findViewport(sub) { return f } }
        return nil
    }

    /// Tool "Mittig" with corners, and a circle turned into polygons through the properties.
    static func polygonChecks(_ editor: Editor) async {
        func shot(_ name: String) async {
            if let dir = ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] { await DemoScript.snap(editor, name, URL(fileURLWithPath: dir)) }
        }
        editor.newDocument()
        editor.beginSketch(on: .xy)
        await pause(0.8)
        await view(editor)
        // Mittig with six corners: centre, then a point at distance 10 → wrench size 20.
        editor.setSketchTool(.centerRectangle)
        editor.centerToolSides = 6
        click(editor, Vec2(20, 20))
        await shot("sketch-polygon-tool")
        click(editor, Vec2(30, 20))
        await pause()
        let made = editor.activeSketch?.curves.first
        check("polygon tool: one curve with six corners", editor.activeSketch?.curves.count == 1 && made?.polygon?.sides == 6, "\(String(describing: made))")
        check("polygon tool: is a profile", editor.activeSketchBuild?.regions.count == 1)
        editor.centerToolSides = nil
        click(editor, Vec2(60, 25))
        click(editor, Vec2(70, 35))
        await pause()
        check("Mittig without corners stays a rectangle", editor.activeSketch?.curves.filter(\.isLine).count == 4 + 1, "\(editor.activeSketch?.curves.count ?? 0) curves")

        // Selecting a profile and a line shows their measures in the status bar.
        if let sb = editor.activeSketchBuild, let id = editor.sketchId, let i = sb.regions.indices.first(where: { abs(sb.regions[$0].center.x - 20) < 1 }) {
            editor.selection = [.profile(id, i)]
            await pause(0.4)
            let side = 20 * tan(Double.pi / 6)
            let expected = 6 * side
            let m = editor.selectionMeasure
            check("status bar: a profile's area and perimeter", m?.title.contains("1") == true && m?.detail.contains(formatValue(expected)) == true && m?.detail.contains("cm²") == true,
                  "\(String(describing: m)), expected \(formatValue(expected))")
            if let line = editor.activeSketch?.curves.first(where: { $0.isLine && !$0.construction }) {
                editor.selection = [.sketchCurve(id, line.id)]
                await pause(0.4)
                let sk = editor.activeSketch!
                check("status bar: a line's length", editor.selectionMeasure?.detail.contains(formatValue(sk.length(of: line))) == true, "\(String(describing: editor.selectionMeasure))")
                await DemoScript.snap(editor, "sketch-measure-line", URL(fileURLWithPath: ProcessInfo.processInfo.environment["SIXAXIS_SNAPSHOTS"] ?? NSTemporaryDirectory()))
            }
            editor.selection.removeAll()
            check("status bar: nothing selected, no measure", editor.selectionMeasure == nil)
        } else { check("status bar: profile found", false) }
        // A circle: select it, turn it into a square, set its size, back to round.
        editor.setSketchTool(.circle)
        click(editor, Vec2(20, 60))
        click(editor, Vec2(30, 60))
        editor.setSketchTool(.select)
        await pause()
        guard let circle = editor.activeSketch?.curves.last, let cid = Optional(circle.id) else { return check("polygon: circle created", false) }
        click(editor, Vec2(30, 60))
        await pause()
        check("properties: click selects the circle", editor.selectedSketchCurves == [cid], "\(editor.selectedSketchCurves)")
        await shot("sketch-properties-circle")
        editor.setPolygonSides([cid], 4)
        editor.setSize([cid], "30 mm")
        await pause()
        await shot("sketch-properties-square")
        if let sk = editor.activeSketch, let c = sk.curve(cid) {
            check("properties: square keeps its centre", sk.center(of: c).map { simd_distance($0, Vec2(20, 60)) < 1e-6 } ?? false)
            check("properties: size is the width across flats", abs(sk.radius(of: c) - 15) < 1e-6 && abs((sk.polygonCorners(c).map(\.x).max() ?? 0) - 35) < 1e-6, "\(sk.polygonCorners(c))")
            check("properties: the size is a dimension", editor.sizeText(c, in: sk) == "30 mm", editor.sizeText(c, in: sk))
        }
        await pause(0.4)
        check("status bar: a square's outline", editor.selectionMeasure?.detail.contains("120") == true, "\(String(describing: editor.selectionMeasure))")
        // The square's corner sticks out beyond the circle: picking follows the polygon.
        editor.selection.removeAll()
        click(editor, Vec2(34, 74))
        await pause()
        check("properties: a corner of the polygon can be clicked", editor.selectedSketchCurves == [cid], "\(editor.selectedSketchCurves)")
        editor.undo()
        editor.undo()
        await pause()
        check("properties: undo takes back size and shape", editor.activeSketch?.curve(cid)?.polygon == nil, "\(String(describing: editor.activeSketch?.curve(cid)))")
        editor.setConstruction([cid], true)
        check("properties: construction", editor.activeSketch?.curve(cid)?.construction == true)
        editor.finishSketch()
        await pause()
    }
}
