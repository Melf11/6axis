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

final class DrawingEditTests: XCTestCase {
    func page(_ configure: (inout DrawingSettings) -> Void) throws -> DrawingPage {
        let shape = try DrawingTests().boardWithHole()
        var s = DrawingSettings()
        configure(&s)
        return DrawingGenerator().generate(.init(shapes: [shape], settings: s, fallbackTitle: "x"))
    }

    func testDimensionsHaveStableIds() throws {
        let p = try page { _ in }
        let ids = Set(p.dimensions.map(\.id))
        for id in ["front.x.70", "front.y.15", "left.x.40", "top.x.35", "top.y.20", "top.hole.10"] {
            XCTAssertTrue(ids.contains(id), "missing \(id) in \(ids.sorted())")
        }
    }

    func testHideDimension() throws {
        let p = try page { $0.hiddenDimensions = ["front.x.70"] }
        XCTAssertFalse(p.dimensions.contains { $0.id == "front.x.70" })
        XCTAssertFalse(p.texts.contains { $0.text == "70" })
        XCTAssertTrue(p.texts.contains { $0.text == "15" })
    }

    func testMoveDimensionLine() throws {
        // Measured relative to the front view, because the layout re-centres when rows are added.
        func lineY(_ p: DrawingPage) -> Double {
            p.dimensions.first { $0.id == "front.x.70" }!.segments[0].0.y - p.views.first { $0.id == "front" }!.min.y
        }
        let a = try page { _ in }
        let b = try page { $0.dimensionOffsets["front.x.70"] = DimensionOffset(distance: 12, along: 0) }
        XCTAssertEqual(lineY(a) - lineY(b), 14, accuracy: 1e-6, "moved lines snap to the 7 mm rows (12 → 2 rows)")
    }

    func testViewOffsetsKeepProjectionAlignment() throws {
        let a = try page { _ in }
        let b = try page { $0.viewOffsets["top"] = Vec2(30, -8) }
        let ta = a.views.first { $0.id == "top" }!, tb = b.views.first { $0.id == "top" }!
        XCTAssertEqual(tb.min.x, ta.min.x, accuracy: 1e-9, "top view must stay below the front view")
        XCTAssertEqual(tb.min.y - ta.min.y, -8, accuracy: 1e-9)
        let c = try page { $0.viewOffsets["front"] = Vec2(5, 5) }
        let fa = a.views.first { $0.id == "left" }!, fc = c.views.first { $0.id == "left" }!
        XCTAssertEqual(fc.min - fa.min, Vec2(5, 5), "moving the front view moves the whole projection")
    }

    func testMovedDimensionsNeverOverlap() {
        let f = DrawingGenerator.Feature(position: 0, low: 0, high: 0)
        let features = [(f, "a"), (f, "b"), (f, "c")]
        // "a" dragged onto the row of "b": "b" moves outwards, all rows distinct.
        let rows = DrawingGenerator.assignRows(features, ["a": DimensionOffset(distance: 7, along: 0)])
        XCTAssertEqual(rows, [1, 2, 3])
        XCTAssertEqual(Set(rows).count, 3)
    }

    func testCustomDimensionSnapsToVertices() throws {
        // Slightly off the real corners: should snap to (0, 0) and (70, 15) → 70 horizontally.
        let custom = CustomDimension(view: "front", a: Vec2(0.3, 0.2), b: Vec2(69.6, 14.8), orientation: .horizontal, offset: 8)
        let p = try page { $0.customDimensions = [custom] }
        let d = try XCTUnwrap(p.dimensions.first { $0.id == custom.key })
        XCTAssertEqual(d.text, "70")
        XCTAssertTrue(d.isCustom)
    }

    func testSettingsDecodeOlderFiles() throws {
        let old = #"{"sheet":"a3","showHidden":false,"title":"Alt"}"#
        let s = try JSONDecoder().decode(DrawingSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.sheet, .a3)
        XCTAssertFalse(s.showHidden)
        XCTAssertTrue(s.hiddenDimensions.isEmpty)
        var t = s
        t.customDimensions = [CustomDimension(view: "top", a: .zero, b: Vec2(1, 1), orientation: .aligned, offset: 3)]
        t.dimensionOffsets["front.x.70"] = DimensionOffset(distance: 2, along: -1)
        let round = try JSONDecoder().decode(DrawingSettings.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(round, t)
    }
}
