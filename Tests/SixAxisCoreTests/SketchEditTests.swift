import simd
import XCTest
@testable import SixAxisCore

final class SketchEditTests: XCTestCase {
    /// Rectangle 0,0 – W,H with horizontal/vertical constraints and width/height dimensions.
    func rectangle(_ w: Double = 60, _ h: Double = 40) -> (Sketch, [Int], [Int]) {
        var sk = Sketch(plane: .xy)
        let p = [Vec2(0, 0), Vec2(w, 0), Vec2(w, h), Vec2(0, h)].map { sk.addPoint($0) }
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.coincident(Sketch.originId, p[0]))
        sk.merge(point: p[0], into: Sketch.originId)
        let pts = [Sketch.originId, p[1], p[2], p[3]]
        sk.addConstraint(.horizontal(line: l[0])); sk.addConstraint(.vertical(line: l[1]))
        sk.addConstraint(.horizontal(line: l[2])); sk.addConstraint(.vertical(line: l[3]))
        sk.addConstraint(.length(line: l[0], value: "\(w) mm"))
        sk.addConstraint(.length(line: l[1], value: "\(h) mm"))
        return (sk, pts, l)
    }

    func regionArea(_ sk: Sketch) -> [Double] {
        var doc = CADDocument()
        let f = Feature(name: "S", kind: .sketch(sk))
        doc.features = [f]
        return ModelBuilder().build(doc).sketches[f.id]!.regions.map(\.area)
    }

    func testFilletRoundsCornerAndKeepsDimensions() {
        var (sk, pts, _) = rectangle()
        XCTAssertNotNil(SketchEdit.fillet(&sk, corner: pts[2], radius: 10, radiusText: "10 mm"))
        let r = SketchSolver().solve(&sk)
        XCTAssertTrue(r.converged)
        XCTAssertEqual(r.degreesOfFreedom, 0, "still fully constrained")
        let area = regionArea(sk)
        XCTAssertEqual(area.count, 1)
        XCTAssertEqual(area[0], 60 * 40 - 100 * (1 - .pi / 4), accuracy: 0.01)
        // Virtual corner still at 60/40.
        XCTAssertEqual(simd_distance(sk.point(pts[2])!, Vec2(60, 40)), 0, accuracy: 1e-6)
    }

    func testFilletRadiusIsAParameterAndDimensionsStillDrive() {
        var (sk, pts, _) = rectangle()
        SketchEdit.fillet(&sk, corner: pts[1], radius: 5, radiusText: "r")
        var doc = CADDocument()
        doc.parameters = [UserParameter(name: "r", expression: "12 mm")]
        doc.features = [Feature(name: "S", kind: .sketch(sk))]
        let sb = ModelBuilder().build(doc).sketches[doc.features[0].id]!
        XCTAssertTrue(sb.solve.converged)
        XCTAssertEqual(sb.regions.first?.area ?? 0, 60 * 40 - 144 * (1 - .pi / 4), accuracy: 0.01)
        // Width dimension still 60 after rounding (re-attached to the virtual corner).
        doc.parameters[0].expression = "12 mm"
        if case var .sketch(s2) = doc.features[0].kind {
            if let i = s2.constraints.firstIndex(where: { if case .distance(_, _, "60.0 mm") = $0.kind { return true }; return false }) {
                s2.constraints[i].kind = s2.constraints[i].kind.withValue("80 mm")
            } else { XCTFail("width dimension not re-attached") }
            doc.features[0].kind = .sketch(s2)
        }
        let sb2 = ModelBuilder().build(doc).sketches[doc.features[0].id]!
        XCTAssertEqual(sb2.regions.first?.area ?? 0, 80 * 40 - 144 * (1 - .pi / 4), accuracy: 0.01)
    }

    func testChamferCutsCorner() {
        var (sk, pts, _) = rectangle()
        XCTAssertNotNil(SketchEdit.chamfer(&sk, corner: pts[3], distance: 8, distanceText: "8 mm"))
        let r = SketchSolver().solve(&sk)
        XCTAssertTrue(r.converged)
        XCTAssertEqual(r.degreesOfFreedom, 0)
        XCTAssertEqual(regionArea(sk).first ?? 0, 60 * 40 - 32, accuracy: 0.01)
    }

    func testRejectsInvalidCorners() {
        var (sk, pts, _) = rectangle()
        XCTAssertNil(SketchEdit.fillet(&sk, corner: pts[2], radius: 50, radiusText: "50"), "radius longer than the side")
        var line = Sketch(plane: .xy)
        let a = line.addPoint(Vec2(0, 0)), b = line.addPoint(Vec2(10, 0)), c = line.addPoint(Vec2(20, 0))
        line.addLine(a, b); line.addLine(b, c)
        XCTAssertNil(SketchEdit.fillet(&line, corner: b, radius: 1, radiusText: "1"), "collinear lines")
    }
}
