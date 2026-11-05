import Foundation

/// Anything wrong with the bytes of a DWG file. The reader never trusts a size or an offset from the file:
/// a broken or hostile file ends in this error, not in a crash.
struct DWGCorrupt: Error {
    var what: String
    init(_ what: String = "") { self.what = what }
}

/// A handle reference: the code says how `value` relates to the object holding the reference.
struct DWGHandleRef {
    var code: Int
    var value: UInt64

    func resolved(from reference: UInt64) -> UInt64 {
        switch code {
        case 0x6: return reference &+ 1
        case 0x8: return reference &- 1
        case 0xA: return reference &+ value
        case 0xC: return reference &- value
        default: return value
        }
    }
}

/// Reads the DWG bit codes (chapter 2 of the Open Design Specification for .dwg files). Little-endian, every
/// read checks the end.
struct DWGBits {
    let bytes: [UInt8]
    /// Position and end in bits.
    var pos: Int
    var end: Int

    init(_ bytes: [UInt8], byte: Int = 0, endByte: Int? = nil) {
        self.bytes = bytes
        let last = min(max(endByte ?? bytes.count, 0), bytes.count)
        self.end = last * 8
        self.pos = min(max(byte, 0), last) * 8
    }

    var bytePosition: Int { (pos + 7) / 8 }
    var remaining: Int { end - pos }

    mutating func seek(bit: Int) throws {
        guard bit >= 0, bit <= end else { throw DWGCorrupt("seek") }
        pos = bit
    }

    mutating func skip(bytes n: Int) throws {
        guard n >= 0, n <= remaining / 8 else { throw DWGCorrupt("skip") }
        pos += n * 8
    }

    mutating func bit() throws -> Int {
        guard pos < end else { throw DWGCorrupt("end of data") }
        let b = (bytes[pos >> 3] >> UInt8(7 - (pos & 7))) & 1
        pos += 1
        return Int(b)
    }

    mutating func flag() throws -> Bool { try bit() == 1 }

    mutating func bits(_ n: Int) throws -> UInt64 {
        guard n >= 0, n <= 64, n <= remaining else { throw DWGCorrupt("end of data") }
        var v: UInt64 = 0
        for _ in 0..<n {
            v = (v << 1) | UInt64((bytes[pos >> 3] >> UInt8(7 - (pos & 7))) & 1)
            pos += 1
        }
        return v
    }

    mutating func bb() throws -> Int { Int(try bits(2)) }
    mutating func rc() throws -> UInt8 { UInt8(try bits(8)) }

    mutating func rs() throws -> UInt16 {
        let lo = UInt16(try rc())
        return lo | UInt16(try rc()) << 8
    }

    mutating func rl() throws -> UInt32 {
        let lo = UInt32(try rs())
        return lo | UInt32(try rs()) << 16
    }

    mutating func rd() throws -> Double {
        let lo = UInt64(try rl())
        return Double(bitPattern: lo | UInt64(try rl()) << 32)
    }

    mutating func point2R() throws -> Vec2 {
        let x = try rd()
        return Vec2(x, try rd())
    }

    mutating func bs() throws -> Int {
        switch try bb() {
        case 0: return Int(Int16(bitPattern: try rs()))
        case 1: return Int(try rc())
        case 2: return 0
        default: return 256
        }
    }

    mutating func bl() throws -> Int {
        switch try bb() {
        case 0: return Int(Int32(bitPattern: try rl()))
        case 1: return Int(try rc())
        case 2: return 0
        default: throw DWGCorrupt("BL")
        }
    }

    /// A bit triplet: 1 to 3 bits, ended by a zero.
    mutating func b3() throws -> Int {
        var v = 0
        for _ in 0..<3 {
            let b = try bit()
            v = v << 1 | b
            if b == 0 { break }
        }
        return v
    }

