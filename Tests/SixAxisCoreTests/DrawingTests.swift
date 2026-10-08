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

final class DrawingPartsTests: XCTestCase {
    /// Box-shaped board via sketch on XZ, extruded along -Y.
    func board(_ x: ClosedRange<Double>, _ z: ClosedRange<Double>, depth: Double = 300) throws -> Shape {
        var doc = CADDocument()
        var sk = Sketch(plane: .xz)
        let p = [sk.addPoint(Vec2(x.lowerBound, z.lowerBound)), sk.addPoint(Vec2(x.upperBound, z.lowerBound)),
                 sk.addPoint(Vec2(x.upperBound, z.upperBound)), sk.addPoint(Vec2(x.lowerBound, z.upperBound))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        let s = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2((x.lowerBound + x.upperBound) / 2, (z.lowerBound + z.upperBound) / 2))]
        ex.distance = "\(depth)"
        let f = Feature(name: "E", kind: .extrude(ex))
        doc.features = [s, f]
        return try XCTUnwrap(ModelBuilder().build(doc).bodies[f.id]?.shape)
    }

    func cabinet() throws -> [DrawingGenerator.Part] {
        [
            .init(name: "Seite", shape: try board(0...19, 0...600)),
            .init(name: "Seite", shape: try board(481...500, 0...600)),
            .init(name: "Boden", shape: try board(19...481, 0...19)),
            .init(name: "Deckel", shape: try board(19...481, 581...600)),
        ]
    }

    func testIdenticalPartsAreGrouped() throws {
        let groups = DrawingGenerator().groupParts(try cabinet())
        XCTAssertEqual(groups.count, 2, "two sides identical, bottom and top identical")
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual([groups[0].length, groups[0].width, groups[0].thickness], [600, 300, 19])
        XCTAssertEqual([groups[1].length, groups[1].width, groups[1].thickness], [462, 300, 19])
    }

    func testPartIsOrientedLengthWidthThickness() throws {
        let side = try board(0...19, 0...600)
        let n = DrawingGenerator.normalized(side)
        let bb = try XCTUnwrap(n.boundingBox)
        let e = bb.max - bb.min
        XCTAssertEqual(e.x, 600, accuracy: 1e-6)
        XCTAssertEqual(e.z, 300, accuracy: 1e-6)
        XCTAssertEqual(e.y, 19, accuracy: 1e-6)
        XCTAssertEqual(simd_length(bb.min), 0, accuracy: 1e-6)
        XCTAssertEqual(n.volume, side.volume, accuracy: 1e-3, "rotation, no mirroring or scaling")
    }

    func testAssemblyWithPartsListBalloonsAndPartSheets() throws {
        var settings = DrawingSettings()
        settings.material = "Eiche"
        let pages = DrawingGenerator().generatePages(.init(parts: try cabinet(), settings: settings, fallbackTitle: "Korpus"))
        XCTAssertGreaterThanOrEqual(pages.count, 2)
        XCTAssertEqual(pages[0].name, "Gesamtansicht")
        let texts = Set(pages[0].texts.map(\.text))
        for t in ["Pos.", "Benennung", "Anzahl", "Seite", "Boden", "600", "462", "Eiche", "1", "2", "1 / \(pages.count)"] {
            XCTAssertTrue(texts.contains(t), "missing \(t)")
        }
        XCTAssertTrue(pages[0].dimensions.contains { $0.id == "balloon.1" })
        // Part sheet: prefixed ids, heading with count and cut size.
        let parts = pages[1]
        XCTAssertTrue(parts.dimensions.contains { $0.id == "p1.front.x.600" }, "\(parts.dimensions.map(\.id))")
        XCTAssertTrue(parts.texts.contains { $0.text.contains("Pos. 1") && $0.text.contains("2 Stück") && $0.text.contains("600 × 300 × 19") })
        XCTAssertTrue(parts.texts.contains { $0.text == "2 / \(pages.count)" })
    }

    func testSingleBodyHasNoPartSheets() throws {
        let pages = DrawingGenerator().generatePages(.init(parts: [.init(name: "Brett", shape: try board(0...100, 0...50))],
                                                           settings: DrawingSettings(), fallbackTitle: "x"))
        XCTAssertEqual(pages.count, 1)
        XCTAssertFalse(pages[0].texts.contains { $0.text == "Benennung" && $0.position.y > 50 }, "no parts list for one body")
    }
}

