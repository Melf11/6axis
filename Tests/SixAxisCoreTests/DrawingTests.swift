import XCTest
import simd
@testable import SixAxisCore

final class DrawingTests: XCTestCase {
    /// 70 × 40 × 15 board with a Ø10 through hole at (35, 20).
    func boardWithHole() throws -> Shape {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(70, 0)), sk.addPoint(Vec2(70, 40)), sk.addPoint(Vec2(0, 40))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        sk.addCircle(center: sk.addPoint(Vec2(35, 20)), radius: 5)
        let sketch = Feature(name: "Skizze1", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(3, 3))]
        ex.distance = "15"
        let f = Feature(name: "Extrusion1", kind: .extrude(ex))
        doc.features = [sketch, f]
        let state = ModelBuilder().build(doc)
        return try XCTUnwrap(state.bodies[f.id]?.shape)
    }

    func testProjectionFrontView() throws {
        let shape = try boardWithHole()
        let front = try shape.project(viewDir: Vec3(0, -1, 0), xDir: Vec3(1, 0, 0), deflection: 0.05)
        let b = try XCTUnwrap(front.bounds)
        XCTAssertEqual(b.max.x - b.min.x, 70, accuracy: 1e-3)
        XCTAssertEqual(b.max.y - b.min.y, 15, accuracy: 1e-3)
        XCTAssertTrue(front.polylines.contains { $0.hidden }, "hole edges are hidden in the front view")
        let top = try shape.project(viewDir: Vec3(0, 0, 1), xDir: Vec3(1, 0, 0), deflection: 0.05)
        XCTAssertTrue(top.circles.contains { $0.full && abs($0.radius - 5) < 1e-6 && !$0.hidden })
    }

    func testThreeViewDrawingWithBaselineDimensions() throws {
        let shape = try boardWithHole()
        var settings = DrawingSettings()
        settings.title = "Brett"
        let page = DrawingGenerator().generate(.init(shapes: [shape], settings: settings, fallbackTitle: "x"))
        XCTAssertFalse(page.isEmpty)
        XCTAssertEqual(page.sheet.name, "A4")
        let texts = Set(page.texts.map(\.text))
        for expected in ["70", "40", "15", "35", "20", "Ø10", "Brett", page.scale.label] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected) in \(texts.sorted())")
        }
        XCTAssertEqual(page.scale.label, "1:1")
        // Everything stays inside the sheet.
        for line in page.lines { for p in line.points {
            XCTAssertTrue(p.x >= 0 && p.x <= page.sheet.width && p.y >= 0 && p.y <= page.sheet.height, "\(p) outside sheet")
        } }
    }

    func testLargePartSelectsSmallerScale() throws {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(1800, 0)), sk.addPoint(Vec2(1800, 600)), sk.addPoint(Vec2(0, 600))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        let sketch = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(5, 5))]
        ex.distance = "750"
        let f = Feature(name: "E", kind: .extrude(ex))
        doc.features = [sketch, f]
        let shape = try XCTUnwrap(ModelBuilder().build(doc).bodies[f.id]?.shape)
        let page = DrawingGenerator().generate(.init(shapes: [shape], settings: DrawingSettings(), fallbackTitle: "Schrank"))
        XCTAssertTrue(["1:10", "1:20"].contains(page.scale.label), page.scale.label)
        XCTAssertTrue(page.texts.contains { $0.text == "1800" })
    }
}