    mutating func bll() throws -> UInt64 {
        let n = try b3()
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(try rc()) << UInt64(8 * i) }
        return v
    }

    mutating func bd() throws -> Double {
        switch try bb() {
        case 0: return try rd()
        case 1: return 1
        case 2: return 0
        default: throw DWGCorrupt("BD")
        }
    }

    mutating func point3() throws -> SIMD3<Double> {
        let x = try bd(), y = try bd()
        return SIMD3(x, y, try bd())
    }

    /// A bit double that patches the bytes of a default value.
    mutating func dd(default d: Double) throws -> Double {
        switch try bb() {
        case 0: return d
        case 1:
            let low = UInt64(try rl())
            return Double(bitPattern: (d.bitPattern & 0xFFFF_FFFF_0000_0000) | low)
        case 2:
            let mid = UInt64(try rs())
            let low = UInt64(try rl())
            return Double(bitPattern: (d.bitPattern & 0xFFFF_0000_0000_0000) | mid << 32 | low)
        default: return try rd()
        }
    }

    /// Extrusion: R2000 and later store the usual (0, 0, 1) as a single bit.
    mutating func extrusion(_ version: Int) throws -> SIMD3<Double> {
        if version >= 15, try flag() { return SIMD3(0, 0, 1) }
        return try point3()
    }

    mutating func thickness(_ version: Int) throws -> Double {
        if version >= 15, try flag() { return 0 }
        return try bd()
    }

    /// Modular char. A signed one carries its sign in bit 0x40 of the last byte.
    mutating func mc(signed: Bool = false) throws -> Int {
        var v = 0
        var shift = 0
        while true {
            let b = Int(try rc())
            if b & 0x80 == 0 {
                guard shift <= 56 else { throw DWGCorrupt("MC") }
                if signed {
                    v |= (b & 0x3F) << shift
                    return b & 0x40 != 0 ? -v : v
                }
                return v | (b << shift)
            }
            guard shift <= 56 else { throw DWGCorrupt("MC") }
            v |= (b & 0x7F) << shift
            shift += 7
        }
    }

    mutating func ms() throws -> Int {
        var v = 0
        var shift = 0
        while true {
            let w = Int(try rs())
            guard shift <= 45 else { throw DWGCorrupt("MS") }
            v |= (w & 0x7FFF) << shift
            if w & 0x8000 == 0 { return v }
            shift += 15
        }
    }

    mutating func handle() throws -> DWGHandleRef {
        let code = Int(try bits(4))
        let count = Int(try bits(4))
        guard count <= 8 else { throw DWGCorrupt("handle") }
        var v: UInt64 = 0
        for _ in 0..<count { v = v << 8 | UInt64(try rc()) }
        return DWGHandleRef(code: code, value: v)
    }

    /// Text with a single byte per character (R2004 and earlier).
    mutating func text8() throws -> String {
        let n = try bs()
        guard n >= 0, n <= remaining / 8 else { throw DWGCorrupt("text") }
        var chars = [UInt8]()
        chars.reserveCapacity(n)
        for _ in 0..<n { chars.append(try rc()) }
        if let zero = chars.firstIndex(of: 0) { chars.removeSubrange(zero...) }
        return String(data: Data(chars), encoding: .utf8)
            ?? String(data: Data(chars), encoding: .windowsCP1252)
            ?? ""
    }

    /// Unicode text (R2007 and later).
    mutating func text16() throws -> String {
        let n = try bs()
        guard n >= 0, n <= remaining / 16 else { throw DWGCorrupt("text") }
        var units = [UInt16]()
        units.reserveCapacity(n)
        for _ in 0..<n { units.append(try rs()) }
        if let zero = units.firstIndex(of: 0) { units.removeSubrange(zero...) }
        return String(decoding: units, as: UTF16.self)
    }

    /// The object type of R2010 and later: a bit pair and one or two bytes.
    mutating func objectType(_ version: Int) throws -> Int {
        guard version >= 24 else { return try bs() }
        switch try bb() {
        case 0: return Int(try rc())
        case 1: return Int(try rc()) + 0x1F0
        default: return Int(try rs())
        }
    }
}
