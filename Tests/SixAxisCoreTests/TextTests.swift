import simd
import XCTest
@testable import SixAxisCore

final class TextTests: XCTestCase {
    func regions(_ sk: Sketch) -> [SketchRegion] {
        var doc = CADDocument()
        let f = Feature(name: "S", kind: .sketch(sk))
        doc.features = [f]
        return ModelBuilder().build(doc).sketches[f.id]!.regions
    }

    func testCapHeightMatchesHeight() {
        let polys = TextOutline.polylines(TextOutline.contours("H", height: 10, font: nil, origin: Vec2(5, 2)))
        let ys = polys.flatMap { $0.map(\.y) }
        XCTAssertEqual(ys.min()!, 2, accuracy: 0.05, "H sits on the baseline")
        XCTAssertEqual(ys.max()! - ys.min()!, 10, accuracy: 0.05, "cap height = text height")
    }

    func testLetterOHasCounter() {
        var sk = Sketch(plane: .xy)
        sk.addText("O", at: sk.addPoint(Vec2(0, 0)), height: 20)
        let r = regions(sk)
        XCTAssertEqual(r.count, 2, "ring and the inner counter")
    }

    func testTextExtrudes() throws {
        var sk = Sketch(plane: .xy)
        sk.addText("6", at: sk.addPoint(Vec2(0, 0)), height: 30)
        var doc = CADDocument()
        let s = Feature(name: "S", kind: .sketch(sk))
        doc.features = [s]
        let sb = ModelBuilder().build(doc).sketches[s.id]!
        let biggest = try XCTUnwrap(sb.regions.max { $0.area < $1.area })
        var ex = ExtrudeFeature()
        ex.profiles = [sb.profileRef(biggest)]
        ex.distance = "2 mm"
        let e = Feature(name: "E", kind: .extrude(ex))
        doc.features.append(e)
        let state = ModelBuilder().build(doc)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        XCTAssertEqual(state.bodies[e.id]?.shape.volume ?? 0, biggest.area * 2, accuracy: 0.5)
    }

    func testTextFollowsAnchorAndRoundTrips() throws {
        var sk = Sketch(plane: .xy)
        let a = sk.addPoint(Vec2(0, 0))
        let t = sk.addText("Eiche", at: a, height: 8)
        sk.setPoint(a, Vec2(100, 50))
        let ys = sk.polylines(sk.curve(t)!).flatMap { $0.map(\.y) }
        XCTAssertGreaterThanOrEqual(ys.min()!, 49)
        var doc = CADDocument()
        doc.features = [Feature(name: "S", kind: .sketch(sk))]
        XCTAssertEqual(try CADDocument.decode(doc.encoded()), doc)
    }
}
