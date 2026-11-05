import Foundation

/// The parts of a DWG file the importer needs, freed from the packaging of the file's version.
struct DWGSections {
    /// 13, 14 and 15 (R2000), 18 (R2004), 21 (R2007), 24 (R2010), 27 (R2013), 32 (R2018).
    var version: Int
    var maintenance: Int
    var header: [UInt8]
    var classes: [UInt8]
    var handles: [UInt8]
    var objects: [UInt8]
}

enum DWGContainer {
    /// Limits for what the file may ask for, so that a small hostile file cannot fill the memory.
    private static let maxSectionSize = 512 * 1024 * 1024
    private static let maxPageSize = 64 * 1024 * 1024

    static let versions: [String: Int] = [
        "AC1012": 13, "AC1014": 14, "AC1015": 15, "AC1018": 18,
        "AC1021": 21, "AC1024": 24, "AC1027": 27, "AC1032": 32,
    ]

    static func read(_ file: [UInt8]) throws -> DWGSections {
        guard file.count >= 0x100 else { throw DWGImportError.notDWG }
        let id = String(decoding: file[0..<6], as: UTF8.self)
        guard id.hasPrefix("AC") else { throw DWGImportError.notDWG }
        guard let version = versions[id] else { throw DWGImportError.unsupportedVersion(id) }
        switch version {
        case ..<18: return try readR13(file, version: version)
        case 21: return try readR21(file)
        default: return try readR18(file, version: version)
        }
    }

    // MARK: Little helpers

