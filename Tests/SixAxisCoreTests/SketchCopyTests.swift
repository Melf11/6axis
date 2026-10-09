import simd
import XCTest
@testable import SixAxisCore

final class SketchCopyTests: XCTestCase {
    func assertClose(_ a: [Double], _ b: [Double], _ tol: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: tol, file: file, line: line) }
    }

    /// Rectangle with fixed corners (so solving only moves the copies).
    func rect(_ sk: inout Sketch, _ x0: Double, _ y0: Double, _ w: Double, _ h: Double) -> [Int] {
        let p = [Vec2(x0, y0), Vec2(x0 + w, y0), Vec2(x0 + w, y0 + h), Vec2(x0, y0 + h)].map { sk.addPoint($0) }
        for id in p { sk.points[sk.pointIndex(id)!].fixed = true }
        return (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
    }

    func areas(_ sk: Sketch) -> [Double] {
        var doc = CADDocument()
        let f = Feature(name: "S", kind: .sketch(sk))
        doc.features = [f]
        return ModelBuilder().build(doc).sketches[f.id]!.regions.map(\.area).sorted()
    }

    func testChainOfRectangleIsClosed() {
        var sk = Sketch(plane: .xy)
        let l = rect(&sk, 0, 0, 60, 40)
        let (items, closed) = SketchEdit.chain(sk, from: l[2])
        XCTAssertTrue(closed)
        XCTAssertEqual(Set(items.map(\.id)), Set(l))
    }

    func testOffsetRectangleOutwardAndEditDistance() {
        var sk = Sketch(plane: .xy)
        let l = rect(&sk, 0, 0, 60, 40)
        // Counter-clockwise rectangle: right side (−1) is outside.
        let leader = SketchEdit.offset(&sk, chainFrom: l[0], distance: 5, side: -1, text: "5 mm")
        XCTAssertNotNil(leader)
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
        var a = areas(sk)
        XCTAssertEqual(a.count, 2)
        assertClose(a, [1100, 2400])
        // One edit drives all four offset sides.
        sk.setValue("10 mm", of: leader!)
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
        a = areas(sk)
        XCTAssertEqual(a.reduce(0, +), 80 * 60, accuracy: 1e-4)
        XCTAssertEqual(sk.constraints.filter { !sk.isGroupFollower($0) && { if case .offset = $0.kind { return true }; return false }($0) }.count, 1,
                       "one visible offset dimension")
    }

    func testOffsetInwardAndCircle() {
        var sk = Sketch(plane: .xy)
        let l = rect(&sk, 0, 0, 60, 40)
        SketchEdit.offset(&sk, chainFrom: l[0], distance: 5, side: 1, text: "5")
        assertClose(areas(sk), [900, 1500])
        var c = Sketch(plane: .xy)
        let circle = c.addCircle(center: c.addPoint(Vec2(0, 0)), radius: 10)
        c.addConstraint(.radius(curve: circle, value: "10"))
        let lead = SketchEdit.offset(&c, chainFrom: circle, distance: 3, side: 1, text: "3")
        XCTAssertNotNil(lead)
        c.setValue("4", of: lead!)
        XCTAssertTrue(SketchSolver().solve(&c).converged)
        assertClose(c.curves.compactMap { if case let .circle(_, r) = $0.geometry { return r }; return nil }.sorted(), [10, 14])
    }

    func testMirrorStaysSymmetric() {
        var sk = Sketch(plane: .xy)
        let a0 = sk.addPoint(Vec2(0, -50)), a1 = sk.addPoint(Vec2(0, 50))
        sk.points[sk.pointIndex(a0)!].fixed = true; sk.points[sk.pointIndex(a1)!].fixed = true
        let axis = sk.addLine(a0, a1, construction: true)
        let s = sk.addPoint(Vec2(0, 20)), e = sk.addPoint(Vec2(10, 0))
        let line = sk.addLine(s, e)
        let copies = SketchEdit.mirror(&sk, curves: [line], axis: axis)
        XCTAssertEqual(copies.count, 1)
        guard case let .line(a, b) = sk.curve(copies[0])!.geometry else { return XCTFail() }
        XCTAssertEqual(a, s, "point on the axis is shared")
        XCTAssertEqual(simd_distance(sk.point(b)!, Vec2(-10, 0)), 0, accuracy: 1e-9)
        // Move the original end: the mirror follows.
        _ = SketchSolver().drag(&sk, points: [e: Vec2(25, 5)])
        XCTAssertEqual(simd_distance(sk.point(b)!, Vec2(-25, 5)), 0, accuracy: 1e-6)
    }

    func testRectangularPatternOfHolesFollowsSpacing() {
        var sk = Sketch(plane: .xy)
        let center = sk.addPoint(Vec2(37, 9.5))
        sk.points[sk.pointIndex(center)!].fixed = true
        let c = sk.addCircle(center: center, radius: 2.5)
        let leaders = SketchEdit.rectangularPattern(&sk, curves: [c], direction: Vec2(1, 0), count: 5, spacing: 32, spacingText: "32 mm")
        XCTAssertEqual(sk.curves.count, 5)
        XCTAssertEqual(leaders.count, 1)
        sk.setValue("50 mm", of: leaders[0])
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
        let xs = sk.curves.compactMap { sk.center(of: $0)?.x }.sorted()
        assertClose(xs, [37, 87, 137, 187, 237])
        // Radius of the original drives the copies.
        if let i = sk.curveIndex(c), case let .circle(ci, _) = sk.curves[i].geometry { sk.curves[i].geometry = .circle(center: ci, radius: 4) }
        sk.addConstraint(.radius(curve: c, value: "4"))
        XCTAssertTrue(SketchSolver().solve(&sk).converged)
        XCTAssertTrue(sk.curves.allSatisfy { abs(sk.radius(of: $0) - 4) < 1e-6 })
    }

    func testTwoDirectionPatternAndCircularPattern() {
        var sk = Sketch(plane: .xy)
        let c = sk.addCircle(center: sk.addPoint(Vec2(0, 0)), radius: 2)
        SketchEdit.rectangularPattern(&sk, curves: [c], direction: Vec2(1, 0), count: 3, spacing: 10, spacingText: "10",
                                      direction2: Vec2(0, 1), count2: 2, spacing2: 20, spacingText2: "20")
        XCTAssertEqual(sk.curves.count, 6)
        XCTAssertTrue(SketchSolver().solve(&sk).converged)

        var r = Sketch(plane: .xy)
        let hub = r.addPoint(Vec2(0, 0))
        let hole = r.addCircle(center: r.addPoint(Vec2(30, 0)), radius: 3)
        let lead = SketchEdit.circularPattern(&r, curves: [hole], center: hub, count: 6)
        XCTAssertNotNil(lead)
        XCTAssertEqual(r.curves.count, 6)
        let angles = r.curves.compactMap { r.center(of: $0) }.map { (atan2($0.y, $0.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        for (a, e) in zip(angles, [0, 60, 120, 180, 240, 300]) { XCTAssertEqual(a, Double(e), accuracy: 1e-6) }
        XCTAssertTrue(SketchSolver().solve(&r).converged)
    }
}
