import AppKit
import Foundation
import simd
import SixAxisCore

/// Scripted use of the 1.2 commands through the real pick pipeline: SIXAXIS_MODEL_TEST=1.
/// Prints "CHECK ok/FAIL" lines like SketchChecks; snapshots of the dialogs go to SIXAXIS_SNAPSHOTS.
@MainActor
enum ModellingChecks {
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { SketchChecks.check(name, ok, detail()) }
    static func pause(_ s: Double = 0.3) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func settle(_ editor: Editor) async {
        await pause(0.15)
        while editor.isRebuilding { await pause(0.05) }
        await pause(0.25)
    }

    /// Hover and click a point in space (whatever the pick buffer has there).
    static func click(_ editor: Editor, _ p: Vec3) async {
        guard let pt = editor.camera.project(p) else { return }
        editor.updateHover(at: pt)
        editor.mouseDown(at: pt, modifiers: [], clickCount: 1)
        editor.mouseUp(at: pt, modifiers: [], clickCount: 1)
        await settle(editor)
    }

    static func volume(_ editor: Editor, _ body: UUID) -> Double { editor.state.bodies[body]?.shape.volume ?? 0 }

    static func run(_ editor: Editor, snapshots: URL?) async {
        func snap(_ name: String) async { if let snapshots { await DemoScript.snap(editor, name, snapshots) } }
        editor.newDocument()
        // Plate 100 × 60 × 20 and a bolt Ø8 × 12 beside it.
        var plate = Sketch(plane: .xy)
        let c = [plate.addPoint(Vec2(0, 0)), plate.addPoint(Vec2(100, 0)), plate.addPoint(Vec2(100, 60)), plate.addPoint(Vec2(0, 60))]
        for i in 0..<4 { plate.addLine(c[i], c[(i + 1) % 4]) }
        var boltSketch = Sketch(plane: .xy)
        boltSketch.addCircle(center: boltSketch.addPoint(Vec2(150, 30)), radius: 4)
        let s1 = Feature(name: "Platte", kind: .sketch(plate)), s2 = Feature(name: "Bolzen", kind: .sketch(boltSketch))
        var e1 = ExtrudeFeature(); e1.profiles = [ProfileRef(sketch: s1.id, sample: Vec2(50, 30))]; e1.distance = "20 mm"
        var e2 = ExtrudeFeature(); e2.profiles = [ProfileRef(sketch: s2.id, sample: Vec2(150, 30))]; e2.distance = "12 mm"
        let plateF = Feature(name: "Platte", kind: .extrude(e1)), boltF = Feature(name: "Bolzen", kind: .extrude(e2))
        editor.commit { $0.features = [s1, plateF, s2, boltF]; $0.hiddenSketches = [s1.id, s2.id] }
        await settle(editor)
        editor.cameraAnimation = nil
        editor.camera.target = SIMD3<Float>(75, 30, 5)
        editor.camera.distance = 330
        await settle(editor)
        let full = 100.0 * 60 * 20

        // Hole: two clicks on the top face, Ø8 through.
        editor.beginCommand(.hole)
        await click(editor, Vec3(31.6, 28.7, 20))
        // While positioning, the hovered face shows a grid (step 10 at this zoom) and the click lands on it.
        // (The preview renumbers faces – move the mouse again like the user would.)
        if let pt = editor.camera.project(Vec3(50, 45, 20)) { editor.updateHover(at: pt) }
        var grid = SceneBuilder(editor: editor, scale: 2)
        grid.buildGrid()
        let faceLines = grid.scene.lines.filter { $0.depthBias > 0 }.flatMap(\.instances)
        check("hole: grid on the hovered face", faceLines.count == 11 + 7 && faceLines.allSatisfy { abs($0.z0 - 20) < 1e-3 && abs($0.z1 - 20) < 1e-3 },
              "\(faceLines.count) lines, step \(editor.gridSpacing.minor), z \(Set(faceLines.map(\.z0)))")
        if case let .hole(h)? = editor.commandFeature?.kind, case let .faceOffset(_, x, y)? = h.points.first {
            check("hole: click snaps to the face grid", x == "30" && y == "30", "\(x) \(y)")
        } else {
            check("hole: click snaps to the face grid", false)
        }
        await click(editor, Vec3(70, 30, 20))
        editor.updateCommandFeature { k in if case var .hole(h) = k { h.diameter = "8 mm"; h.extent = .through; k = .hole(h) } }
        await settle(editor)
        if case let .hole(h)? = editor.commandFeature?.kind {
            check("hole: two positions from clicks", h.points.count == 2, "\(h.points.count)")
            if case let .faceOffset(_, x, y)? = h.points.first {
                check("hole: click gives distances from the face corner", abs((Double(x) ?? 0) - 30) <= 1 && abs((Double(y) ?? 0) - 30) <= 1, "\(x) \(y)")
            } else {
                check("hole: click gives distances from the face corner", false, "\(h.points)")
            }
        }
        // Arrows on the face: dragging the first position's arrows moves it 20 mm along X, then 10 mm along Y.
        let handles = editor.holeHandles
        check("hole: arrows at each position", handles.count == 2, "\(handles.count)")
        if let start = handles.first {
            let len = editor.arrowLength
            for (axis, delta) in [(0, 20.0), (1, 10.0)] {
                guard let h = editor.holeHandles.first, let a = editor.camera.project(h.center + h.axes[axis] * len),
                      let b = editor.camera.project(h.center + h.axes[axis] * (len + delta)),
                      let v = editor.holeOffset(h, axis: axis, from: a, to: b) else { continue }
                editor.setHoleOffset(h.index, axis: axis, v)
            }
            await settle(editor)
            let moved = editor.holeHandles.first?.offsets ?? []
            let dx = (moved.first ?? 0) - start.offsets[0], dy = (moved.last ?? 0) - start.offsets[1]
            check("hole: arrows move the position", abs(dx - 20) <= 1 && abs(dy - 10) <= 1, "\(start.offsets) → \(moved)")
        }
        // Typed exactly: first hole at X 30, second at X 70, both Y 30.
        editor.updateCommandFeature { k in
            guard case var .hole(h) = k else { return }
            for i in h.points.indices { if case let .faceOffset(r, _, _) = h.points[i] { h.points[i] = .faceOffset(r, x: i == 0 ? "30" : "70", y: "30") } }
            k = .hole(h)
        }
        await snap("m01-hole")
        let holeId = editor.command?.featureId
        editor.commitCommand()
        await settle(editor)
        check("hole: material removed", abs(volume(editor, plateF.id) - (full - 2 * .pi * 16 * 20)) < 1, "\(volume(editor, plateF.id))")

        // Pattern of the hole feature: second row 20 mm further in Y.
        editor.timelineSelection = holeId
        editor.beginCommand(.rectPattern)
        editor.updateCommandFeature { k in if case var .pattern(p) = k { p.direction = .y; p.count = "2"; p.spacing = "20 mm"; k = .pattern(p) } }
        await settle(editor)
        await snap("m02-pattern")
        editor.commitCommand()
        await settle(editor)
        editor.timelineSelection = nil
        check("pattern: holes repeated", abs(volume(editor, plateF.id) - (full - 4 * .pi * 16 * 20)) < 1, "\(volume(editor, plateF.id))")

        // Fillet and chamfer on the plate's top front edge: an arrow on the edge, dragged 2 mm into the corner
        // (measured on the rounded/chamfered surface) gives radius/distance 1 → 3 mm (scale 0.414 / 0.707 at 90°).
        for kind in [CommandKind.fillet, .chamfer] {
            editor.beginCommand(kind)
            if let body = editor.stateBeforeCommand.bodies[plateF.id],
               let idx = body.edgeInfos.compactMap({ $0 }).first(where: { simd_distance($0.midpoint, Vec3(50, 0, 20)) < 1e-6 })?.index,
               let ref = body.edgeRef(idx) {
                editor.updateCommandFeature { k in
                    if case var .fillet(f) = k { f.edges = [BodyEdgeRef(body: plateF.id, edge: ref)]; k = .fillet(f) }
                    if case var .chamfer(c) = k { c.edges = [BodyEdgeRef(body: plateF.id, edge: ref)]; k = .chamfer(c) }
                }
            }
            await settle(editor)
            let name = kind == .fillet ? "fillet" : "chamfer"
            guard let h = editor.edgeHandle else { check("\(name): arrow on the edge", false); editor.cancelCommand(); continue }
            let out = simd_normalize(Vec3(0, -1, 1))
            check("\(name): arrow on the edge", simd_dot(h.direction, out) > 0.999 && abs(h.value - 1) < 1e-9, "\(h.direction) \(h.value)")
            let len = editor.arrowLength, depth = 2 * h.scale
            if let a = editor.camera.project(h.center + h.direction * len),
               let b = editor.camera.project(h.center + h.direction * (len - depth)),
               let v = editor.edgeValue(h, from: a, to: b) {
                editor.setEdgeValue(v)
            }
            await settle(editor)
            check("\(name): arrow changes the size", abs((editor.edgeHandle?.value ?? 0) - 3) < 1e-6 && editor.state.errors.isEmpty,
                  "\(editor.edgeHandle?.value ?? 0) \(editor.state.errors.values)")
            await snap(kind == .fillet ? "m02-fillet" : "m02-chamfer")
            editor.cancelCommand()
            await settle(editor)
        }

        // Offset plane from the top face, then a sketch on it by clicking the plane.
        editor.beginPlane(.offset)
        await click(editor, Vec3(95, 5, 20))
        editor.updateCommandFeature { k in if case var .plane(p) = k { p.distance = "30 mm"; k = .plane(p) } }
        await settle(editor)
        await snap("m03-plane")
        let planeId = editor.command?.featureId
        editor.commitCommand()
        await settle(editor)
        let plane = planeId.flatMap { editor.state.planes[$0] }
        check("plane: 30 mm above the top face", plane.map { abs($0.origin.z - 50) < 1e-6 } ?? false, "\(String(describing: plane))")
        editor.selection = []
        await click(editor, Vec3(75, 30, 50))
        check("plane: selectable in the viewport", editor.selection.first.map { if case .originPlane(.construction) = $0 { return true }; return false } ?? false,
              "\(editor.selection)")
        editor.beginCommand(.sketchPlane)
        await settle(editor)
        check("plane: sketch on it", editor.sketchId != nil && abs((editor.activePlane?.origin.z ?? 0) - 50) < 1e-6)
        // A sketch grid must lie in front of the face/plane it sits on, not behind it.
        var sketchGrid = SceneBuilder(editor: editor, scale: 2)
        sketchGrid.buildGrid()
        let gridBatches = sketchGrid.scene.lines.filter { $0.instances.count > 2 }   // not the two axes
        check("plane: sketch grid not hidden by the face", !gridBatches.isEmpty && gridBatches.allSatisfy { $0.depthBias > 0 },
              "\(gridBatches.map(\.depthBias))")
        editor.finishSketch()
        await settle(editor)

        // Thread on the bolt: back to the 3D view, click its side facing the camera.
        editor.cameraAnimation = nil
        editor.camera.orientation = Camera.homeOrientation
        editor.camera.target = SIMD3<Float>(75, 30, 5)
        editor.camera.distance = 330
        await settle(editor)
        let eye = editor.camera.eye
        var toEye = Vec3(Double(eye.x) - 150, Double(eye.y) - 30, 0)
        toEye = simd_normalize(toEye)
        editor.beginCommand(.thread)
        await click(editor, Vec3(150, 30, 6) + toEye * 4)
        if case let .thread(t)? = editor.commandFeature?.kind { check("thread: cylinder picked", t.faces.count == 1, "\(t.faces.count)") }
        await snap("m04-thread")
        editor.commitCommand()
        await settle(editor)
        let bolt = volume(editor, boltF.id)
        check("thread: modeled M8", bolt < .pi * 16 * 12 - 40 && bolt > .pi * 16 * 12 - 100, "\(bolt)")

        // Thread in a hole (crashed before 2.0.1): pick the hole wall, then again after the preview changed the faces.
        editor.cameraAnimation = nil
        editor.camera.orientation = Camera.homeOrientation
        editor.camera.target = SIMD3<Float>(30, 30, 10)
        editor.camera.distance = 120
        await settle(editor)
        editor.beginCommand(.thread)
        // Looking down into the hole, the wall on the far side is visible.
        let wall = Vec3(30, 30, 18) - toEye * 4
        await click(editor, wall)
        if case let .thread(t)? = editor.commandFeature?.kind { check("thread in hole: hole wall picked", t.faces.count == 1, "\(t.faces.count)") }
        await click(editor, wall)
        for _ in 0..<5 { editor.updateHover(at: editor.camera.project(wall) ?? .zero); await settle(editor) }
        check("thread in hole: second click and hover on the threaded preview survive", editor.command?.kind == .thread)
        if case let .thread(t)? = editor.commandFeature?.kind, t.faces.isEmpty { await click(editor, wall) }
        editor.commitCommand()
        await settle(editor)
        check("thread in hole: no errors", editor.state.errors.isEmpty, "\(editor.state.errors.values)")
        editor.undo()
        await settle(editor)
        editor.camera.target = SIMD3<Float>(75, 30, 5)
        editor.camera.distance = 330
        await settle(editor)

        // Copy the bolt 30 mm to the right.
        editor.selection = [.body(boltF.id)]
        editor.beginCommand(.move)
        editor.updateCommandFeature { k in if case var .move(m) = k { m.dx = "30 mm"; m.copy = true; k = .move(m) } }
        await settle(editor)
        await snap("m05-move")
        editor.commitCommand()
        await settle(editor)
        check("move: copy added", editor.state.bodyOrder.count == 3, "\(editor.state.bodyOrder.count)")

        // Combine: join the copy into the bolt (target clicked, tool set).
        let copy = editor.state.bodyOrder.last!
        editor.selection = []
        editor.beginCommand(.combine)
        await click(editor, Vec3(150, 30, 12))
        editor.updateCommandFeature { k in if case var .combine(c) = k { c.tools = [copy]; c.keepTools = false; k = .combine(c) } }
        await settle(editor)
        await snap("m06-combine")
        editor.commitCommand()
        await settle(editor)
        check("combine: two bodies left", editor.state.bodyOrder.count == 2, "\(editor.state.bodyOrder.count)")

        // Mirror the bolt across the YZ plane.
        editor.selection = [.body(boltF.id)]
        editor.beginCommand(.mirror)
        editor.updateCommandFeature { k in if case var .pattern(p) = k { p.plane = .yz; k = .pattern(p) } }
        await settle(editor)
        editor.commitCommand()
        await settle(editor)
        check("mirror: bolt mirrored", editor.state.bodyOrder.count == 3, "\(editor.state.bodyOrder.count)")
        check("no feature errors", editor.state.errors.isEmpty, "\(editor.state.errors.values)")
        editor.undo()
        await settle(editor)
        check("undo removes the mirror", editor.state.bodyOrder.count == 2)

        // Editing a hole from the timeline reopens its dialog with the values.
        if let holeId {
            editor.editFeature(holeId)
            await settle(editor)
            if case let .hole(h)? = editor.commandFeature?.kind { check("edit: hole dialog reopens", h.diameter == "8 mm" && editor.command?.kind == .hole) }
            editor.cancelCommand()
        }
        await snap("m07-result")

        // Measure: the two Ø8 holes 40 mm apart (centres at x = 30 and 70).
        editor.cameraAnimation = nil
        editor.camera.orientation = Camera.lookOrientation(direction: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        editor.camera.target = SIMD3<Float>(50, 30, 20)
        editor.camera.distance = 200
        await settle(editor)
        editor.toggleMeasure()
        await click(editor, Vec3(30 + 4, 30, 20))
        await click(editor, Vec3(70 + 4, 30, 20))
        let rows = editor.measureResult?.rows ?? []
        check("measure: two hole rims picked", editor.measurePicks.count == 2, "\(editor.measurePicks)")
        check("measure: hole spacing 40 mm", rows.contains { $0.label == String(localized: "Achsabstand") && abs($0.value - 40) < 1e-3 }, "\(rows)")
        await snap("m08-measure")
        editor.escape()
        check("measure: Esc ends", !editor.measuring)

        // Section through the hole row: cut faces are drawn, picking ignores the removed half.
        editor.camera.orientation = Camera.homeOrientation
        editor.camera.target = SIMD3<Float>(50, 30, 10)
        editor.camera.distance = 260
        editor.toggleSection()
        editor.section?.offset = 30
        await settle(editor)
        check("section: on through the holes", editor.section?.axis == 1 && editor.section?.offset == 30)
        editor.updateHover(at: editor.camera.project(Vec3(50, 5, 20)) ?? .zero)
        check("section: removed half is not pickable", editor.hover == nil || {
            if case let .face(b, i)? = editor.hover, let c = editor.state.bodies[b]?.faceInfo(at: i)?.centroid { return c.y >= 29 }
            return true
        }(), "\(String(describing: editor.hover))")
        await snap("m09-section")
        editor.toggleSection()

        // Assembly: the bolt becomes a component, turns 90° about the Y axis, the view explodes.
        editor.selection = [.body(boltF.id)]
        editor.createComponent()
        await settle(editor)
        check("component: created from the selection", editor.doc.components.first?.bodies == [boltF.id], "\(editor.doc.components)")
        editor.renameComponent(editor.doc.components[0].id, to: "Bolzen M8")
        editor.selection = [.body(boltF.id)]
        editor.beginCommand(.joint)
        check("joint: component preselected, axis input active", editor.command?.activeInput == 1)
        editor.updateCommandFeature { k in if case var .joint(j) = k { j.axis = .y; j.value = "90"; k = .joint(j) } }
        await settle(editor)
        await snap("m10-joint")
        editor.commitCommand()
        await settle(editor)
        let turned = editor.state.bodies[boltF.id]?.shape.boundingBox
        check("joint: bolt turned onto its side", turned.map { abs(($0.max.x - $0.min.x) - 12) < 0.5 } ?? false, "\(String(describing: turned))")
        editor.showExplode = true
        editor.explode = 0.8
        await settle(editor)
        check("explode: offsets for every visible body", editor.explodeOffsets().count == editor.state.bodyOrder.filter { editor.doc.isBodyVisible($0) }.count)
        await snap("m11-explode")
        editor.explode = 0
        editor.showExplode = false
        let names = editor.drawing.input(editor).parts.map(\.name)
        check("parts list: component name", names.contains("Bolzen M8"), "\(names)")
    }
}
