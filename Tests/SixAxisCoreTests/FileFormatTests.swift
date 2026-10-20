import XCTest
@testable import SixAxisCore

/// Files saved by released versions must keep opening and building (Fixtures/<version>-<name>.6axis).
final class FileFormatTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    func testReleasedFilesOpenAndBuild() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "6axis" }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        for url in files {
            let doc = try CADDocument.decode(Data(contentsOf: url))
            XCTAssertEqual(doc.formatVersion, CADDocument.currentFormatVersion, url.lastPathComponent)
            let state = ModelBuilder().build(doc)
            XCTAssertTrue(state.errors.isEmpty, "\(url.lastPathComponent): \(state.errors)")
            XCTAssertFalse(state.bodies.isEmpty, url.lastPathComponent)
            // Round trip keeps the content.
            XCTAssertEqual(try CADDocument.decode(doc.encoded()), doc, url.lastPathComponent)
        }
    }

    /// A move saved by 2.0.3 (format 7) turns about the X axis through the origin; since format 8 new moves turn
    /// about the bodies' centre. The old file must build exactly as 2.0.3 built it.
    func testMoveFrom203KeepsTurningAboutTheOrigin() throws {
        let doc = try CADDocument.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("2.0.3-Kippen.6axis")))
        guard case let .move(m)? = doc.features.last?.kind else { return XCTFail("no move") }
        XCTAssertNil(m.aroundCenter)
        XCTAssertFalse(m.turnsAboutCenter)
        let bb = try XCTUnwrap(ModelBuilder().build(doc).bodies[m.bodies[0]]?.shape.boundingBox)
        // Result of 2.0.3 (printed when the file was written).
        for (got, want) in zip([bb.min.x, bb.min.y, bb.min.z, bb.max.x, bb.max.y, bb.max.z], [0.0, -10, 5, 20, 0, 25]) {
            XCTAssertEqual(got, want, accuracy: 1e-5)
        }
    }

    func testHolesFrom210StaySingle() throws {
        let doc = try CADDocument.decode(Data(contentsOf: Self.fixtures.appendingPathComponent("2.1.0-Bohrungen.6axis")))
        guard case let .hole(h)? = doc.features.last?.kind else { return XCTFail("no hole") }
        XCTAssertNil(h.grid)
        let plate = try XCTUnwrap(doc.features.first { $0.name == "Platte" }?.id)
        // Volume printed by 2.1.0 when the file was written.
        XCTAssertEqual(try XCTUnwrap(ModelBuilder().build(doc).bodies[plate]?.shape.volume), 227528.76110196154, accuracy: 1e-3)
    }

    func testNewerFormatIsRefused() {
        let data = Data(#"{"formatVersion": 99, "features": []}"#.utf8)
        XCTAssertThrowsError(try CADDocument.decode(data)) { error in
            XCTAssertTrue("\(error)".contains("neueren 6axis-Version"))
        }
    }

    func testMinimalAndCorruptFiles() throws {
        let empty = try CADDocument.decode(Data("{}".utf8))
        XCTAssertTrue(empty.features.isEmpty)
        XCTAssertThrowsError(try CADDocument.decode(Data("[1,2]".utf8)))
        XCTAssertThrowsError(try CADDocument.decode(Data(#"{"features": 5}"#.utf8))) { error in
            XCTAssertTrue("\(error)".contains("beschädigt"), "\(error)")
        }
    }

    func testSavedFilesCarryCurrentVersion() throws {
        var doc = CADDocument()
        doc.formatVersion = 1
        let json = try JSONSerialization.jsonObject(with: doc.encoded()) as! [String: Any]
        XCTAssertEqual(json["formatVersion"] as? Int, CADDocument.currentFormatVersion)
    }

    func testRemoveBodiesStep() throws {
        var doc = CADDocument()
        doc.features = SketchEdit.check_box(name: "A", x: 0) + SketchEdit.check_box(name: "B", x: 50)
        let b = doc.features[3].id
        doc.features.append(Feature(name: "Entfernen1", kind: .removeBodies([b])))
        let state = ModelBuilder().build(doc)
        XCTAssertEqual(state.bodyOrder, [doc.features[1].id])
        XCTAssertEqual(try CADDocument.decode(doc.encoded()), doc)
    }
}

