import AppKit
import Foundation
import simd
import SixAxisCore

/// The milling workspace through the real pick pipeline: SIXAXIS_CAM_TEST=1 (CHECK lines, snapshots).
@MainActor
enum CAMChecks {
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { SketchChecks.check(name, ok, detail()) }

    static func run(_ editor: Editor, snapshots: URL?) async {
        func snap(_ name: String) async { if let snapshots { await DemoScript.snap(editor, name, snapshots) } }
        let settle = ModellingChecks.settle
        let click = ModellingChecks.click
        editor.newDocument()
        // Plate 100 × 60 × 19 with a 40 × 30 × 5 pocket and two Ø8 holes.
        var plate = Sketch(plane: .xy)
        let c = [plate.addPoint(Vec2(0, 0)), plate.addPoint(Vec2(100, 0)), plate.addPoint(Vec2(100, 60)), plate.addPoint(Vec2(0, 60))]
        for i in 0..<4 { plate.addLine(c[i], c[(i + 1) % 4]) }
        plate.addCircle(center: plate.addPoint(Vec2(75, 15)), radius: 4)
        plate.addCircle(center: plate.addPoint(Vec2(75, 45)), radius: 4)
        var pocket = Sketch(plane: .xy)
        let q = [pocket.addPoint(Vec2(10, 15)), pocket.addPoint(Vec2(50, 15)), pocket.addPoint(Vec2(50, 45)), pocket.addPoint(Vec2(10, 45))]
        for i in 0..<4 { pocket.addLine(q[i], q[(i + 1) % 4]) }
        let s1 = Feature(name: "Platte", kind: .sketch(plate)), s2 = Feature(name: "Tasche", kind: .sketch(pocket))
        var e1 = ExtrudeFeature(); e1.profiles = [ProfileRef(sketch: s1.id, sample: Vec2(30, 5))]; e1.distance = "19 mm"
        var e2 = ExtrudeFeature(); e2.profiles = [ProfileRef(sketch: s2.id, sample: Vec2(30, 30))]; e2.distance = "5 mm"
        e2.operation = .cut
        let body = Feature(name: "Platte", kind: .extrude(e1))
        // The pocket is cut from the top: its sketch sits at z = 19 via a translated copy of the plane.
        var e2f = Feature(name: "Tasche", kind: .extrude(e2))
        e2.extent = .oneSide
        e2.distance = "-5 mm"
        e2f.kind = .extrude(e2)
        var s2top = s2
        if case var .sketch(sk) = s2top.kind {
            var cp = ConstructionPlaneFeature(); cp.plane = .xy; cp.distance = "19 mm"
            let pl = Feature(name: "Oben", kind: .plane(cp))
            sk.plane = .construction(pl.id)
            s2top.kind = .sketch(sk)
            editor.commit { $0.features = [s1, body, pl, s2top, e2f]; $0.hiddenSketches = [s1.id, s2.id, pl.id] }
        }
        await settle(editor)
        check("cam: model built", editor.state.errors.isEmpty && editor.state.bodyOrder.count == 1, "\(editor.state.errors.values)")
        editor.cameraAnimation = nil
        editor.camera.orientation = Camera.homeOrientation
        editor.camera.target = SIMD3<Float>(50, 30, 10)
        editor.camera.distance = 300
        editor.setWorkspace(.cam)
        await settle(editor)
        check("cam: workspace with defaults", editor.workspace == .cam && editor.doc.cam?.tools.count == 6)

        // Contour: select the top face, then "Kontur".
        await click(editor, Vec3(90, 55, 19))
        check("cam: top face selectable", editor.selection.count == 1, "\(editor.selection)")
        editor.addOperation(.contour)
        await settle(editor)
        check("cam: contour takes the selected face", editor.editedOperation?.faces.count == 1)
        // Pocket: start empty, click the pocket floor.
        editor.editOperation(nil)
        editor.addOperation(.pocket)
        await click(editor, Vec3(30, 30, 14))
        check("cam: pocket floor picked", editor.editedOperation?.faces.count == 1, "\(String(describing: editor.editedOperation))")
        await snap("c01-pocket")
        // Drilling: the top face stands for all holes of the part.
        editor.editOperation(nil)
        editor.addOperation(.drill)
        await click(editor, Vec3(90, 55, 19))
        if let id = editor.camEdit {
            let drill8 = editor.cam.tools.first { $0.kind == .drill && abs($0.diameter - 8) < 0.01 }!.id
            editor.updateOperation(id) { $0.tool = drill8 }
        }
        editor.editOperation(nil)
        // Wait for the background planner.
        for _ in 0..<100 where editor.camPlanning { await ModellingChecks.pause(0.05) }
        await settle(editor)
        let r = editor.camResult
        check("cam: three operations planned", r?.paths.count == 3, "\(r?.paths.count ?? -1) \(r?.warnings ?? [])")
        check("cam: no warnings", r?.warnings.isEmpty == true, "\(r?.warnings ?? [])")
        await snap("c02-toolpaths")
        if let r, let setup = editor.doc.cam {
            let g = GCodeWriter.write(r, setup: setup, title: "Test")
            check("cam: G-code with three sections", g.contains("(Kontur1)") && g.contains("(Tasche1)") && g.contains("(Bohren1)"))
            check("cam: tool change pause for GRBL", g.contains("M0"))
            if let dir = snapshots { try? g.write(to: dir.appendingPathComponent("test.nc"), atomically: true, encoding: .ascii) }
        }
        editor.showCAMSetup = true
        await snap("c03-setup")
        editor.showCAMSetup = false
        editor.undo()
        await settle(editor)
        check("cam: undo removes the last change", editor.cam.operations.count == 3)
        editor.setWorkspace(.design)
        check("cam: back to construction", editor.workspace == .design)
    }
}