    static func u32(_ b: [UInt8], _ at: Int) throws -> UInt32 {
        guard at >= 0, at <= b.count - 4 else { throw DWGCorrupt("u32") }
        return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    static func i32(_ b: [UInt8], _ at: Int) throws -> Int { Int(Int32(bitPattern: try u32(b, at))) }

    static func u64(_ b: [UInt8], _ at: Int) throws -> UInt64 {
        let lo = UInt64(try u32(b, at))
        return lo | UInt64(try u32(b, at + 4)) << 32
    }

    /// A 64-bit size or offset that has to be a sensible, positive `Int`.
    static func size(_ b: [UInt8], _ at: Int) throws -> Int {
        let v = try u64(b, at)
        guard v <= UInt64(Int32.max) * 4 else { throw DWGCorrupt("size") }
        return Int(v)
    }

    // MARK: R13 to R2000: plain sections at known addresses

    private static func readR13(_ file: [UInt8], version: Int) throws -> DWGSections {
        let count = try i32(file, 0x15)
        guard (1...64).contains(count) else { throw DWGCorrupt("locators") }
        var records: [Int: (seek: Int, size: Int)] = [:]
        for i in 0..<count {
            let at = 0x19 + i * 9
            guard at + 9 <= file.count else { throw DWGCorrupt("locators") }
            records[Int(file[at])] = (try i32(file, at + 1), try i32(file, at + 5))
        }
        func section(_ n: Int) throws -> [UInt8] {
            guard let r = records[n], r.seek >= 0, r.size >= 0, r.seek <= file.count, r.size <= file.count - r.seek
            else { throw DWGCorrupt("section \(n)") }
            return Array(file[r.seek..<(r.seek + r.size)])
        }
        return DWGSections(version: version, maintenance: Int(file[0x0B]),
                           header: (try? section(0)) ?? [], classes: (try? section(1)) ?? [],
                           handles: try section(2), objects: file)
    }

    // MARK: R2004, R2010, R2013, R2018: compressed pages

    /// The bytes that mask the file header data at 0x80, and also fill gaps in the file.
    private static func magicSequence() -> [UInt8] {
        var seed: Int32 = 1
        return (0..<0x6C).map { _ in
            seed = seed &* 0x343FD &+ 0x269EC3
            return UInt8(truncatingIfNeeded: seed >> 16)
        }
    }

    private static func systemPage(_ file: [UInt8], at address: Int, type: UInt32) throws -> [UInt8] {
        guard try u32(file, address) == type else { throw DWGCorrupt("system page") }
        let plain = try i32(file, address + 4)
        let packed = try i32(file, address + 8)
        guard plain >= 0, plain <= maxPageSize, packed >= 0, address + 0x14 <= file.count, packed <= file.count - address - 0x14
        else { throw DWGCorrupt("system page") }
        return try DWGDecompress.r18(file, from: address + 0x14, count: packed, output: plain)
    }

    private static func readR18(_ file: [UInt8], version: Int) throws -> DWGSections {
        guard try i32(file, 0x18) & 1 == 0 else { throw DWGImportError.passwordProtected }
        let magic = magicSequence()
        let head = (0..<0x6C).map { file[0x80 + $0] ^ magic[$0] }
        guard String(decoding: head[0..<11], as: UTF8.self) == "AcFssFcAJMB" else { throw DWGCorrupt("file header") }
        let pageMapAddress = try size(head, 0x54) + 0x100
        let sectionMapId = try i32(head, 0x5C)

        // Section page map: page number and size, the addresses add up from 0x100.
        let pageMap = try systemPage(file, at: pageMapAddress, type: 0x4163_0E3B)
        var pages: [Int: Int] = [:]
        var address = 0x100
        var at = 0
        while at + 8 <= pageMap.count {
            let number = try i32(pageMap, at)
            let pageSize = try i32(pageMap, at + 4)
            at += 8
            guard pageSize >= 0, pageSize <= file.count else { throw DWGCorrupt("page map") }
            if number < 0 { at += 16 } else { pages[number] = address }
            address += pageSize
        }

        guard let sectionMapAddress = pages[sectionMapId] else { throw DWGCorrupt("section map") }
        let map = try systemPage(file, at: sectionMapAddress, type: 0x4163_003B)
        let descriptions = try i32(map, 0)
        guard (0...256).contains(descriptions) else { throw DWGCorrupt("section map") }

        var found: [String: [UInt8]] = [:]
        at = 0x14
        for _ in 0..<descriptions {
            guard at + 0x60 <= map.count else { throw DWGCorrupt("section map") }
            let sectionSize = try size(map, at)
            let pageCount = try i32(map, at + 8)
            let maxPage = try i32(map, at + 0x0C)
            let compressed = try i32(map, at + 0x14)
            let encrypted = try i32(map, at + 0x1C)
            let nameBytes = map[(at + 0x20)..<(at + 0x60)].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            at += 0x60
            guard pageCount >= 0, pageCount <= (map.count - at) / 16 else { throw DWGCorrupt("section map") }
            defer { at += pageCount * 16 }
            guard Self.wanted.contains(name) else { continue }
            guard encrypted != 1 else { throw DWGImportError.passwordProtected }
            guard sectionSize <= maxSectionSize, maxPage > 0, maxPage <= maxPageSize else { throw DWGCorrupt("section size") }

            var section = [UInt8](repeating: 0, count: sectionSize)
            for p in 0..<pageCount {
                let entry = at + p * 16
                let start = try size(map, entry + 8)
                guard let page = pages[try i32(map, entry)] else { throw DWGCorrupt("missing page") }
                guard page + 32 <= file.count, start <= sectionSize else { throw DWGCorrupt("page") }
                let mask = 0x4164_536B ^ UInt32(truncatingIfNeeded: page)
                guard try u32(file, page) ^ mask == 0x4163_043B else { throw DWGCorrupt("page header") }
                let dataSize = Int(try u32(file, page + 8) ^ mask)
                guard dataSize <= file.count - page - 32 else { throw DWGCorrupt("page data") }
                let logical = min(maxPage, sectionSize - start)
                if compressed == 2 {
                    let plain = try DWGDecompress.r18(file, from: page + 32, count: dataSize, output: maxPage)
                    let n = min(logical, plain.count)
                    section.replaceSubrange(start..<(start + n), with: plain[0..<n])
                } else {
                    guard logical <= dataSize else { throw DWGCorrupt("page data") }
                    section.replaceSubrange(start..<(start + logical), with: file[(page + 32)..<(page + 32 + logical)])
                }
            }
            found[name] = section
        }
        return try sections(found, version: version, maintenance: Int(file[0x0B]))
    }

    private static let wanted: Set<String> = ["AcDb:Header", "AcDb:Classes", "AcDb:Handles", "AcDb:AcDbObjects"]

    private static func sections(_ found: [String: [UInt8]], version: Int, maintenance: Int) throws -> DWGSections {
        guard let handles = found["AcDb:Handles"], let objects = found["AcDb:AcDbObjects"] else {
            throw DWGCorrupt("sections missing")
        }
        return DWGSections(version: version, maintenance: maintenance,
                           header: found["AcDb:Header"] ?? [], classes: found["AcDb:Classes"] ?? [],
                           handles: handles, objects: objects)
    }

    // MARK: R2007: Reed-Solomon encoded pages

    /// Takes the data bytes out of interleaved Reed-Solomon blocks. A healthy file needs no correction, and a
    /// damaged one is caught later by its broken contents.
    private static func deinterleave(_ file: [UInt8], at start: Int, blocks: Int, dataPerBlock k: Int) throws -> [UInt8] {
        guard blocks >= 0, blocks <= (file.count - min(start, file.count)) / 255, start >= 0 else { throw DWGCorrupt("page") }
        var out = [UInt8](repeating: 0, count: blocks * k)
        for b in 0..<blocks {
            for i in 0..<k { out[b * k + i] = file[start + b + i * blocks] }
        }
        return out
    }

    private static func align8(_ n: Int) -> Int { (n + 7) & ~7 }

    private static func systemPageR21(_ file: [UInt8], at start: Int, packed: Int, plain: Int, factor: Int) throws -> [UInt8] {
        guard packed >= 0, plain >= 0, plain <= maxPageSize, packed <= file.count, factor >= 1, factor <= 1024 else {
            throw DWGCorrupt("system page")
        }
        let blocks = (align8(packed) * factor + 238) / 239
        let data = try deinterleave(file, at: start, blocks: blocks, dataPerBlock: 239)
        guard packed <= data.count else { throw DWGCorrupt("system page") }
        if packed < plain { return try DWGDecompress.r21(data, count: packed, output: plain) }
        return Array(data[0..<min(packed, plain)])
    }

    private static func readR21(_ file: [UInt8]) throws -> DWGSections {
        guard try i32(file, 0x18) & 1 == 0 else { throw DWGImportError.passwordProtected }
        let block = try deinterleave(file, at: 0x80, blocks: 3, dataPerBlock: 239)
        let packedHeader = try i32(block, 0x18)
        let head: [UInt8]
        if packedHeader < 0 {
            guard -packedHeader <= block.count - 0x20 else { throw DWGCorrupt("file header") }
            head = Array(block[0x20..<(0x20 - packedHeader)])
        } else {
            guard packedHeader <= block.count - 0x20 else { throw DWGCorrupt("file header") }
            head = try DWGDecompress.r21(Array(block[0x20...]), count: packedHeader, output: 0x110)
        }
        guard head.count >= 0xF0 else { throw DWGCorrupt("file header") }

        // Page map: size and id, the addresses add up from the start of the page data.
        let base = 0x480
        let map = try systemPageR21(file, at: base + (try size(head, 0x38)), packed: try size(head, 0x50),
                                    plain: try size(head, 0x58), factor: try size(head, 0x18))
        var pages: [Int: Int] = [:]
        var offset = 0
        var at = 0
        while at + 16 <= map.count {
            let pageSize = try size(map, at)
            let id = Int(Int64(bitPattern: try u64(map, at + 8)))
            at += 16
            guard id != Int.min else { throw DWGCorrupt("page map") }
            pages[abs(id)] = offset
            guard pageSize <= file.count else { throw DWGCorrupt("page map") }
            offset += pageSize
        }

        guard let sectionMapOffset = pages[try size(head, 0xC0)] else { throw DWGCorrupt("section map") }
        let sectionMap = try systemPageR21(file, at: base + sectionMapOffset, packed: try size(head, 0xB0),
                                           plain: try size(head, 0xC8), factor: try size(head, 0xD8))
        var found: [String: [UInt8]] = [:]
        at = 0
        while at + 0x40 <= sectionMap.count {
            let dataSize = try size(sectionMap, at)
            let encrypted = try u64(sectionMap, at + 0x10)
            let nameLength = try size(sectionMap, at + 0x20)
            let encoding = try size(sectionMap, at + 0x30)
            let pageCount = try size(sectionMap, at + 0x38)
            at += 0x40
            // The length counts bytes, including the closing zero.
            guard nameLength <= sectionMap.count - at else { throw DWGCorrupt("section map") }
            var units: [UInt16] = []
            for c in 0..<(nameLength / 2) {
                let unit = UInt16(sectionMap[at + 2 * c]) | UInt16(sectionMap[at + 2 * c + 1]) << 8
                if unit == 0 { break }
                units.append(unit)
            }
            let name = String(decoding: units, as: UTF16.self)
            at += nameLength
            guard pageCount <= (sectionMap.count - min(at, sectionMap.count)) / 56 else { throw DWGCorrupt("section map") }
            defer { at += pageCount * 56 }
            guard Self.wanted.contains(name) else { continue }
            guard encrypted != 1 else { throw DWGImportError.passwordProtected }
            guard dataSize <= maxSectionSize else { throw DWGCorrupt("section size") }

            var section = [UInt8](repeating: 0, count: dataSize)
            for p in 0..<pageCount {
                let entry = at + p * 56
                let start = try size(sectionMap, entry)
                let id = try size(sectionMap, entry + 0x10)
                let plain = try size(sectionMap, entry + 0x18)
                let packed = try size(sectionMap, entry + 0x20)
                guard let pageOffset = pages[id], plain <= maxPageSize, packed <= file.count, start <= dataSize
                else { throw DWGCorrupt("page") }
                let stored: [UInt8]
                if encoding == 4 {
                    let blocks = (align8(packed) + 250) / 251
                    stored = try deinterleave(file, at: base + pageOffset, blocks: blocks, dataPerBlock: 251)
                } else {
                    guard base + pageOffset <= file.count, packed <= file.count - base - pageOffset else { throw DWGCorrupt("page") }
                    stored = Array(file[(base + pageOffset)..<(base + pageOffset + packed)])
                }
                guard packed <= stored.count else { throw DWGCorrupt("page") }
                let content = packed < plain ? try DWGDecompress.r21(stored, count: packed, output: plain)
                                             : Array(stored[0..<min(packed, plain)])
                let n = min(content.count, dataSize - start)
                section.replaceSubrange(start..<(start + n), with: content[0..<n])
            }
            found[name] = section
        }
        return try sections(found, version: 21, maintenance: Int(file[0x0B]))
    }
}

enum DWGDecompress {
    // MARK: R2004 (chapter 4.7)

