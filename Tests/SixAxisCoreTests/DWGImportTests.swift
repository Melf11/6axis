import XCTest
import simd
@testable import SixAxisCore

/// Writes small DWG files in each packaging and object layout from R2000 on, because real files cannot go into the
/// repository (their licences do not fit). Real drawings of all versions, also R13 and R14, are checked by
/// `testRealFilesFromFolder` when a folder is given.
private struct DWGTestFile {
    struct BitWriter {
        var bytes: [UInt8] = []
        var bitCount = 0
        mutating func bit(_ b: Int) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if b != 0 { bytes[bytes.count - 1] |= UInt8(0x80 >> (bitCount % 8)) }
            bitCount += 1
        }
        mutating func bits(_ v: UInt64, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bit(Int((v >> UInt64(i)) & 1)) } }
        mutating func rc(_ v: UInt8) { bits(UInt64(v), 8) }
        mutating func rs(_ v: UInt16) { rc(UInt8(v & 0xFF)); rc(UInt8(v >> 8)) }
        mutating func rl(_ v: UInt32) { rs(UInt16(v & 0xFFFF)); rs(UInt16(v >> 16)) }
        mutating func rd(_ d: Double) { let p = d.bitPattern; rl(UInt32(p & 0xFFFF_FFFF)); rl(UInt32(p >> 32)) }
        mutating func bs(_ v: Int) { bits(0, 2); rs(UInt16(truncatingIfNeeded: v)) }
        mutating func bl(_ v: Int) { bits(0, 2); rl(UInt32(truncatingIfNeeded: v)) }
        mutating func bd(_ d: Double) { bits(0, 2); rd(d) }
        mutating func dd(_ d: Double) { bits(3, 2); rd(d) }
        mutating func p3(_ x: Double, _ y: Double, _ z: Double = 0) { bd(x); bd(y); bd(z) }
        mutating func handle(_ code: Int, _ v: UInt64) {
            bits(UInt64(code), 4)
            var b: [UInt8] = []
            var x = v
            while x > 0 { b.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
            bits(UInt64(b.count), 4)
            for c in b { rc(c) }
        }
        mutating func t8(_ s: String) { let u = Array(s.utf8); bs(u.count); for c in u { rc(c) } }
        mutating func t16(_ s: String) { let u = Array(s.utf16); bs(u.count); for c in u { rs(c) } }
        mutating func pad() { while bitCount % 8 != 0 { bit(0) } }
    }

    let v: Int

    static func ms(_ n: Int) -> [UInt8] {
        precondition(n < 0x7FFF)
        return [UInt8(n & 0xFF), UInt8(n >> 8)]
    }

    static func mc(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var x = n
        repeat {
            var b = UInt8(x & 0x7F)
            x >>= 7
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }

    /// Modular char with room for the sign bit in its last byte.
    static func mcSigned(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var x = abs(n)
        while x > 0x3F {
            out.append(UInt8(x & 0x7F) | 0x80)
            x >>= 7
        }
        out.append(UInt8(x) | (n < 0 ? 0x40 : 0))
        return out
    }

    /// Puts one object together: fields, string stream and handles in the places the version wants them.
    func object(type: Int, handle: UInt64, fields: (inout BitWriter, inout BitWriter) -> Void, handles: (inout BitWriter) -> Void) -> [UInt8] {
        var data = BitWriter()
        if v >= 24 {
            if type < 256 { data.bits(0, 2); data.rc(UInt8(type)) } else { data.bits(2, 2); data.rs(UInt16(type)) }
        } else {
            data.bs(type)
        }
        let sizeAt = data.bitCount
        if v >= 15, v < 24 { data.rl(0) }
        data.handle(0, handle)
        data.bs(0)      // no extended data
        var strings = BitWriter()
        fields(&data, &strings)
        if v >= 21 {
            if v >= 24 {
                // From R2010 on the size is in bytes, so the last bit of the data (the string flag) ends a byte.
                let tail = (strings.bitCount > 0 ? strings.bytes.count * 8 + 16 : 0) + 1
                while (data.bitCount + tail) % 8 != 0 { data.bit(0) }
            }
            if strings.bitCount > 0 {
                for byte in strings.bytes { data.rc(byte) }
                data.rs(UInt16(strings.bytes.count * 8))
                data.bit(1)
            } else {
                data.bit(0)
            }
        }
        let dataBits = data.bitCount
        if v >= 15, v < 24 {
            // Patch the size into the placeholder, little-endian bytes in stream order.
            var patched = BitWriter()
            patched.rl(UInt32(dataBits))
            for i in 0..<32 {
                let b = Int((patched.bytes[i / 8] >> UInt8(7 - i % 8)) & 1)
                let at = sizeAt + i
                if b != 0 { data.bytes[at / 8] |= UInt8(0x80 >> (at % 8)) }
            }
        }
        var h = BitWriter()
        handles(&h)
        h.pad()
        if v >= 24 {
            let parts: [[UInt8]] = [Self.ms(data.bytes.count + h.bytes.count), Self.mc(h.bytes.count * 8), data.bytes, h.bytes, [0, 0]]
            return parts.flatMap { $0 }
        }
        var body = BitWriter()
        for byte in data.bytes { body.rc(byte) }
        body.bitCount = dataBits
        for byte in h.bytes { body.rc(byte) }
        body.pad()
        let parts: [[UInt8]] = [Self.ms(body.bytes.count), body.bytes, [0, 0]]
        return parts.flatMap { $0 }
    }

    /// Common entity data. `owner` is set for entities inside a block.
    func entity(type: Int, handle: UInt64, owner: UInt64?, layer: UInt64, fields: @escaping (inout BitWriter, inout BitWriter) -> Void,
                extraHandles: @escaping (inout BitWriter) -> Void = { _ in }) -> [UInt8] {
        object(type: type, handle: handle, fields: { d, s in
            d.bit(0)                                    // no graphics
            d.bits(owner == nil ? 2 : 0, 2)
            d.bl(0)
            if v >= 18 { d.bit(1) }
            if v >= 27 { d.bit(0) }
            if v <= 15 { d.bit(1) }
            d.bs(256)
            d.bd(1)
            d.bits(0, 2); d.bits(0, 2)
            if v >= 21 { d.bits(0, 2); d.rc(0) }
            if v >= 24 { d.bit(0); d.bit(0); d.bit(0) }
            d.bs(0)
            d.rc(29)
            fields(&d, &s)
        }, handles: { h in
            if let owner { h.handle(4, owner) }
            if v < 18 { h.handle(5, 0) }                // no xdictionary: R2004 and later say so by a bit
            h.handle(5, layer)
            extraHandles(&h)
        })
    }

    func tableHead(_ d: inout BitWriter, _ s: inout BitWriter, name: String) {
        d.bl(0)
        if v >= 18 { d.bit(1) }
        if v >= 27 { d.bit(0) }
        if v >= 21 { s.t16(name) } else { d.t8(name) }
        d.bit(0); d.bs(0); d.bit(0)
    }

    func layer(handle: UInt64, name: String) -> [UInt8] {
        object(type: 0x33, handle: handle, fields: { d, s in
            tableHead(&d, &s, name: name)
            d.bs(0)
            d.bs(7)
        }, handles: { h in h.handle(4, 1) })
    }

    func blockHeader(handle: UInt64, name: String, base: SIMD3<Double> = .zero) -> [UInt8] {
        object(type: 0x31, handle: handle, fields: { d, s in
            tableHead(&d, &s, name: name)
            d.bit(0); d.bit(0); d.bit(0); d.bit(0); d.bit(0)
            if v >= 18 { d.bl(0) }
            d.p3(base.x, base.y, base.z)
        }, handles: { h in h.handle(4, 1) })
    }

    func line(handle: UInt64, owner: UInt64?, _ a: Vec2, _ b: Vec2) -> [UInt8] {
        entity(type: 0x13, handle: handle, owner: owner, layer: 0x10, fields: { d, _ in
            d.bit(1)
            d.rd(a.x); d.dd(b.x); d.rd(a.y); d.dd(b.y)
            d.bit(1); d.bit(1)
        })
    }

    /// Model space: a closed 100 × 50 rectangle of lines, circle, arc, polyline with a half-circle, a block placed
    /// scaled and turned, mirrored circle, a text, and a dimension that stays out.
    func objects() -> [(UInt64, [UInt8])] {
        var out: [(UInt64, [UInt8])] = []
        func add(_ h: UInt64, _ b: [UInt8]) { out.append((h, b)) }
        add(0x10, layer(handle: 0x10, name: "0"))
        add(0x11, blockHeader(handle: 0x11, name: "*Model_Space"))
        add(0x12, blockHeader(handle: 0x12, name: "Teil", base: SIMD3(1, 0, 0)))
        add(0x20, line(handle: 0x20, owner: nil, Vec2(0, 0), Vec2(100, 0)))
        add(0x21, line(handle: 0x21, owner: nil, Vec2(100, 0), Vec2(100, 50)))
        add(0x22, line(handle: 0x22, owner: nil, Vec2(100, 50), Vec2(0, 50)))
        add(0x23, line(handle: 0x23, owner: nil, Vec2(0, 50), Vec2(0, 0)))
        add(0x24, entity(type: 0x12, handle: 0x24, owner: nil, layer: 0x10, fields: { d, _ in
            d.p3(30, 20); d.bd(5); d.bit(1); d.bit(1)
        }))
        add(0x25, entity(type: 0x11, handle: 0x25, owner: nil, layer: 0x10, fields: { d, _ in
            d.p3(200, 0); d.bd(10); d.bit(1); d.bit(1); d.bd(0); d.bd(.pi / 2)
        }))
        add(0x26, entity(type: 0x4D, handle: 0x26, owner: nil, layer: 0x10, fields: { d, _ in
            d.bs(16)                 // has bulges
            d.bl(2); d.bl(2)
            d.rd(300); d.rd(0)
            d.dd(320); d.dd(0)
            d.bd(1); d.bd(0)
        }))
        add(0x27, entity(type: 0x07, handle: 0x27, owner: nil, layer: 0x10, fields: { d, _ in
            d.p3(400, 0)
            d.bits(0, 2); d.rd(2); d.dd(2); d.dd(2)
            d.bd(.pi / 2)
            d.p3(0, 0, 1)
            d.bit(0)
            if v >= 18 { d.bl(0) }
        }, extraHandles: { h in h.handle(5, 0x12) }))
        add(0x30, line(handle: 0x30, owner: 0x12, Vec2(1, 0), Vec2(11, 0)))
        add(0x28, entity(type: 0x12, handle: 0x28, owner: nil, layer: 0x10, fields: { d, _ in
            d.p3(50, 200); d.bd(3); d.bit(1); d.bit(0)
            d.p3(0, 0, -1)
        }))
        add(0x29, entity(type: 0x01, handle: 0x29, owner: nil, layer: 0x10, fields: { d, s in
            d.rc(0xFF)      // nothing optional is stored
            d.rd(5); d.rd(7)
            d.bit(1); d.bit(1)
            d.rd(2.5)
            if v >= 21 { s.t16("Schrank %%c8") } else { d.t8("Schrank %%c8") }
        }))
        add(0x2A, entity(type: 0x15, handle: 0x2A, owner: nil, layer: 0x10, fields: { _, _ in }))
        return out
    }

    func objectMap(_ offsets: [(UInt64, Int)]) -> [UInt8] {
        var body: [UInt8] = []
        var h: UInt64 = 0, o = 0
        for (handle, offset) in offsets.sorted(by: { $0.0 < $1.0 }) {
            body += Self.mc(Int(handle - h))
            body += Self.mcSigned(offset - o)
            h = handle
            o = offset
        }
        let size = body.count + 2
        let parts: [[UInt8]] = [[UInt8(size >> 8), UInt8(size & 0xFF)], body, [0, 0], [0, 2, 0, 0]]
        return parts.flatMap { $0 }
    }

    static let ids = [15: "AC1015", 18: "AC1018", 21: "AC1021", 24: "AC1024", 27: "AC1027", 32: "AC1032"]

    func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
    func le64(_ n: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }

    // MARK: Packaging

    func file() -> [UInt8] {
        switch v {
        case 15: return r15()
        case 21: return r21()
        default: return r18()
        }
    }

    private func r15() -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 0x100)
        f.replaceSubrange(0..<6, with: Array(Self.ids[v]!.utf8))
        var offsets: [(UInt64, Int)] = []
        var blob: [UInt8] = []
        for (h, bytes) in objects() {
            offsets.append((h, 0x100 + blob.count))
            blob += bytes
        }
        let map = objectMap(offsets)
        let mapAt = 0x100 + blob.count
        f.replaceSubrange(0x15..<0x19, with: le32(3))
        for (i, record) in [(0, 0, 0), (1, 0, 0), (2, mapAt, map.count)].enumerated() {
            let at = 0x19 + i * 9
            f[at] = UInt8(record.0)
            f.replaceSubrange((at + 1)..<(at + 5), with: le32(record.1))
            f.replaceSubrange((at + 5)..<(at + 9), with: le32(record.2))
        }
        return f + blob + map
    }

    /// Literals only: valid R2004 compression without any back reference.
    private func packed18(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count >= 4)
        var out: [UInt8] = []
        if data.count <= 18 {
            out.append(UInt8(data.count - 3))
        } else {
            out.append(0)
            var rest = data.count - 3 - 0x0F
            while rest > 0xFF { out.append(0); rest -= 0xFF }
            out.append(UInt8(rest))
        }
        return out + data + [0x11]
    }

    private func r18() -> [UInt8] {
        var blob = le32(0x0DCA)
        var offsets: [(UInt64, Int)] = []
        for (h, bytes) in objects() {
            offsets.append((h, blob.count))
            blob += bytes
        }
        let map = objectMap(offsets)

        var f = [UInt8](repeating: 0, count: 0x100)
        f.replaceSubrange(0..<6, with: Array(Self.ids[v]!.utf8))
        var pages: [(number: Int, size: Int)] = []
        func align(_ b: inout [UInt8]) { while b.count % 0x20 != 0 { b.append(0) } }

        func dataPage(_ number: Int, _ content: [UInt8]) {
            let start = f.count
            let packed = packed18(content)
            var head = [UInt8](repeating: 0, count: 32)
            head.replaceSubrange(0..<4, with: le32(0x4163_043B))
            head.replaceSubrange(8..<12, with: le32(packed.count))
            let mask = 0x4164_536B ^ UInt32(truncatingIfNeeded: start)
            for i in 0..<8 {
                let at = i * 4
                let word = (0..<4).reduce(UInt32(0)) { $0 | UInt32(head[at + $1]) << UInt32($1 * 8) } ^ mask
                head.replaceSubrange(at..<(at + 4), with: le32(Int(word)))
            }
            f += head + packed
            align(&f)
            pages.append((number, f.count - start))
        }

        dataPage(1, blob)
        dataPage(2, map)

        // Section map
        var sectionMap: [UInt8] = [le32(2), le32(2), le32(0x7400), le32(0), le32(2)].flatMap { $0 }
        func describe(_ name: String, size: Int, page: Int) {
            var n = Array(name.utf8)
            n += [UInt8](repeating: 0, count: 64 - n.count)
            let parts: [[UInt8]] = [le64(size), le32(1), le32(max(size, 0x7400)), le32(0), le32(2), le32(page), le32(0),
                                    n, le32(page), le32(0), le64(0)]
            sectionMap += parts.flatMap { $0 }
        }
        describe("AcDb:AcDbObjects", size: blob.count, page: 1)
        describe("AcDb:Handles", size: map.count, page: 2)
        func systemPage(_ number: Int, type: Int, _ content: [UInt8]) {
            let start = f.count
            let packed = packed18(content)
            let parts: [[UInt8]] = [le32(type), le32(content.count), le32(packed.count), le32(2), le32(0), packed]
            f += parts.flatMap { $0 }
            align(&f)
            pages.append((number, f.count - start))
        }
        systemPage(4, type: 0x4163_003B, sectionMap)

        let pageMapAddress = f.count
        var pageMap: [UInt8] = []
        for p in pages { pageMap += le32(p.number) + le32(p.size) }
        pageMap += le32(5) + le32(0x400)
        systemPage(5, type: 0x4163_0E3B, pageMap)

        var head = [UInt8](repeating: 0, count: 0x6C)
        head.replaceSubrange(0..<11, with: Array("AcFssFcAJMB".utf8))
        head.replaceSubrange(0x54..<0x5C, with: le64(pageMapAddress - 0x100))
        head.replaceSubrange(0x5C..<0x60, with: le32(4))
        var seed: Int32 = 1
        for i in 0..<0x6C {
            seed = seed &* 0x343FD &+ 0x269EC3
            f[0x80 + i] = head[i] ^ UInt8(truncatingIfNeeded: seed >> 16)
        }
        return f
    }

    private func interleave(_ data: [UInt8], k: Int) -> [UInt8] {
        let padded = data + [UInt8](repeating: 0, count: (8 - data.count % 8) % 8)
        let blocks = (padded.count + k - 1) / k
        var out = [UInt8](repeating: 0, count: blocks * 255)
        for (i, byte) in padded.enumerated() {
            out[i / k + (i % k) * blocks] = byte
        }
        return out
    }

    private func r21() -> [UInt8] {
        var blob = le32(0x0DCA)
        var offsets: [(UInt64, Int)] = []
        for (h, bytes) in objects() {
            offsets.append((h, blob.count))
            blob += bytes
        }
        let map = objectMap(offsets)

        var stream: [UInt8] = []          // what follows 0x480
        var pageTable: [(id: Int, size: Int)] = []
        func page(_ id: Int, _ content: [UInt8]) {
            var bytes = content
            while bytes.count % 0x20 != 0 { bytes.append(0) }
            stream += bytes
            pageTable.append((id, bytes.count))
        }
        let objectsPage = interleave(blob, k: 251)
        let handlesPage = interleave(map, k: 251)
        page(1, objectsPage)
        page(2, handlesPage)

        var sectionMap: [UInt8] = []
        func describe(_ name: String, size: Int, id: Int) {
            var n: [UInt8] = []
            for unit in name.utf16 { n += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            n += [0, 0]
            let parts: [[UInt8]] = [le64(size), le64(0xF800), le64(0), le64(0), le64(n.count), le64(0), le64(4), le64(1), n,
                                    le64(0), le64(0), le64(id), le64(size), le64(size), le64(0), le64(0)]
            sectionMap += parts.flatMap { $0 }
        }
        describe("AcDb:AcDbObjects", size: blob.count, id: 1)
        describe("AcDb:Handles", size: map.count, id: 2)
        page(3, interleave(sectionMap, k: 239))

        var pageMap: [UInt8] = []
        for p in pageTable { pageMap += le64(p.size) + le64(p.id) }
        let pageMapOffset = stream.count
        page(4, interleave(pageMap, k: 239))

        var head = [UInt8](repeating: 0, count: 0x110)
        head.replaceSubrange(0x18..<0x20, with: le64(1))
        head.replaceSubrange(0x38..<0x40, with: le64(pageMapOffset))
        head.replaceSubrange(0x50..<0x58, with: le64(pageMap.count))
        head.replaceSubrange(0x58..<0x60, with: le64(pageMap.count))
        head.replaceSubrange(0xB0..<0xB8, with: le64(sectionMap.count))
        head.replaceSubrange(0xC0..<0xC8, with: le64(3))
        head.replaceSubrange(0xC8..<0xD0, with: le64(sectionMap.count))
        head.replaceSubrange(0xD8..<0xE0, with: le64(1))

        var block = [UInt8](repeating: 0, count: 0x20) + head
        block.replaceSubrange(0x18..<0x1C, with: le32(-head.count))
        block += [UInt8](repeating: 0, count: 3 * 239 - block.count)
        var f = [UInt8](repeating: 0, count: 0x480)
        f.replaceSubrange(0..<6, with: Array("AC1021".utf8))
        for (i, byte) in block.enumerated() { f[0x80 + i / 239 + (i % 239) * 3] = byte }
        return f + stream
    }
}

