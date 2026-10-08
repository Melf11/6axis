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