    static func r18(_ src: [UInt8], from start: Int, count: Int, output: Int) throws -> [UInt8] {
        guard start >= 0, count >= 0, start <= src.count, count <= src.count - start, output >= 0 else {
            throw DWGCorrupt("compressed data")
        }
        let end = start + count
        var i = start
        var out = [UInt8]()
        out.reserveCapacity(output)

        func next() throws -> Int {
            guard i < end else { throw DWGCorrupt("compressed data") }
            defer { i += 1 }
            return Int(src[i])
        }

        func literalLength() throws -> Int {
            guard i < end else { return 0 }
            let b = Int(src[i])
            if b & 0xF0 != 0 { return 0 }     // no literals: this byte is already the next opcode
            i += 1
            if b != 0 { return b + 3 }
            var total = 0x0F
            while true {
                let n = try next()
                if n != 0 { return total + n + 3 }
                total += 0xFF
                guard total <= output + 0xFF else { throw DWGCorrupt("compressed data") }
            }
        }

        func longLength() throws -> Int {
            var total = 0
            var b = try next()
            if b != 0 { return b }
            total = 0xFF
            while true {
                b = try next()
                if b != 0 { return total + b }
                total += 0xFF
                guard total <= output + 0xFF else { throw DWGCorrupt("compressed data") }
            }
        }

        func twoByteOffset() throws -> (offset: Int, literals: Int) {
            let first = try next()
            let second = try next()
            return ((first >> 2) | (second << 6), first & 3)
        }

        func copyLiterals(_ n: Int) throws {
            guard n <= end - i, n <= output - out.count else { throw DWGCorrupt("compressed data") }
            out.append(contentsOf: src[i..<(i + n)])
            i += n
        }

        try copyLiterals(try literalLength())
        while true {
            let op = try next()
            if op == 0x11 { return out }
            var length: Int
            var offset: Int
            var literals: Int
            switch op {
            case 0x00...0x0F:
                throw DWGCorrupt("compressed data")
            case 0x10, 0x12...0x1F:
                length = op == 0x10 ? try longLength() + 9 : (op & 0x0F) + 2
                (offset, literals) = try twoByteOffset()
                offset += 0x3FFF
                if literals == 0 { literals = try literalLength() }
            case 0x20...0x3F:
                length = op == 0x20 ? try longLength() + 0x21 : op - 0x1E
                (offset, literals) = try twoByteOffset()
                if literals == 0 { literals = try literalLength() }
            default:
                length = (op >> 4) - 1
                offset = (try next() << 2) | ((op & 0x0C) >> 2)
                literals = op & 3
                if literals == 0 { literals = try literalLength() }
            }
            let from = out.count - offset - 1
            guard from >= 0, length <= output - out.count else { throw DWGCorrupt("compressed data") }
            for k in 0..<length { out.append(out[from + k]) }   // may overlap: byte by byte
            try copyLiterals(literals)
        }
    }