final class DWGImportTests: XCTestCase {
    private func check(_ r: DWGImportResult, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let sk = r.sketch
        var lines = 0, circles = 0, arcs = 0
        for c in sk.curves {
            switch c.geometry {
            case .line: lines += 1
            case .circle: circles += 1
            case .arc: arcs += 1
            default: break
            }
        }
        XCTAssertEqual(lines, 5, label, file: file, line: line)
        XCTAssertEqual(circles, 2, label, file: file, line: line)
        XCTAssertEqual(arcs, 2, label, file: file, line: line)
        XCTAssertEqual(r.textCount, 1, label, file: file, line: line)
        XCTAssertEqual(r.skipped[.dimension], 1, label, file: file, line: line)
    }

    private func has(_ sk: Sketch, _ p: Vec2) -> Bool { sk.points.contains { simd_length($0.position - p) < 1e-6 } }

    func testAllLayouts() throws {
        for v in [15, 18, 21, 24, 27, 32] {
            let r = try DWGImporter.importData(DWGTestFile(v: v).file())
            check(r, "version \(v)")
            let sk = r.sketch
            // The corners meet in shared points, so the rectangle is a closed area, and it starts at the sketch origin.
            XCTAssertTrue(sk.curves.contains { if case let .line(a, _) = $0.geometry { return a == Sketch.originId } else { return false } }, "\(v)")
            XCTAssertEqual(sk.points.filter { simd_length($0.position - Vec2(100, 0)) < 1e-6 }.count, 1, "\(v)")
            // Arc from 0° to 90° around (200, 0)
            XCTAssertTrue(has(sk, Vec2(210, 0)) && has(sk, Vec2(200, 10)), "\(v)")
            // Half circle of the polyline: bulge 1 from (300, 0) to (320, 0), counter-clockwise, so it runs below.
            let half = try XCTUnwrap(sk.curves.first { c in
                if case let .arc(m, _, _) = c.geometry, let center = sk.point(m) { return simd_length(center - Vec2(310, 0)) < 1e-6 }
                return false
            })
            let lowest = sk.polyline(half, segments: 32).map(\.y).min() ?? 0
            XCTAssertLessThan(lowest, -9.9, "\(v)")
            // Block: base (1, 0), scale 2, turned by 90°, placed at (400, 0): its line runs up 20 long.
            XCTAssertTrue(has(sk, Vec2(400, 0)) && has(sk, Vec2(400, 20)), "\(v)")
            // Circle with normal (0, 0, -1) lies mirrored at x = -50.
            XCTAssertTrue(sk.curves.contains { c in
                if case let .circle(m, rr) = c.geometry, let center = sk.point(m) { return rr == 3 && simd_length(center - Vec2(-50, 200)) < 1e-6 }
                return false
            }, "\(v)")
            let text = try XCTUnwrap(sk.curves.first { $0.isText })
            guard case let .text(_, s, h, _) = text.geometry else { return XCTFail() }
            XCTAssertEqual(s, "Schrank Ø8", "\(v)")
            XCTAssertEqual(h, 2.5, "\(v)")
            XCTAssertTrue(text.construction, "texts stay notes")
            // The rectangle is found as an area.
            var doc = CADDocument()
            let f = Feature(name: "Plan", kind: .sketch(sk))
            doc.features = [f]
            let regions = try XCTUnwrap(ModelBuilder().build(doc).sketches[f.id]?.regions)
            XCTAssertTrue(regions.contains { abs($0.area - (100 * 50 - .pi * 25)) < 1e-3 }, "\(v): \(regions.map(\.area))")
        }
    }

