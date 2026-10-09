import simd
import XCTest
@testable import SixAxisCore

final class SplineTests: XCTestCase {
    func testBezierPiecesPassThroughFitPoints() {
        let pts = [Vec2(0, 0), Vec2(10, 5), Vec2(20, 0), Vec2(30, 8)]
        let pieces = Spline.beziers(pts, closed: false)
        XCTAssertEqual(pieces.count, 3)
        for (i, p) in pieces.enumerated() {
            XCTAssertEqual(simd_distance(p.0, pts[i]), 0, accuracy: 1e-12)
            XCTAssertEqual(simd_distance(p.3, pts[i + 1]), 0, accuracy: 1e-12)
        }
        // Tangent continuity at inner points: incoming and outgoing handles are collinear.
        for i in 0..<(pieces.count - 1) {
            let a = simd_normalize(pieces[i].3 - pieces[i].2), b = simd_normalize(pieces[i + 1].1 - pieces[i + 1].0)
            XCTAssertEqual(simd_dot(a, b), 1, accuracy: 1e-9)
        }
        XCTAssertEqual(Spline.beziers(pts, closed: true).count, 4)
    }

    /// U-shape of three lines whose open side is closed by a spline (the "attach a spline to a rectangle" case).
    func testSplineClosesProfileWithLines() throws {
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 40)), sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(60, 0)), sk.addPoint(Vec2(60, 40))]
        sk.addLine(p[0], p[1]); sk.addLine(p[1], p[2]); sk.addLine(p[2], p[3])
        let mid = sk.addPoint(Vec2(30, 55))
        sk.addSpline([p[3], mid, p[0]])
        var doc = CADDocument()
        let s = Feature(name: "S", kind: .sketch(sk))
        doc.features = [s]
        let sb = ModelBuilder().build(doc).sketches[s.id]!
        XCTAssertEqual(sb.regions.count, 1)
        // Bulging spline: area larger than the 60 × 40 rectangle.
        XCTAssertGreaterThan(sb.regions[0].area, 2400)
        var ex = ExtrudeFeature()
        ex.profiles = [sb.profileRef(sb.regions[0])]
        ex.distance = "10 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features.append(e)
        let state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        XCTAssertEqual(state.bodies[e.id]?.shape.volume ?? 0, sb.regions[0].area * 10, accuracy: 1)
    }

    func testClosedSplineIsARegion() {
        var sk = Sketch(plane: .xy)
        let ids = [Vec2(0, 0), Vec2(40, -5), Vec2(50, 30), Vec2(10, 35)].map { sk.addPoint($0) }
        sk.addSpline(ids, closed: true)
        var doc = CADDocument()
        let s = Feature(name: "S", kind: .sketch(sk))
        doc.features = [s]
        let sb = ModelBuilder().build(doc).sketches[s.id]!
        XCTAssertEqual(sb.regions.count, 1)
        XCTAssertGreaterThan(sb.regions[0].area, 1000)
    }

    func testMergeClosesSplineAndPointOnSplineSolves() {
        var sk = Sketch(plane: .xy)
        let ids = [Vec2(0, 0), Vec2(20, 10), Vec2(40, 0), Vec2(0.5, 0.5)].map { sk.addPoint($0) }
        let c = sk.addSpline(ids)
        sk.merge(point: ids[3], into: ids[0])
        XCTAssertEqual(sk.curve(c)?.geometry, .spline(points: Array(ids.prefix(3)), closed: true))
        // A free point constrained onto the spline ends up on it.
        let q = sk.addPoint(Vec2(20, 20))
        sk.addConstraint(.pointOnCurve(point: q, curve: c))
        let r = SketchSolver().solve(&sk)
        XCTAssertTrue(r.converged)
        let poly = sk.polyline(sk.curve(c)!, segments: 400)
        let d = poly.indices.dropLast().map { k -> Double in
            let a = poly[k], v = poly[k + 1] - a
            let t = max(0, min(1, simd_dot(sk.point(q)! - a, v) / simd_length_squared(v)))
            return simd_distance(sk.point(q)!, a + t * v)
        }.min()!
        XCTAssertLessThan(d, 0.05)
    }

    func testSplineDocumentRoundTripAndVersion() throws {
        var sk = Sketch(plane: .xy)
        sk.addSpline([sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(5, 5))])
        var doc = CADDocument()
        doc.features = [Feature(name: "S", kind: .sketch(sk))]
        let back = try CADDocument.decode(doc.encoded())
        XCTAssertEqual(back, doc)
        let json = try JSONSerialization.jsonObject(with: doc.encoded()) as! [String: Any]
        XCTAssertEqual(json["formatVersion"] as? Int, 3)
    }

    /// A body with a spline edge projects into the drawing (curved outline as polyline) and gets a drawing.
    func testSplineBodyInDrawing() throws {
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 40)), sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(60, 0)), sk.addPoint(Vec2(60, 40))]
        sk.addLine(p[0], p[1]); sk.addLine(p[1], p[2]); sk.addLine(p[2], p[3])
        sk.addSpline([p[3], sk.addPoint(Vec2(30, 55)), p[0]])
        var doc = CADDocument()
        let s = Feature(name: "S", kind: .sketch(sk))
        doc.features = [s]
        let sb = ModelBuilder().build(doc).sketches[s.id]!
        var ex = ExtrudeFeature()
        ex.profiles = [sb.profileRef(sb.regions[0])]
        ex.distance = "10 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features.append(e)
        let shape = try XCTUnwrap(ModelBuilder().build(doc).bodies[e.id]?.shape)
        let top = try shape.project(viewDir: Vec3(0, 0, 1), xDir: Vec3(1, 0, 0), deflection: 0.05)
        let b = try XCTUnwrap(top.bounds)
        XCTAssertEqual(b.max.y - b.min.y, 55, accuracy: 0.5, "spline apex appears in the top view")
        XCTAssertTrue(top.polylines.contains { $0.points.count > 5 }, "curved outline as polyline")
        let page = DrawingGenerator().generate(.init(shapes: [shape], settings: DrawingSettings(), fallbackTitle: "Spline"))
        XCTAssertFalse(page.lines.isEmpty)
    }
}