    // MARK: R2007 (chapter 5.10)

    /// How the literal blocks of 1 to 32 bytes are stored: pieces of (length, source position), written one after
    /// the other.
    private static let literalOrder: [[(Int, Int)]] = [
        [],
        [(1, 0)], [(1, 1), (1, 0)], [(1, 2), (1, 1), (1, 0)], [(1, 0), (1, 1), (1, 2), (1, 3)],
        [(1, 4), (4, 0)], [(1, 5), (4, 1), (1, 0)], [(2, 5), (4, 1), (1, 0)], [(4, 0), (4, 4)],
        [(1, 8), (8, 0)], [(1, 9), (8, 1), (1, 0)], [(2, 9), (8, 1), (1, 0)], [(4, 8), (8, 0)],
        [(1, 12), (4, 8), (8, 0)], [(1, 13), (4, 9), (8, 1), (1, 0)], [(2, 13), (4, 9), (8, 1), (1, 0)], [(8, 8), (8, 0)],
        [(8, 9), (1, 8), (8, 0)], [(1, 17), (16, 1), (1, 0)], [(3, 16), (16, 0)], [(4, 16), (16, 0)],
        [(1, 20), (4, 16), (16, 0)], [(2, 20), (4, 16), (16, 0)], [(3, 20), (4, 16), (16, 0)], [(8, 16), (16, 0)],
        [(8, 17), (1, 16), (16, 0)], [(1, 25), (8, 17), (1, 16), (16, 0)], [(2, 25), (8, 17), (1, 16), (16, 0)],
        [(4, 24), (8, 16), (16, 0)], [(1, 28), (4, 24), (8, 16), (16, 0)], [(2, 28), (4, 24), (8, 16), (16, 0)],
        [(1, 30), (4, 26), (8, 18), (16, 2), (2, 0)], [(16, 16), (16, 0)],
    ]

