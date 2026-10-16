import XCTest
import simd
@testable import SixAxisCore

/// Drawings show threads per ISO 6410 (no helix geometry) and dimension hidden holes.
final class DrawingThreadTests: XCTestCase {
    /// Plate 100 × 60 × 20 with an M6 tapped hole, repeated 3× along X.
    func threadedPlate(modeled: Bool) -> CADDocument {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(100, 0)), sk.addPoint(Vec2(100, 60)), sk.addPoint(Vec2(0, 60))]
        for i in 0..<4 { sk.addLine(c[i], c[(i + 1) % 4]) }
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2(50, 30))]
        ex.distance = "20 mm"
        let e = Feature(name: "Platte", kind: .extrude(ex))
        doc.features = [s, e]
        let body = ModelBuilder().build(doc).bodies[e.id]!
        let top = body.faceInfos.compactMap { $0 }.max { $0.centroid.z < $1.centroid.z }!.index
        var h = HoleFeature()
        h.points = [.face(BodyFaceRef(body: e.id, face: body.faceRef(top)!), position: Vec3(20, 30, 20))]
        h.thread = "M6"
        h.threadModeled = modeled
        h.depth = "12 mm"
        let hole = Feature(name: "B", kind: .hole(h))
        var p = PatternFeature()
        p.features = [hole.id]
        p.direction = .x
        p.count = "3"
        p.spacing = "30 mm"
        doc.features += [hole, Feature(name: "M", kind: .pattern(p))]
        return doc
    }

    func input(_ doc: CADDocument) -> DrawingGenerator.Input {
        let state = ModelBuilder(markThreads: true).build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        let parts = state.orderedBodies.map { b in
            DrawingGenerator.Part(name: "Platte", shape: b.shape, threads: state.threadMarks.filter { $0.body == b.id })
        }
        return DrawingGenerator.Input(parts: parts, settings: DrawingSettings(), fallbackTitle: "T")
    }

    func testModeledThreadsAreDrawnAsMarksWithCallout() {
        let doc = threadedPlate(modeled: true)
        // The real model has grooves; the drawing model has none but three marks.
        let real = ModelBuilder().build(doc).orderedBodies[0].shape
        let marked = ModelBuilder(markThreads: true).build(doc)
        XCTAssertEqual(marked.threadMarks.count, 3)
        XCTAssertGreaterThan(marked.orderedBodies[0].shape.volume, real.volume + 5)
        let start = Date()
        let page = DrawingGenerator().generate(input(doc))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let texts = page.texts.map(\.text)
        XCTAssertTrue(texts.contains("3× M6"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("Ø5") }, "tap drill is not labelled as a plain hole")
    }

    func testHiddenHolesAreDimensioned() throws {
        // Blind hole drilled from the bottom: only hidden in the top view.
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let c = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(80, 0)), sk.addPoint(Vec2(80, 50)), sk.addPoint(Vec2(0, 50))]
        for i in 0..<4 { sk.addLine(c[i], c[(i + 1) % 4]) }
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2(40, 25))]
        ex.distance = "20 mm"
        let e = Feature(name: "Platte", kind: .extrude(ex))
        var pts = Sketch(plane: .xy)
        let p = pts.addPoint(Vec2(30, 25))
        let ps = Feature(name: "P", kind: .sketch(pts))
        var h = HoleFeature()
        h.points = [.sketchPoint(sketch: ps.id, point: p)]
        h.flip = true
        h.diameter = "8 mm"
        h.depth = "10 mm"
        doc.features = [s, e, ps, Feature(name: "B", kind: .hole(h))]
        let page = DrawingGenerator().generate(input(doc))
        XCTAssertTrue(page.texts.map(\.text).contains("Ø8"), "\(page.texts.map(\.text))")
    }
}
