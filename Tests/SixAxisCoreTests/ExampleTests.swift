import XCTest
@testable import SixAxisCore

final class ExampleTests: XCTestCase {
    /// Every example builds without errors and has the expected bodies.
    /// `SIXAXIS_WRITE_EXAMPLES=Examples swift test --filter ExampleTests` regenerates the files.
    func testExamplesBuild() throws {
        for example in Examples.all {
            let state = ModelBuilder().build(example.document)
            XCTAssertTrue(state.errors.isEmpty, "\(example.fileName): \(state.errors)")
            XCTAssertFalse(state.bodies.isEmpty, example.fileName)
            for (_, body) in state.bodies { XCTAssertGreaterThan(body.shape.volume, 0, example.fileName) }
            if let dir = ProcessInfo.processInfo.environment["SIXAXIS_WRITE_EXAMPLES"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(example.fileName + ".6axis")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try example.document.encoded().write(to: url)
            }
        }
    }

    func testExampleParametersDriveModel() throws {
        var box = Examples.storageBox()
        let v1 = ModelBuilder().build(box).bodies.values.first!.shape.volume
        box.parameters[box.parameters.firstIndex { $0.name == "wand" }!].expression = "3 mm"
        let state = ModelBuilder().build(box)
        XCTAssertTrue(state.errors.isEmpty, "\(state.errors)")
        XCTAssertGreaterThan(state.bodies.values.first!.shape.volume, v1)
        let features = Examples.storageBox().features.map(\.kind.typeName)
        XCTAssertEqual(features, ["Skizze", "Extrusion", "Abrundung", "Wandstärke"])
        let board = Examples.cuttingBoard().features.map(\.kind.typeName)
        XCTAssertEqual(board, ["Skizze", "Extrusion", "Abrundung", "Fase"])
    }

    func testMaterialDensity() {
        XCTAssertEqual(MaterialDensity.lookup("Eiche massiv"), 0.71)
        XCTAssertEqual(MaterialDensity.lookup("Buche Multiplex"), 0.75)
        XCTAssertEqual(MaterialDensity.lookup("PLA"), 1.24)
        XCTAssertNil(MaterialDensity.lookup(""))
        XCTAssertNil(MaterialDensity.lookup("Unobtainium"))
    }
}

extension ExampleTests {
    /// Changing the main sizes of the examples rebuilds without errors and changes the volume.
    func testExamplesFollowSizeParameters() {
        let cases: [(CADDocument, [String: String])] = [
            (Examples.cabinet(), ["breite": "800 mm", "hoehe": "400 mm", "tiefe": "560 mm", "staerke": "16 mm", "fachhoehe": "150 mm"]),
            (Examples.cuttingBoard(), ["laenge": "300 mm", "breite": "180 mm", "dicke": "20 mm"]),
            (Examples.storageBox(), ["laenge": "200 mm", "breite": "50 mm", "hoehe": "30 mm"]),
        ]
        for (original, changes) in cases {
            var doc = original
            let before = ModelBuilder().build(doc).bodies.values.reduce(0) { $0 + $1.shape.volume }
            for (name, value) in changes { doc.parameters[doc.parameters.firstIndex { $0.name == name }!].expression = value }
            let state = ModelBuilder().build(doc)
            XCTAssertTrue(state.errors.isEmpty, "\(changes): \(state.errors)")
            let after = state.bodies.values.reduce(0) { $0 + $1.shape.volume }
            XCTAssertNotEqual(before, after, accuracy: 1)
            XCTAssertEqual(state.bodies.count, ModelBuilder().build(original).bodies.count)
        }
    }

    /// Cabinet volumes per board match the parameters exactly.
    func testCabinetBoardSizes() {
        var doc = Examples.cabinet()
        for (n, v) in ["breite": "800 mm", "hoehe": "720 mm", "tiefe": "560 mm"] {
            doc.parameters[doc.parameters.firstIndex { $0.name == n }!].expression = v
        }
        let state = ModelBuilder().build(doc)
        func vol(_ name: String) -> Double {
            let id = doc.bodies.first { $0.value.name == name }!.key
            return state.bodies[id]!.shape.volume
        }
        XCTAssertEqual(vol("Seite links"), 19 * 720 * 560, accuracy: 1)
        XCTAssertEqual(vol("Rückwand"), 800 * 720 * 8, accuracy: 1)
        let hole = Double.pi * 16
        XCTAssertEqual(vol("Boden"), (800 - 38) * 19 * 560 - 2 * hole * 19, accuracy: 1)
    }
}