    static func r21(_ src: [UInt8], count: Int, output: Int) throws -> [UInt8] {
        guard count > 0, count <= src.count, output >= 0 else { throw DWGCorrupt("compressed data") }
        var out = [UInt8](repeating: 0, count: output)
        var o = 0
        var i = 0
        var op = Int(src[0])
        var length = 0

        func next() throws -> Int {
            guard i < count else { throw DWGCorrupt("compressed data") }
            defer { i += 1 }
            return Int(src[i])
        }

        if op >> 4 == 2 {
            guard count > 3 else { throw DWGCorrupt("compressed data") }
            length = Int(src[3]) & 7
            i = 4
        } else {
            i = 1
        }

        /// A piece of the table is itself stored in the order the table gives for its size.
        func writeLiterals(_ size: Int, from at: Int) {
            if size == 1 {
                out[o] = src[at]
                o += 1
                return
            }
            for (part, offset) in literalOrder[size] { writeLiterals(part, from: at + offset) }
        }

        func copyLiterals(_ n: Int) throws {
            guard n <= count - i, n <= output - o else { throw DWGCorrupt("compressed data") }
            var left = n
            while left > 0 {
                let piece = min(left, 32)
                writeLiterals(piece, from: i)
                i += piece
                left -= piece
            }
        }

        /// Reads one copy instruction; `op` becomes the byte that says what comes next.
        func instruction() throws -> (offset: Int, length: Int) {
            var offset: Int
            var n: Int
            switch op >> 4 {
            case 0:
                n = (op & 0xF) + 0x13
                offset = try next()
                op = try next()
                n += (op >> 3) & 0x10
                offset += ((op & 0x78) << 5) + 1
            case 1:
                n = (op & 0xF) + 3
                offset = try next()
                op = try next()
                offset += ((op & 0xF8) << 5) + 1
            case 2:
                offset = try next()
                offset |= (try next() << 8) & 0xFF00
                n = op & 7
                if op & 8 == 0 {
                    op = try next()
                    n += op & 0xF8
                } else {
                    offset += 1
                    n += try next() << 3
                    op = try next()
                    n += ((op & 0xF8) << 8) + 0x100
                }
            default:
                n = op >> 4
                offset = op & 15
                op = try next()
                offset += ((op & 0xF8) << 1) + 1
            }
            return (offset, n)
        }

        while i < count {
            if length == 0 {
                length = op + 8
                if length == 0x17 {
                    var n = try next()
                    length += n
                    if n == 0xFF {
                        repeat {
                            n = try next()
                            n |= try next() << 8
                            length += n
                        } while n == 0xFFFF
                    }
                }
            }
            try copyLiterals(length)
            length = 0
            if i >= count { break }

            op = try next()
            var copy = try instruction()
            while true {
                guard copy.offset <= o, copy.offset > 0, copy.length <= output - o else { throw DWGCorrupt("compressed data") }
                for k in 0..<copy.length { out[o + k] = out[o - copy.offset + k] }
                o += copy.length
                length = op & 7
                if length != 0 || i >= count { break }
                op = try next()
                if op >> 4 == 0 { break }
                if op >> 4 == 15 { op &= 15 }
                copy = try instruction()
            }
        }
        return out
    }
}
