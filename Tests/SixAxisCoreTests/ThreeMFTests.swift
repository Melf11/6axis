import simd
import XCTest
@testable import SixAxisCore

final class ThreeMFTests: XCTestCase {
    func testWritesValidZipWithWatertightMeshes() throws {
        let a = try Shape.box(min: Vec3(0, 0, 0), max: Vec3(10, 20, 30))
        let b = try Shape.box(min: Vec3(50, 0, 0), max: Vec3(60, 10, 10))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("3mf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.3mf")
        try ThreeMF.write([.init(name: "Seite <links> & Co", shape: a), .init(name: "Boden", shape: b)], to: url, linearDeflection: 0.01)

        // The archive must pass unzip's integrity test (CRC, deflate streams).
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tq", url.path]
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", url.path, "-d", dir.appendingPathComponent("x").path]
        try unzip.run()
        unzip.waitUntilExit()
        let model = try String(contentsOf: dir.appendingPathComponent("x/3D/3dmodel.model"), encoding: .utf8)
        XCTAssertTrue(model.contains("unit=\"millimeter\""))
        XCTAssertTrue(model.contains("name=\"Seite &lt;links&gt; &amp; Co\""))
        XCTAssertEqual(model.components(separatedBy: "<object ").count - 1, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x/[Content_Types].xml").path))
        // A box welds to 8 vertices and 12 triangles; every edge is shared by exactly two triangles.
        let (v, t) = ThreeMF.weld(try a.mesh(linearDeflection: 0.01))
        XCTAssertEqual(v.count, 8)
        XCTAssertEqual(t.count, 12)
        var edges: [String: Int] = [:]
        for (x, y, z) in t { for (p, q) in [(x, y), (y, z), (z, x)] { edges["\(min(p, q))-\(max(p, q))", default: 0] += 1 } }
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 })
    }

    func testCRC32() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

final class CutSizeTests: XCTestCase {
    func testTiltedBoardKeepsItsTrueCutSize() throws {
        let board = try Shape.box(min: Vec3(0, 0, 0), max: Vec3(600, 300, 19))
        let tilted = try board.transformed(rotation: rotationMatrix(axis: Vec3(0, 0, 1), angle: .pi / 6)
                                           * rotationMatrix(axis: Vec3(1, 0, 0), angle: 0.4), translation: Vec3(10, 20, 30))
        let gen = DrawingGenerator()
        let parts = [DrawingGenerator.Part(name: "Brett", shape: tilted), DrawingGenerator.Part(name: "Gerade", shape: board)]
        let groups = gen.groupParts(parts)
        XCTAssertEqual(groups.count, 1, "the tilted board is the same part as the straight one")
        XCTAssertEqual(groups.first.map { [$0.length, $0.width, $0.thickness] }, [600, 300, 19])
        XCTAssertEqual(groups.first?.count, 2)
        // The part sheet shows it lying flat.
        let flat = DrawingGenerator.normalized(tilted).boundingBox!
        let e = flat.max - flat.min
        XCTAssertEqual(e.x, 600, accuracy: 0.01)
        XCTAssertEqual(e.y, 19, accuracy: 0.01)
        XCTAssertEqual(e.z, 300, accuracy: 0.01)
    }
}
