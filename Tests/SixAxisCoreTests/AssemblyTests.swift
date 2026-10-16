import XCTest
import simd
@testable import SixAxisCore

final class AssemblyTests: XCTestCase {
    /// Box body from a rectangle at `origin` (w × d), extruded `h`; width may be a parameter.
    func box(_ doc: inout CADDocument, _ name: String, w: String, d: Double, h: Double, at origin: Vec2 = .zero, z: Double = 0) -> UUID {
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(origin), sk.addPoint(origin + Vec2(10, 0)), sk.addPoint(origin + Vec2(10, d)), sk.addPoint(origin + Vec2(0, d))]
        sk.points[sk.pointIndex(p[0])!].fixed = true
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.horizontal(line: l[0])); sk.addConstraint(.vertical(line: l[1]))
        sk.addConstraint(.horizontal(line: l[2])); sk.addConstraint(.vertical(line: l[3]))
        sk.addConstraint(.length(line: l[0], value: w))
        sk.addConstraint(.length(line: l[1], value: "\(d) mm"))
        let s = Feature(name: name, kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: origin + Vec2(1, d / 2), anchor: nil)]
        ex.distance = "\(h) mm"
        ex.operation = .newBody
        let e = Feature(name: name, kind: .extrude(ex))
        doc.features += [s, e]
        return e.id
    }

    func build(_ doc: CADDocument) -> ModelState {
        let s = ModelBuilder().build(doc)
        XCTAssertTrue(s.errors.isEmpty, "\(s.errors.values)")
        return s
    }

    func testCopiesAreInstancesAndFollowTheOriginal() {
        var doc = CADDocument()
        doc.parameters = [UserParameter(name: "b", expression: "400 mm")]
        let shelf = box(&doc, "Boden", w: "b", d: 300, h: 19)
        doc.components = [ComponentDef(name: "Boden", bodies: [shelf])]
        var m = MoveFeature()
        m.bodies = [shelf]
        m.dz = "300 mm"
        m.copy = true
        doc.features.append(Feature(name: "Kopie", kind: .move(m)))
        var p = PatternFeature()
        p.bodies = [shelf]
        p.direction = .z
        p.count = "3"
        p.spacing = "100 mm"
        doc.features.append(Feature(name: "Muster", kind: .pattern(p)))
        var state = build(doc)
        XCTAssertEqual(state.bodyOrder.count, 4)
        XCTAssertEqual(state.instanceCounts(doc.components)[doc.components[0].id], 4)
        XCTAssertTrue(state.bodyOrder.allSatisfy { state.component(of: $0, in: doc.components)?.name == "Boden" })
        doc.parameters[0].expression = "600 mm"
        state = build(doc)
        for b in state.orderedBodies {
            let bb = b.shape.boundingBox!
            XCTAssertEqual(bb.max.x - bb.min.x, 600, accuracy: 1e-6, "copies follow the original's width")
        }
    }

    func testRevoluteSliderAndRigidJoints() {
        var doc = CADDocument()
        let door = box(&doc, "Tür", w: "400 mm", d: 19, h: 600)
        let knob = box(&doc, "Griff", w: "20 mm", d: 20, h: 40, at: Vec2(350, -20), z: 0)
        let drawer = box(&doc, "Schub", w: "300 mm", d: 400, h: 100, at: Vec2(0, 100))
        doc.components = [ComponentDef(name: "Tür", bodies: [door]), ComponentDef(name: "Griff", bodies: [knob]),
                          ComponentDef(name: "Schubkasten", bodies: [drawer])]
        var fix = JointFeature()
        fix.kind = .rigid
        fix.body = knob
        fix.parent = door
        // Door turns 90° about its hinge edge (vertical line through the origin).
        var hinge = JointFeature()
        hinge.kind = .revolute
        hinge.body = door
        hinge.axis = .z
        hinge.value = "90"
        var slide = JointFeature()
        slide.kind = .slider
        slide.body = drawer
        slide.axis = .y
        slide.value = "-250 mm"
        doc.features += [Feature(name: "Fest", kind: .joint(fix)), Feature(name: "Scharnier", kind: .joint(hinge)),
                         Feature(name: "Auszug", kind: .joint(slide))]
        let state = build(doc)
        let d = state.bodies[door]!.shape.boundingBox!
        XCTAssertEqual(d.max.y, 400, accuracy: 1e-6, "door swung open")
        XCTAssertEqual(d.min.x, -19, accuracy: 1e-6)
        let k = state.bodies[knob]!.shape.boundingBox!
        XCTAssertGreaterThan(k.min.y, 300, "the knob moved with the door")
        let s = state.bodies[drawer]!.shape.boundingBox!
        XCTAssertEqual(s.min.y, -150, accuracy: 1e-6, "drawer pulled out")
    }

    func testFormatVersion6RoundTrip() throws {
        var doc = CADDocument()
        let b = box(&doc, "A", w: "50 mm", d: 50, h: 10)
        doc.components = [ComponentDef(name: "A", bodies: [b])]
        var j = JointFeature()
        j.body = b
        j.axis = .x
        doc.features.append(Feature(name: "G", kind: .joint(j)))
        let back = try CADDocument.decode(try doc.encoded())
        XCTAssertEqual(back, doc)
        XCTAssertEqual(CADDocument.currentFormatVersion, 6)
    }

    func testExplodeOffsetsMoveInstancesApart() {
        var doc = CADDocument()
        let a = box(&doc, "A", w: "100 mm", d: 100, h: 10)
        let b = box(&doc, "B", w: "100 mm", d: 100, h: 10, at: Vec2(200, 0))
        doc.components = [ComponentDef(name: "A", bodies: [a])]
        let state = build(doc)
        let off = state.explodeOffsets([a, b], components: doc.components, factor: 1)
        // Centres at x = 50 and 250, middle 150: each moves by its distance from the middle.
        XCTAssertEqual(off[a]!.x, -100, accuracy: 1e-6)
        XCTAssertEqual(off[b]!.x, 100, accuracy: 1e-6)
        XCTAssertTrue(state.explodeOffsets([a, b], components: doc.components, factor: 0).isEmpty)
    }
}