final class DrawingStage5Tests: XCTestCase {
    let parts = DrawingPartsTests()

    func testBodyMetaDecodesOlderFiles() throws {
        let old = #"{"name":"Seite","visible":true}"#
        let m = try JSONDecoder().decode(BodyMeta.self, from: Data(old.utf8))
        XCTAssertEqual(m.name, "Seite")
        XCTAssertEqual(m.material, "")
        XCTAssertEqual(m.grain, .none)
    }

    func testMaterialSeparatesGroupsAndShowsInList() throws {
        var p = try parts.cabinet()
        p[0].material = "Eiche massiv"; p[0].grain = .length
        p[1].material = "Buche massiv"
        let groups = DrawingGenerator().groupParts(p)
        XCTAssertEqual(groups.count, 3, "same size but different material → different positions")
        let page = DrawingGenerator().generatePages(.init(parts: p, settings: DrawingSettings(), fallbackTitle: "K"))[0]
        XCTAssertTrue(page.texts.contains { $0.text == "Eiche massiv ↔" })
        XCTAssertTrue(page.texts.contains { $0.text == "Buche massiv" })
    }

    func testPartsDXFHasLayersAndRealCircles() throws {
        let board = try DrawingTests().boardWithHole()
        let dxf = DrawingGenerator().partsDXF(.init(parts: [.init(name: "Brett", shape: board)], settings: DrawingSettings(), fallbackTitle: "x"))
        XCTAssertTrue(dxf.hasPrefix("0\nSECTION\n2\nHEADER"))
        XCTAssertTrue(dxf.contains("AC1009"))
        XCTAssertTrue(dxf.hasSuffix("0\nEOF\n"))
        XCTAssertTrue(dxf.contains("POS_1"))
        XCTAssertEqual(dxf.components(separatedBy: "0\nCIRCLE\n").count - 1, 1, "the Ø10 hole as one CIRCLE entity")
        XCTAssertTrue(dxf.contains("\n40\n5.0000\n"), "radius 5")
    }

    func testSheetDXFUsesISOLayers() throws {
        let page = DrawingGenerator().generate(.init(shapes: [try DrawingTests().boardWithHole()], settings: DrawingSettings(), fallbackTitle: "x"))
        let dxf = page.dxf()
        for layer in ["KONTUR", "VERDECKT", "MITTELLINIE", "BEMASSUNG", "RAHMEN"] { XCTAssertTrue(dxf.contains("\n8\n\(layer)\n"), layer) }
        XCTAssertTrue(dxf.contains("%%c10"), "Ø written as %%c for DXF")
    }

    func testSectionAA() throws {
        var s = DrawingSettings()
        s.sectionLeft = true
        let page = DrawingGenerator().generatePages(.init(parts: try parts.cabinet(), settings: s, fallbackTitle: "K"))[0]
        XCTAssertTrue(page.texts.contains { $0.text == "A–A" })
        XCTAssertGreaterThan(page.lines.filter { $0.style == .hatch }.count, 5, "cut boards are hatched")
        let marker = try XCTUnwrap(page.dimensions.first { $0.id == "section.A" })
        XCTAssertEqual(marker.value, 250, accuracy: 1e-6, "default plane through the middle")
    }

