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

