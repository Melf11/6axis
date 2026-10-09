import simd
import XCTest
@testable import SixAxisCore

final class SketchTrimTests: XCTestCase {
    func regions(_ sk: Sketch) -> [Double] {
        var doc = CADDocument()
        let f = Feature(name: "S", kind: .sketch(sk))
        doc.features = [f]
        return ModelBuilder().build(doc).sketches[f.id]!.regions.map(\.area).sorted()
    }

    func rectangleWithCrossLine() -> (Sketch, Int) {
        var sk = Sketch(plane: .xy)
        let p = [Vec2(0, 0), Vec2(60, 0), Vec2(60, 40), Vec2(0, 40)].map { sk.addPoint($0) }
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        let v = sk.addLine(sk.addPoint(Vec2(20, -10)), sk.addPoint(Vec2(20, 50)))
        sk.addConstraint(.vertical(line: v))
        return (sk, v)
    }

    func testTrimOverhangsLeavesDividerAttached() throws {
        var (sk, v) = rectangleWithCrossLine()
        XCTAssertEqual(SketchEdit.trim(&sk, curve: v, at: Vec2(20, -5)), .shortened)
        XCTAssertEqual(SketchEdit.trim(&sk, curve: v, at: Vec2(20, 45)), .shortened)
        guard case let .line(a, b) = try XCTUnwrap(sk.curve(v)).geometry else { return XCTFail() }
        XCTAssertEqual(simd_distance(sk.point(a)!, Vec2(20, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(sk.point(b)!, Vec2(20, 40)), 0, accuracy: 1e-9)
        let areas = regions(sk)
        XCTAssertEqual(areas.count, 2)
        XCTAssertEqual(areas[0], 800, accuracy: 1e-6)
        XCTAssertEqual(areas[1], 1600, accuracy: 1e-6)
        // The new endpoints stay on the rectangle when it's solved.
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
        XCTAssertEqual(sk.constraints.filter { if case .pointOnCurve = $0.kind { return true }; return false }.count, 2)
    }

    func testTrimWholeSegmentBetweenEndsDeletes() {
        var sk = Sketch(plane: .xy)
        let l = sk.addLine(sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(10, 0)))
        XCTAssertEqual(SketchEdit.trim(&sk, curve: l, at: Vec2(5, 0)), .deleted)
        XCTAssertTrue(sk.curves.isEmpty)
    }

    func testTrimMiddleSplitsLine() {
        var sk = Sketch(plane: .xy)
        let h = sk.addLine(sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(100, 0)))
        sk.addConstraint(.horizontal(line: h))
        sk.addLine(sk.addPoint(Vec2(30, -10)), sk.addPoint(Vec2(30, 10)))
        sk.addLine(sk.addPoint(Vec2(70, -10)), sk.addPoint(Vec2(70, 10)))
        XCTAssertEqual(SketchEdit.trim(&sk, curve: h, at: Vec2(50, 0)), .split)
        let lines = sk.curves.filter { c in
            if case let .line(a, b) = c.geometry { return abs(sk.point(a)!.y) < 1e-9 && abs(sk.point(b)!.y) < 1e-9 }
            return false
        }
        XCTAssertEqual(lines.count, 2)
        let lengths = lines.map { c -> Double in
            guard case let .line(a, b) = c.geometry else { return 0 }
            return simd_distance(sk.point(a)!, sk.point(b)!)
        }.sorted()
        XCTAssertEqual(lengths[0], 30, accuracy: 1e-9)
        XCTAssertEqual(lengths[1], 30, accuracy: 1e-9)
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
    }

    func testTrimCircleBecomesArc() {
        var sk = Sketch(plane: .xy)
        let c = sk.addCircle(center: sk.addPoint(Vec2(0, 0)), radius: 10)
        sk.addConstraint(.diameter(curve: c, value: "20"))
        sk.addLine(sk.addPoint(Vec2(-20, 5)), sk.addPoint(Vec2(20, 5)))
        XCTAssertEqual(SketchEdit.trim(&sk, curve: c, at: Vec2(0, 10)), .opened)
        guard case let .arc(_, s, e) = sk.curve(c)!.geometry else { return XCTFail("not an arc") }
        XCTAssertEqual(sk.point(s)!.y, 5, accuracy: 1e-9)
        XCTAssertEqual(sk.point(e)!.y, 5, accuracy: 1e-9)
        // The kept arc is the lower, larger part: its midpoint lies below the line.
        let mid = sk.polyline(sk.curve(c)!, segments: 64)
        XCTAssertLessThan(mid[mid.count / 2].y, 0)
        XCTAssertTrue(sk.constraints.contains { if case .radius(c, "(20) / 2") = $0.kind { return true }; return false })
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
    }

    func testExtendLineToNextCurve() {
        var sk = Sketch(plane: .xy)
        let l = sk.addLine(sk.addPoint(Vec2(10, 10)), sk.addPoint(Vec2(20, 10)))
        sk.addLine(sk.addPoint(Vec2(50, 0)), sk.addPoint(Vec2(50, 30)))
        sk.addLine(sk.addPoint(Vec2(80, 0)), sk.addPoint(Vec2(80, 30)))
        XCTAssertTrue(SketchEdit.extend(&sk, line: l, near: Vec2(19, 10)))
        guard case let .line(_, b) = sk.curve(l)!.geometry else { return XCTFail() }
        XCTAssertEqual(simd_distance(sk.point(b)!, Vec2(50, 10)), 0, accuracy: 1e-9)
    }
}