    func testBrokenFilesAreRefusedNotCrashed() {
        XCTAssertEqual(try? DWGImporter.importData([]).curveCount, nil)
        XCTAssertThrowsError(try DWGImporter.importData(Array("Das ist Text, keine Zeichnung".utf8))) {
            XCTAssertEqual($0 as? DWGImportError, .notDWG)
        }
        var old = [UInt8](repeating: 0, count: 0x200)
        old.replaceSubrange(0..<6, with: Array("AC1009".utf8))
        XCTAssertThrowsError(try DWGImporter.importData(old)) { XCTAssertEqual($0 as? DWGImportError, .unsupportedVersion("AC1009")) }
        // Passwords
        var locked = DWGTestFile(v: 18).file()
        locked[0x18] = 1
        XCTAssertThrowsError(try DWGImporter.importData(locked)) { XCTAssertEqual($0 as? DWGImportError, .passwordProtected) }

        // Random damage ends in a result or an error, never in a crash. The generator is seeded, a failure repeats.
        var random = SeededRandom(state: 0x6A78)
        for v in [15, 18, 21, 24, 32] {
            let good = DWGTestFile(v: v).file()
            for round in 0..<400 {
                var bytes = good
                switch round % 3 {
                case 0:
                    for _ in 0..<8 { bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random) }
                case 1:
                    bytes = Array(bytes[0..<Int.random(in: 0..<bytes.count, using: &random)])
                default:
                    for _ in 0..<60 { bytes[Int.random(in: 0..<min(bytes.count, 0x500), using: &random)] = UInt8.random(in: 0...255, using: &random) }
                }
                _ = try? DWGImporter.importData(bytes)
            }
        }
    }

    func testDecompressors() throws {
        // Four literals, then copy the last byte four times with an overlap, then one literal.
        let r18: [UInt8] = [0x01, 0x61, 0x62, 0x63, 0x64, 0x51, 0x00, 0x65, 0x11]
        XCTAssertEqual(String(decoding: try DWGDecompress.r18(r18, from: 0, count: r18.count, output: 64), as: UTF8.self), "abcddddde")
        XCTAssertThrowsError(try DWGDecompress.r18(r18, from: 0, count: r18.count, output: 4), "may not grow past its limit")

        // 16 literals are stored as their back half before their front half; then a copy of three.
        let literals = (0..<16).map { UInt8($0) }
        let r21: [UInt8] = [0x08] + literals + [0x30, 0x00]
        let out = try DWGDecompress.r21(r21, count: r21.count, output: 19)
        XCTAssertEqual(Array(out[0..<16]), Array(literals[8..<16] + literals[0..<8]))
        XCTAssertEqual(Array(out[16...]), [7, 7, 7])
    }

    func testUnitsBecomeMillimetres() throws {
        func sketch(units: Int) throws -> DWGImportResult {
            var d = DWGDrawing(version: 15, units: units)
            d.modelSpace = [DWGEntity(handle: 1, layer: 0, shape: .line(SIMD3(1, 0, 0), SIMD3(2, 0, 0)))]
            var flat = DWGFlattener(d)
            try flat.run()
            return try flat.result()
        }
        XCTAssertNotNil(try sketch(units: 1).sketch.points.first { abs($0.position.x - 50.8) < 1e-9 }, "inch")
        XCTAssertNotNil(try sketch(units: 6).sketch.points.first { abs($0.position.x - 2000) < 1e-9 }, "m")
        XCTAssertNil(try sketch(units: 0).unit, "no unit: read as mm and said so")
    }

    func testMoreThanASketchHolds() throws {
        var d = DWGDrawing(version: 15, units: 4)
        d.modelSpace = (0...DWGImporter.maxCurves).map { i in
            DWGEntity(handle: UInt64(i), layer: 0, shape: .line(SIMD3(Double(i), 0, 0), SIMD3(Double(i), 5, 0)))
        }
        var flat = DWGFlattener(d)
        XCTAssertThrowsError(try flat.run()) { XCTAssertEqual($0 as? DWGImportError, .tooLarge(limit: DWGImporter.maxCurves)) }
    }

    /// A block placed in itself, or a grid of grids, must not run forever.
    func testBlocksCannotUnfoldForever() throws {
        var d = DWGDrawing(version: 15, units: 4)
        let insert = { (block: UInt64) in
            DWGShape.insert(block: block, at: .zero, scale: SIMD3(1, 1, 1), rotation: 0, normal: SIMD3(0, 0, 1),
                            columns: 30000, rows: 30000, columnSpacing: 0, rowSpacing: 0)
        }
        d.blocks[1] = DWGBlock(name: "A", base: .zero, isXref: false)
        d.blockEntities[1] = [DWGEntity(handle: 2, layer: 0, shape: insert(1))]
        d.modelSpace = [DWGEntity(handle: 3, layer: 0, shape: insert(1))]
        var flat = DWGFlattener(d)
        XCTAssertThrowsError(try flat.run())
    }

    func testSparseSolverAgreesWithDense() {
        // Chain of lines with constraints: some parts fully determined, some free.
        var sk = Sketch(plane: .xy)
        var ids = [Sketch.originId]
        for i in 1...60 { ids.append(sk.addPoint(Vec2(Double(i) * 10, Double(i % 3)))) }
        var lines: [Int] = []
        for i in 0..<60 { lines.append(sk.addLine(ids[i], ids[i + 1])) }
        for i in 0..<20 {
            sk.addConstraint(.horizontal(line: lines[i]))
            sk.addConstraint(.length(line: lines[i], value: "10"))
        }
        sk.addArc(center: sk.addPoint(Vec2(0, 50)), start: sk.addPoint(Vec2(10, 50)), end: sk.addPoint(Vec2(0, 60)))
        sk.addCircle(center: sk.addPoint(Vec2(100, 100)), radius: 5)
        var dense = sk, sparse = sk
        let a = SketchSolver().solve(&dense)
        var solver = SketchSolver()
        solver.denseLimit = 0
        let b = solver.solve(&sparse)
        XCTAssertTrue(a.converged)
        XCTAssertTrue(b.converged)
        XCTAssertEqual(a.degreesOfFreedom, b.degreesOfFreedom)
        XCTAssertEqual(a.fullyConstrainedPoints, b.fullyConstrainedPoints)
        XCTAssertEqual(a.fullyConstrainedCurves, b.fullyConstrainedCurves)
        for p in dense.points {
            XCTAssertEqual(simd_length(p.position - sparse.point(p.id)!), 0, accuracy: 1e-4)
        }
    }

    /// Real files cannot go into the repository. With SIXAXIS_DWG_SAMPLES pointing at a folder of .dwg files this
    /// reads them, and with SIXAXIS_DWG_FUZZ it also damages them at random.
    func testRealFilesFromFolder() throws {
        guard let dir = ProcessInfo.processInfo.environment["SIXAXIS_DWG_SAMPLES"] else { throw XCTSkip("no samples") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".dwg") }.sorted()
        for f in files {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(f)))
            let start = Date()
            let r = try DWGImporter.importData(bytes)
            let read = Date().timeIntervalSince(start)
            var doc = CADDocument()
            let feature = Feature(name: f, kind: .sketch(r.sketch))
            doc.features = [feature]
            let built = Date()
            let sketch = ModelBuilder().build(doc).sketches[feature.id]
            print("DWG \(f): \(r.curveCount) curves, \(r.textCount) texts, \(sketch?.regions.count ?? -1) regions, converged \(sketch?.solve.converged ?? false), read \(read) s, built \(Date().timeIntervalSince(built)) s - \(r.summary)")
            fflush(stdout)
            guard ProcessInfo.processInfo.environment["SIXAXIS_DWG_FUZZ"] != nil else { continue }
            var random = SeededRandom(state: 0xD36)
            for round in 0..<90 {
                var b = bytes
                switch round % 3 {
                case 0: for _ in 0..<40 { b[Int.random(in: 0..<b.count, using: &random)] = UInt8.random(in: 0...255, using: &random) }
                case 1: b = Array(b[0..<Int.random(in: 0..<b.count, using: &random)])
                default: for _ in 0..<400 { b[Int.random(in: 0..<min(b.count, 4096), using: &random)] = UInt8.random(in: 0...255, using: &random) }
                }
                _ = try? DWGImporter.importData(b)
            }
            print("FUZZ \(f) survived"); fflush(stdout)
        }
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension DWGImportTests {
    /// Prints the file `dwgSample` in ModellingChecks.swift was made from.
    func testPrintFixture() throws {
        guard ProcessInfo.processInfo.environment["SIXAXIS_DWG_PRINT"] != nil else { throw XCTSkip("no") }
        print("B64 " + Data(DWGTestFile(v: 18).file()).base64EncodedString()); fflush(stdout)
    }
}