    func testDetailView() throws {
        var s = DrawingSettings()
        s.scale = "1:10"
        s.details = [DetailView(letter: "Z", view: "front", center: Vec2(10, 10), radius: 30, factor: 5)]
        let page = DrawingGenerator().generatePages(.init(parts: try parts.cabinet(), settings: s, fallbackTitle: "K"))[0]
        let d = s.details[0]
        XCTAssertTrue(page.views.contains { $0.id == d.viewId })
        XCTAssertTrue(page.texts.contains { $0.text == "Z (1:2)" })
        XCTAssertTrue(page.dimensions.contains { $0.id == d.markId })
        XCTAssertTrue(page.snapPoints.contains { $0.view == d.viewId }, "corners in the detail are snappable")
    }

    func testHatchAndClipGeometry() {
        let square = [[Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10), Vec2(0, 0)]]
        let lines = DrawingGenerator.hatch(square, angle: .pi / 4, spacing: 1)
        XCTAssertGreaterThan(lines.count, 10)
        for (a, b) in lines {
            for p in [a, b, (a + b) / 2] { XCTAssertTrue(p.x > -1e-6 && p.x < 10 + 1e-6 && p.y > -1e-6 && p.y < 10 + 1e-6) }
        }
        let clipped = DrawingGenerator.clip([Vec2(-10, 0), Vec2(10, 0)], center: .zero, radius: 5)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].first!.x, -5, accuracy: 1e-9)
        XCTAssertEqual(clipped[0].last!.x, 5, accuracy: 1e-9)
        XCTAssertEqual(DrawingGenerator.ratio(0.5), "1:2")
        XCTAssertEqual(DrawingGenerator.ratio(2), "2:1")
    }
}

final class DrawingRadiusTests: XCTestCase {
    /// 70 × 40 × 15 board with all four vertical corners rounded.
    func roundedBoard(radius: String) throws -> Shape {
        var doc = CADDocument()
        var sk = Sketch(plane: .xy)
        let p = [sk.addPoint(Vec2(0, 0)), sk.addPoint(Vec2(70, 0)), sk.addPoint(Vec2(70, 40)), sk.addPoint(Vec2(0, 40))]
        for i in 0..<4 { sk.addLine(p[i], p[(i + 1) % 4]) }
        let sketch = Feature(name: "S", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: sketch.id, sample: Vec2(5, 5))]
        ex.distance = "15"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features = [sketch, e]
        let body = try XCTUnwrap(ModelBuilder().build(doc).bodies[e.id])
        var fillet = FilletFeature()
        fillet.radius = radius
        fillet.edges = body.edgeInfos.compactMap { info -> BodyEdgeRef? in
            guard let info, info.kind == .line, abs(info.end.z - info.start.z) > 1 else { return nil }
            return BodyEdgeRef(body: e.id, edge: body.edgeRef(info.index)!)
        }
        XCTAssertEqual(fillet.edges.count, 4)
        doc.features.append(Feature(name: "F", kind: .fillet(fillet)))
        let state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        return try XCTUnwrap(state.bodies[e.id]?.shape)
    }

    func testRoundedCornersGetRadiusDimension() throws {
        let page = DrawingGenerator().generate(.init(shapes: [try roundedBoard(radius: "5")], settings: DrawingSettings(), fallbackTitle: "x"))
        let radiusTexts = page.texts.filter { $0.text.contains("R5") }.map(\.text)
        XCTAssertEqual(radiusTexts, ["4× R5"], "one callout for all four equal radii, given once")
        XCTAssertTrue(page.dimensions.contains { $0.id == "top.radius.50" })
        XCTAssertTrue(page.texts.contains { $0.text == "70" }, "overall size still dimensioned")
    }

    func testDecimalRadius() throws {
        let page = DrawingGenerator().generate(.init(shapes: [try roundedBoard(radius: "2.5")], settings: DrawingSettings(), fallbackTitle: "x"))
        XCTAssertTrue(page.texts.contains { $0.text == "4× R2,5" }, page.texts.map(\.text).description)
    }

    func testMMText() {
        XCTAssertEqual(DrawingGenerator.mmText(8), "8")
        XCTAssertEqual(DrawingGenerator.mmText(2.5), "2,5")
        XCTAssertEqual(DrawingGenerator.mmText(2.04), "2")
    }
}
