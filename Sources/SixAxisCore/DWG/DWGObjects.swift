import Foundation
import simd

/// What a DWG entity draws, in the coordinates it is stored in.
enum DWGShape {
    case line(SIMD3<Double>, SIMD3<Double>)
    case circle(center: SIMD3<Double>, radius: Double, normal: SIMD3<Double>)
    case arc(center: SIMD3<Double>, radius: Double, start: Double, end: Double, normal: SIMD3<Double>)
    /// Lightweight or 2D polyline in its own plane. `bulges` is empty or one per vertex.
    case polyline(points: [Vec2], bulges: [Double], closed: Bool, normal: SIMD3<Double>)
    case polyline3D(points: [SIMD3<Double>], closed: Bool)
    case ellipse(center: SIMD3<Double>, major: SIMD3<Double>, ratio: Double, start: Double, end: Double, normal: SIMD3<Double>)
    case fitSpline(points: [SIMD3<Double>], closed: Bool)
    case nurbs(degree: Int, knots: [Double], control: [SIMD3<Double>], weights: [Double], closed: Bool)
    case text(String, at: SIMD3<Double>, height: Double, rotation: Double, normal: SIMD3<Double>)
    case mtext(String, at: SIMD3<Double>, height: Double, xAxis: SIMD3<Double>, attachment: Int, width: Double, normal: SIMD3<Double>)
    case insert(block: UInt64, at: SIMD3<Double>, scale: SIMD3<Double>, rotation: Double, normal: SIMD3<Double>,
                columns: Int, rows: Int, columnSpacing: Double, rowSpacing: Double)
}

/// A kind of entity the importer leaves out, for the message after the import.
public enum DWGSkipped: String, Hashable, CaseIterable, Sendable {
    case dimension, hatch, solid3D, tilted, rotatedText, other
}

struct DWGEntity {
    var handle: UInt64
    var layer: UInt64
    var shape: DWGShape
}

struct DWGBlock {
    var name: String
    var base: SIMD3<Double>
    var isXref: Bool
}

struct DWGLayer {
    var name: String
    var visible: Bool
}

/// The objects of a drawing, sorted by who owns them.
struct DWGDrawing {
    var version: Int
    /// The drawing's $INSUNITS, 0 when it has none or it could not be read.
    var units: Int
    var modelSpace: [DWGEntity] = []
    var blocks: [UInt64: DWGBlock] = [:]
    var blockEntities: [UInt64: [DWGEntity]] = [:]
    var layers: [UInt64: DWGLayer] = [:]
    /// Left out, by kind. Inside blocks these count once per definition, not per insert.
    var skipped: [DWGSkipped: Int] = [:]
}

enum DWGReader {
    static func read(_ file: [UInt8]) throws -> DWGDrawing {
        let sections = try DWGContainer.read(file)
        let v = sections.version
        let classes = (try? readClasses(sections)) ?? [:]
        let map = try readObjectMap(sections.handles)
        guard !map.isEmpty else { throw DWGCorrupt("no objects") }

        var drawing = DWGDrawing(version: v, units: (try? readUnits(sections)) ?? 0)
        var raw = RawObjects()
        for (handle, offset) in map {
            // A damaged object costs that object, not the whole drawing. The check after the loop catches files
            // where nothing could be read.
            do {
                try readObject(sections.objects, at: offset, handle: handle, version: v, classes: classes, into: &raw)
            } catch {
                raw.damaged += 1
            }
        }
        guard raw.damaged * 2 <= map.count else { throw DWGCorrupt("too many damaged objects") }
        assemble(raw, into: &drawing)
        return drawing
    }

    // MARK: Object map (chapter 23)

    static func readObjectMap(_ data: [UInt8]) throws -> [(handle: UInt64, offset: Int)] {
        var out: [(handle: UInt64, offset: Int)] = []
        var at = 0
        while at + 2 <= data.count {
            let size = Int(data[at]) << 8 | Int(data[at + 1])
            if size <= 2 { break }
            guard size <= data.count - at else { throw DWGCorrupt("object map") }
            var r = DWGBits(data, byte: at + 2, endByte: at + size)
            // Each part of the map counts from zero again.
            var handle: UInt64 = 0
            var offset = 0
            while r.remaining > 0 {
                handle = handle &+ UInt64(truncatingIfNeeded: try r.mc())
                offset = offset &+ (try r.mc(signed: true))
                out.append((handle, offset))
            }
            at += size + 2     // the section's CRC is not part of its size
        }
        return out
    }

    // MARK: Classes: only R14 and earlier need them, because LWPOLYLINE got its fixed type number in R2000

    private static func readClasses(_ s: DWGSections) throws -> [Int: String] {
        guard s.version <= 15, s.classes.count > 20 else { return [:] }
        var r = DWGBits(s.classes, byte: 16)
        let size = Int(try r.rl())
        let end = 20 + size
        guard size >= 0, end <= s.classes.count else { throw DWGCorrupt("classes") }
        var out: [Int: String] = [:]
        while r.pos < end * 8 - 8 {
            let number = try r.bs()
            _ = try r.bs()
            _ = try r.text8()
            _ = try r.text8()
            out[number] = try r.text8()
            _ = try r.flag()
            _ = try r.bs()
        }
        return out
    }

    // MARK: Header variables (chapter 9): walks to $INSUNITS

    private static func readUnits(_ s: DWGSections) throws -> Int {
        guard s.header.count > 32 else { return 0 }
        let v = s.version
        // What stands between the sentinel and the first variable varies with version and maintenance release. That
        // variable has a known value, so it marks the place.
        var r = DWGBits(s.header)
        var synced = false
        for bit in (20 * 8)..<(48 * 8) {
            r.pos = bit
            if let first = try? r.bd(), abs(first - 412148564080) < 1 {
                synced = true
                break
            }
        }
        guard synced else { return 0 }
        // From R2007 on, texts and handles live in their own streams, so they take no room here.
        func tv() throws { if v < 21 { _ = try r.text8() } }
        func h() throws { if v < 21 { _ = try r.handle() } }
        func bits(_ n: Int) throws { for _ in 0..<n { _ = try r.bit() } }
        func bs(_ n: Int = 1) throws { for _ in 0..<n { _ = try r.bs() } }
        func bl(_ n: Int = 1) throws { for _ in 0..<n { _ = try r.bl() } }
        func bd(_ n: Int = 1) throws { for _ in 0..<n { _ = try r.bd() } }
        func p3(_ n: Int = 1) throws { for _ in 0..<n { _ = try r.point3() } }
        func cmc() throws {
            _ = try r.bs()
            guard v >= 18 else { return }
            _ = try r.bl()
            let flags = try r.rc()
            if flags & 1 != 0 { try tv() }
            if flags & 2 != 0 { try tv() }
        }
        func ucs() throws {
            try p3(3)
            _ = try r.point2R()
            _ = try r.point2R()
            try bd()
            try p3(3)
            try h()
            if v >= 15 {
                try h()
                try bs()
                try h()
                try p3(6)
            }
        }

        try bd(3)
        for _ in 0..<4 { try tv() }
        try bl(2)
        if v <= 14 { try bs() }
        if v < 18 { try h() }
        try bits(v <= 14 ? 3 : 2)              // DIMASO, DIMSHO, DIMSAV
        try bits(7)                            // PLINEGEN to LIMCHECK
        if v <= 14 { try bits(1) }             // BLIPMODE
        if v >= 18 { try bits(1) }
        try bits(4)                            // USRTIMER, SKPOLY, ANGDIR, SPLFRAME
        if v <= 14 { try bits(2) }             // ATTREQ, ATTDIA
        try bits(2)                            // MIRRTEXT, WORLDVIEW
        if v <= 14 { try bits(1) }             // WIREFRAME
        try bits(3)                            // TILEMODE, PLIMCHECK, VISRETAIN
        if v <= 14 { try bits(1) }             // DELOBJ
        try bits(2)                            // DISPSILH, PELLIPSE
        try bs()                               // PROXYGRAPHICS
        if v <= 14 { try bs() }                // DRAGMODE
        try bs(5)                              // TREEDEPTH to AUPREC
        if v <= 14 { try bs() }                // OSMODE
        try bs()                               // ATTMODE
        if v <= 14 { try bs() }                // COORDS
        try bs()                               // PDMODE
        if v <= 14 { try bs() }                // PICKSTYLE
        if v >= 18 { try bl(3) }
        try bs(19)                             // USERI1 to TEXTQLTY
        try bd(21)                             // LTSCALE to CELTSCALE
        if v <= 18 { try tv() }                // MENUNAME
        try bl(4)                              // TDCREATE, TDUPDATE
        if v >= 18 { try bl(3) }
        try bl(4)                              // TDINDWG, TDUSRTIMER
        try cmc()                              // CECOLOR
        _ = try r.handle()                     // HANDSEED, always in the main stream
        try h(); try h(); try h()              // CLAYER, TEXTSTYLE, CELTYPE
        if v >= 21 { try h() }                 // CMATERIAL
        try h(); try h()                       // DIMSTYLE, CMLSTYLE
        if v >= 15 { try bd() }                // PSVPSCALE
        try ucs()                              // paper space
        try ucs()                              // model space
        if v >= 15 {
            try tv(); try tv()                 // DIMPOST, DIMAPOST
        } else {
            try bits(11)                       // DIMTOL to DIMSOXD
            _ = try r.rc(); _ = try r.rc()     // DIMALTD, DIMZIN
            try bits(2)                        // DIMSD1, DIMSD2
            for _ in 0..<3 { _ = try r.rc() }  // DIMTOLJ, DIMJUST, DIMFIT
            try bits(1)                        // DIMUPT
            for _ in 0..<4 { _ = try r.rc() }  // DIMTZIN, DIMALTZ, DIMALTTZ, DIMTAD
            try bs(6)                          // DIMUNIT to DIMALTTD
            try h()                            // DIMTXSTY
        }
        try bd(9)                              // DIMSCALE to DIMTM
        if v >= 21 {
            try bd(2)                          // DIMFXL, DIMJOGANG
            try bs()                           // DIMTFILL
            try cmc()                          // DIMTFILLCLR
        }
        if v >= 15 {
            try bits(6)                        // DIMTOL to DIMSE2
            try bs(3)                          // DIMTAD, DIMZIN, DIMAZIN
        }
        if v >= 21 { try bs() }                // DIMARCSYM
        try bd(8)                              // DIMTXT to DIMGAP
        if v <= 14 {
            for _ in 0..<5 { _ = try r.text8() }
        } else {
            try bd()                           // DIMALTRND
            try bits(1)                        // DIMALT
            try bs()                           // DIMALTD
            try bits(4)                        // DIMTOFL, DIMSAH, DIMTIX, DIMSOXD
        }
        try cmc(); try cmc(); try cmc()        // DIMCLRD, DIMCLRE, DIMCLRT
        if v >= 15 {
            try bs(11)                         // DIMADEC to DIMJUST
            try bits(2)                        // DIMSD1, DIMSD2
            try bs(4)                          // DIMTOLJ, DIMTZIN, DIMALTZ, DIMALTTZ
            try bits(1)                        // DIMUPT
            try bs()                           // DIMATFIT
        }
        if v >= 21 { try bits(1) }             // DIMFXLON
        if v >= 24 {
            try bits(1)                        // DIMTXTDIRECTION
            try bd(); try tv(); try bd(); try tv()
        }
        if v >= 15 {
            for _ in 0..<5 { try h() }         // DIMTXSTY to DIMBLK2
        }
        if v >= 21 { for _ in 0..<3 { try h() } }
        if v >= 15 { try bs(2) }               // DIMLWD, DIMLWE
        for _ in 0..<9 { try h() }             // control objects
        if v <= 15 { try h() }                 // viewport entity header control
        for _ in 0..<3 { try h() }             // dictionaries
        guard v >= 15 else { return 0 }        // R14 and earlier do not store INSUNITS
        try bs(2)                              // TSTACKALIGN, TSTACKSIZE
        try tv(); try tv()                     // HYPERLINKBASE, STYLESHEET
        for _ in 0..<3 { try h() }
        if v >= 18 { try h(); try h() }
        if v >= 21 { try h() }
        if v >= 27 { try h() }
        try bl()                               // flags
        let units = try r.bs()
        return (0...24).contains(units) ? units : 0
    }

    // MARK: Objects (chapter 20)

    private struct RawEntity {
        var handle: UInt64
        var owner: UInt64?
        var mode: Int
        var layer: UInt64
        var invisible: Bool
        var shape: RawShape
    }

    private enum RawShape {
        case done(DWGShape)
        case skipped(DWGSkipped)
        /// Part of the file's structure, nothing the user drew.
        case ignored
        case polyline(flags: Int, normal: SIMD3<Double>, vertices: [UInt64]?, is3D: Bool)
        case vertex(SIMD3<Double>, bulge: Double, flags: Int)
    }

    private struct RawObjects {
        var entities: [RawEntity] = []
        var blocks: [UInt64: DWGBlock] = [:]
        var layers: [UInt64: DWGLayer] = [:]
        var damaged = 0
    }

    private static func readObject(_ data: [UInt8], at offset: Int, handle mapHandle: UInt64, version v: Int,
                                   classes: [Int: String], into raw: inout RawObjects) throws {
        guard offset >= 0, offset < data.count else { throw DWGCorrupt("offset") }
        var r = DWGBits(data, byte: offset)
        let size = try r.ms()
        let handleBits = v >= 24 ? try r.mc() : 0
        let start = r.bytePosition
        guard size >= 0, size <= data.count - start else { throw DWGCorrupt("size") }
        r = DWGBits(data, byte: start, endByte: start + size)
        let type = try r.objectType(v)

        guard handleBits >= 0, handleBits <= size * 8 else { throw DWGCorrupt("handle bits") }
        var dataBits = v >= 24 ? size * 8 - handleBits : 0
        if v >= 15, v < 24 { dataBits = Int(try r.rl()) }
        let handle = try r.handle().value
        guard handle == mapHandle else { throw DWGCorrupt("handle") }
        // Extended data: blocks of size, application handle and bytes, until a size of zero.
        while true {
            let n = try r.bs()
            if n == 0 { break }
            guard n > 0 else { throw DWGCorrupt("EED") }
            _ = try r.handle()
            try r.skip(bytes: n)
        }

        let kind = type >= 500 ? (classes[type] ?? "") : ""
        if type == 0x31 || type == 0x33 {
            try readTableEntry(&r, type: type, handle: handle, version: v, dataBits: dataBits, start: start, size: size, into: &raw)
            return
        }
        guard isEntity(type, kind: kind) else { return }

        // Common entity data
        if try r.flag() {
            let graphics = v >= 24 ? Int(truncatingIfNeeded: try r.bll()) : Int(try r.rl())
            try r.skip(bytes: graphics)
        }
        if v <= 14 { dataBits = Int(try r.rl()) }
        guard dataBits >= 0, dataBits <= size * 8 else { throw DWGCorrupt("bits") }
        let mode = try r.bb()
        let reactors = try r.bl()
        guard reactors >= 0, reactors <= size else { throw DWGCorrupt("reactors") }
        let noXdict = v >= 18 ? try r.flag() : false
        if v >= 27 { _ = try r.bit() }
        let byLayerType = v <= 14 ? try r.flag() : false
        let noLinks = v >= 18 ? true : try r.flag()
        var bookColor = false
        if v < 18 {
            _ = try r.bs()
        } else {
            let color = try r.bs()
            let flags = (color & 0xFFFF) >> 8
            if flags & 0x80 != 0 { _ = try r.bl() }
            if flags & 0x40 != 0 { bookColor = true }
            if flags & 0x20 != 0 { _ = try r.bl() }
        }
        _ = try r.bd()
        var typeFlag = 0, plotFlag = 0, materialFlag = 0
        if v >= 15 {
            typeFlag = try r.bb()
            plotFlag = try r.bb()
        }
        if v >= 21 {
            materialFlag = try r.bb()
            _ = try r.rc()
        }
        var styles = 0
        if v >= 24 { for _ in 0..<3 where try r.flag() { styles += 1 } }
        let invisible = try r.bs() & 1 != 0
        if v >= 15 { _ = try r.rc() }

        // Common handles
        var h = DWGBits(data, byte: start, endByte: start + size)
        try h.seek(bit: start * 8 + dataBits)
        func next() throws -> UInt64 { try h.handle().resolved(from: handle) }
        let owner = mode == 0 ? try next() : nil
        for _ in 0..<reactors { _ = try next() }
        if !noXdict { _ = try next() }
        var layer: UInt64 = 0
        if v <= 14 {
            layer = try next()
            if !byLayerType { _ = try next() }
        }
        if v <= 15, !noLinks {
            _ = try next()
            _ = try next()
        }
        if bookColor { _ = try next() }
        if v >= 15 {
            layer = try next()
            if typeFlag == 3 { _ = try next() }
            if v >= 21, materialFlag == 3 { _ = try next() }
            if plotFlag == 3 { _ = try next() }
            for _ in 0..<styles { _ = try next() }
        }

        var strings = try stringStream(data, start: start, size: size, dataBits: dataBits, version: v)
        let shape = try readShape(&r, &h, &strings, type: type, kind: kind, version: v, owner: handle)
        raw.entities.append(RawEntity(handle: handle, owner: owner, mode: mode, layer: layer, invisible: invisible, shape: shape))
    }

    private static func isEntity(_ type: Int, kind: String) -> Bool {
        switch type {
        case 0x01...0x28, 0x29, 0x2B...0x2F, 0x4A, 0x4D, 0x4E, 0x1F2: return true
        case 500...: return kind == "LWPOLYLINE" || kind == "HATCH"
        default: return false
        }
    }

    /// R2007 and later keep the texts of an object in a stream of their own, ending where the handles begin.
    private static func stringStream(_ data: [UInt8], start: Int, size: Int, dataBits: Int, version v: Int) throws -> DWGBits? {
        guard v >= 21 else { return nil }
        var s = DWGBits(data, byte: start, endByte: start + size)
        let endBit = start * 8 + dataBits - 1
        try s.seek(bit: endBit)
        guard try s.flag() else { return nil }
        var at = endBit - 16
        try s.seek(bit: at)
        var length = Int(try s.rs())
        if length & 0x8000 != 0 {
            at -= 16
            try s.seek(bit: at)
            let high = Int(try s.rs())
            length = (length & 0x7FFF) | high << 15
        }
        try s.seek(bit: at - length)
        s.end = at
        return s
    }

    private static func readTableEntry(_ r: inout DWGBits, type: Int, handle: UInt64, version v: Int, dataBits: Int,
                                       start: Int, size: Int, into raw: inout RawObjects) throws {
        var bits = dataBits
        if v <= 14 { bits = Int(try r.rl()) }
        guard bits >= 0, bits <= size * 8 else { throw DWGCorrupt("bits") }
        _ = try r.bl()
        if v >= 18 { _ = try r.bit() }
        if v >= 27 { _ = try r.bit() }
        var strings = try stringStream(r.bytes, start: start, size: size, dataBits: bits, version: v)
        let name = try readText(&r, &strings, version: v)
        _ = try r.bit()   // 64-flag
        _ = try r.bs()    // xref index
        _ = try r.bit()   // xref dependent
        if type == 0x33 {
            var visible = true
            if v <= 14 {
                let frozen = try r.flag()
                _ = try r.flag()
                _ = try r.flag()
                _ = try r.flag()
                visible = try !frozen && r.bs() >= 0     // a switched-off layer has a negative colour
            } else {
                let values = try r.bs()
                visible = values & 1 == 0 && values & 2 == 0
            }
            raw.layers[handle] = DWGLayer(name: name, visible: visible)
            return
        }
        _ = try r.bit()   // anonymous
        _ = try r.bit()   // has attributes
        let isXref = try r.flag()
        let overlaid = try r.flag()
        if v >= 15 { _ = try r.bit() }
        if v >= 18 { _ = try r.bl() }
        let base = try r.point3()
        raw.blocks[handle] = DWGBlock(name: name, base: base, isXref: isXref || overlaid)
    }

    /// TV: in the object's data up to R2004, in the string stream from R2007 on.
    private static func readText(_ r: inout DWGBits, _ strings: inout DWGBits?, version v: Int) throws -> String {
        if v < 21 { return try r.text8() }
        guard strings != nil else { return "" }
        return try strings!.text16()
    }

    private static func readShape(_ r: inout DWGBits, _ h: inout DWGBits, _ strings: inout DWGBits?, type: Int, kind: String,
                                  version v: Int, owner: UInt64) throws -> RawShape {
        switch type {
        case 0x13:
            return .done(try readLine(&r, version: v))
        case 0x12:
            let c = try r.point3()
            let radius = try r.bd()
            _ = try r.thickness(v)
            return .done(.circle(center: c, radius: radius, normal: try r.extrusion(v)))
        case 0x11:
            let c = try r.point3()
            let radius = try r.bd()
            _ = try r.thickness(v)
            let normal = try r.extrusion(v)
            let a = try r.bd()
            return .done(.arc(center: c, radius: radius, start: a, end: try r.bd(), normal: normal))
        case 0x4D:
            return .done(try readLightweightPolyline(&r, version: v))
        case 500... where kind == "LWPOLYLINE":
            return .done(try readLightweightPolyline(&r, version: v))
        case 0x0F:
            let flags = try r.bs()
            _ = try r.bs()
            _ = try r.bd()
            _ = try r.bd()
            _ = try r.thickness(v)
            _ = try r.bd()
            let normal = try r.extrusion(v)
            return .polyline(flags: flags, normal: normal,
                             vertices: try ownedList(&r, &h, version: v, owner: owner), is3D: false)
        case 0x10:
            _ = try r.rc()
            let flags = Int(try r.rc())
            return .polyline(flags: flags, normal: SIMD3(0, 0, 1),
                             vertices: try ownedList(&r, &h, version: v, owner: owner), is3D: true)
        case 0x0A:
            let flags = Int(try r.rc())
            let p = try r.point3()
            let width = try r.bd()
            if width >= 0 { _ = try r.bd() }
            return .vertex(p, bulge: try r.bd(), flags: flags)
        case 0x0B:
            let flags = Int(try r.rc())
            return .vertex(try r.point3(), bulge: 0, flags: flags)
        case 0x23:
            let c = try r.point3()
            let major = try r.point3()
            let normal = try r.point3()
            let ratio = try r.bd()
            let a = try r.bd()
            return .done(.ellipse(center: c, major: major, ratio: ratio, start: a, end: try r.bd(), normal: normal))
        case 0x24:
            return .done(try readSpline(&r, version: v))
        case 0x01:
            return .done(try readTextEntity(&r, &strings, version: v))
        case 0x2C:
            let at = try r.point3()
            let normal = try r.point3()
            let xAxis = try r.point3()
            let width = try r.bd()
            if v >= 21 { _ = try r.bd() }
            let height = try r.bd()
            let attachment = try r.bs()
            _ = try r.bs()
            _ = try r.bd()
            let extents = try r.bd()
            return .done(.mtext(try readText(&r, &strings, version: v), at: at, height: height, xAxis: xAxis, attachment: attachment,
                                width: extents > 0 ? extents : width, normal: normal))
        case 0x07, 0x08:
            return .done(try readInsert(&r, &h, type: type, version: v, owner: owner))
        case 0x14...0x1A: return .skipped(.dimension)
        case 0x4E: return .skipped(.hatch)
        case 500... where kind == "HATCH": return .skipped(.hatch)
        case 0x1C, 0x1D, 0x1E, 0x25, 0x26, 0x27: return .skipped(.solid3D)
        case 0x04, 0x05, 0x06, 0x0C, 0x0D, 0x0E, 0x22:
            return .ignored              // block brackets, mesh vertices, viewports
        default:
            return .skipped(.other)
        }
    }

    private static func readLine(_ r: inout DWGBits, version v: Int) throws -> DWGShape {
        if v <= 14 {
            let a = try r.point3()
            return .line(a, try r.point3())
        }
        let flat = try r.flag()
        let ax = try r.rd()
        let bx = try r.dd(default: ax)
        let ay = try r.rd()
        let by = try r.dd(default: ay)
        var az = 0.0, bz = 0.0
        if !flat {
            az = try r.rd()
            bz = try r.dd(default: az)
        }
        return .line(SIMD3(ax, ay, az), SIMD3(bx, by, bz))
    }

    private static func count(_ r: DWGBits, _ n: Int, bitsEach: Int) throws -> Int {
        guard n >= 0, n <= r.remaining / bitsEach else { throw DWGCorrupt("count") }
        return n
    }

    private static func readLightweightPolyline(_ r: inout DWGBits, version v: Int) throws -> DWGShape {
        let flags = try r.bs()
        if flags & 4 != 0 { _ = try r.bd() }
        if flags & 8 != 0 { _ = try r.bd() }
        if flags & 2 != 0 { _ = try r.bd() }
        let normal = flags & 1 != 0 ? try r.point3() : SIMD3<Double>(0, 0, 1)
        let n = try count(r, try r.bl(), bitsEach: 2)
        let bulgeCount = flags & 16 != 0 ? try count(r, try r.bl(), bitsEach: 2) : 0
        let idCount = v >= 24 && flags & 1024 != 0 ? try count(r, try r.bl(), bitsEach: 2) : 0
        if flags & 32 != 0 { _ = try count(r, try r.bl(), bitsEach: 4) }
        var points: [Vec2] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            if i == 0 || v <= 14 {
                points.append(try r.point2R())
            } else {
                let x = try r.dd(default: points[i - 1].x)
                points.append(Vec2(x, try r.dd(default: points[i - 1].y)))
            }
        }
        var bulges: [Double] = []
        for _ in 0..<bulgeCount { bulges.append(try r.bd()) }
        if bulges.count != n { bulges = [] }
        for _ in 0..<idCount { _ = try r.bl() }
        return .polyline(points: points, bulges: bulges, closed: flags & 512 != 0, normal: normal)
    }

    private static func readSpline(_ r: inout DWGBits, version v: Int) throws -> DWGShape {
        var scenario = try r.bl()
        var closedFlag = false
        if v >= 27 {
            let flags = try r.bl()
            closedFlag = flags & 4 != 0
            let knotParameter = try r.bl()
            scenario = knotParameter == 15 ? 1 : 2
        }
        let degree = try r.bl()
        if scenario == 2 {
            _ = try r.bd()
            _ = try r.point3()
            _ = try r.point3()
            let n = try count(r, try r.bl(), bitsEach: 6)
            var points: [SIMD3<Double>] = []
            points.reserveCapacity(n)
            for _ in 0..<n { points.append(try r.point3()) }
            return .fitSpline(points: points, closed: closedFlag)
        }
        guard scenario == 1 else { throw DWGCorrupt("spline") }
        let rational = try r.flag()
        let closed = try r.flag()
        _ = try r.flag()     // periodic
        _ = try r.bd()
        _ = try r.bd()
        let knotCount = try count(r, try r.bl(), bitsEach: 2)
        let controlCount = try count(r, try r.bl(), bitsEach: 6)
        let weighted = try r.flag()
        var knots: [Double] = []
        knots.reserveCapacity(knotCount)
        for _ in 0..<knotCount { knots.append(try r.bd()) }
        var control: [SIMD3<Double>] = []
        var weights: [Double] = []
        control.reserveCapacity(controlCount)
        for _ in 0..<controlCount {
            control.append(try r.point3())
            if weighted || rational { weights.append(try r.bd()) }
        }
        return .nurbs(degree: degree, knots: knots, control: control, weights: weights, closed: closed || closedFlag)
    }

    private static func readTextEntity(_ r: inout DWGBits, _ strings: inout DWGBits?, version v: Int) throws -> DWGShape {
        if v <= 14 {
            let elevation = try r.bd()
            let p = try r.point2R()
            _ = try r.point2R()
            let normal = try r.point3()
            _ = try r.bd()
            _ = try r.bd()
            let rotation = try r.bd()
            let height = try r.bd()
            _ = try r.bd()
            let s = try readText(&r, &strings, version: v)
            return .text(s, at: SIMD3(p.x, p.y, elevation), height: height, rotation: rotation, normal: normal)
        }
        let flags = Int(try r.rc())
        let elevation = flags & 0x01 == 0 ? try r.rd() : 0
        let p = try r.point2R()
        if flags & 0x02 == 0 {
            _ = try r.dd(default: p.x)
            _ = try r.dd(default: p.y)
        }
        let normal = try r.extrusion(v)
        _ = try r.thickness(v)
        if flags & 0x04 == 0 { _ = try r.rd() }
        let rotation = flags & 0x08 == 0 ? try r.rd() : 0
        let height = try r.rd()
        if flags & 0x10 == 0 { _ = try r.rd() }
        let s = try readText(&r, &strings, version: v)
        return .text(s, at: SIMD3(p.x, p.y, elevation), height: height, rotation: rotation, normal: normal)
    }

    private static func readInsert(_ r: inout DWGBits, _ h: inout DWGBits, type: Int, version v: Int, owner: UInt64) throws -> DWGShape {
        let at = try r.point3()
        var scale = SIMD3<Double>(1, 1, 1)
        if v <= 14 {
            scale = try r.point3()
        } else {
            switch try r.bb() {
            case 3: break
            case 1:
                scale.y = try r.dd(default: 1)
                scale.z = try r.dd(default: 1)
            case 2:
                let s = try r.rd()
                scale = SIMD3(s, s, s)
            default:
                scale.x = try r.rd()
                scale.y = try r.dd(default: scale.x)
                scale.z = try r.dd(default: scale.x)
            }
        }
        let rotation = try r.bd()
        let normal = try r.point3()
        _ = try r.flag()     // has attributes
        if v >= 18 { _ = try r.bl() }
        var columns = 1, rows = 1
        var columnSpacing = 0.0, rowSpacing = 0.0
        if type == 0x08 {
            columns = try r.bs()
            rows = try r.bs()
            columnSpacing = try r.bd()
            rowSpacing = try r.bd()
        }
        let block = try h.handle().resolved(from: owner)
        return .insert(block: block, at: at, scale: scale, rotation: rotation, normal: normal,
                       columns: columns, rows: rows, columnSpacing: columnSpacing, rowSpacing: rowSpacing)
    }

    /// R2004 and later list the owned objects of a polyline. Earlier files only name the first and last one, so
    /// their vertices are found by their owner instead.
    private static func ownedList(_ r: inout DWGBits, _ h: inout DWGBits, version v: Int, owner: UInt64) throws -> [UInt64]? {
        guard v >= 18 else { return nil }
        let n = try count(r, try r.bl(), bitsEach: 2)
        guard n <= h.remaining / 8 else { throw DWGCorrupt("count") }
        var out: [UInt64] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try h.handle().resolved(from: owner)) }
        return out
    }

    // MARK: Sorting the objects by owner

    private static func assemble(_ raw: RawObjects, into drawing: inout DWGDrawing) {
        drawing.layers = raw.layers
        drawing.blocks = raw.blocks

        var vertices: [UInt64: (p: SIMD3<Double>, bulge: Double, flags: Int, owner: UInt64?)] = [:]
        var verticesByOwner: [UInt64: [UInt64]] = [:]
        for e in raw.entities {
            guard case let .vertex(p, bulge, flags) = e.shape else { continue }
            vertices[e.handle] = (p, bulge, flags, e.owner)
            if let o = e.owner { verticesByOwner[o, default: []].append(e.handle) }
        }

        let modelHandle = raw.blocks.first { $0.value.name.uppercased() == "*MODEL_SPACE" }?.key
        let paperHandles = Set(raw.blocks.filter { $0.value.name.uppercased().hasPrefix("*PAPER_SPACE") }.keys)

        for e in raw.entities.sorted(by: { $0.handle < $1.handle }) {
            if e.invisible { continue }
            let layerVisible = raw.layers[e.layer]?.visible ?? true
            var shape: DWGShape
            switch e.shape {
            case .vertex, .ignored:
                continue
            case let .skipped(kind):
                if e.mode == 2 || e.owner == modelHandle, layerVisible { drawing.skipped[kind, default: 0] += 1 }
                continue
            case let .done(s):
                shape = s
            case let .polyline(flags, normal, list, is3D):
                let ids = list ?? (verticesByOwner[e.handle] ?? []).sorted()
                // Flag 16: a control point of a spline-fit polyline. The curve itself runs through the other vertices.
                let points = ids.compactMap { vertices[$0] }.filter { $0.flags & 16 == 0 }
                let closed = flags & 1 != 0
                if is3D {
                    shape = .polyline3D(points: points.map(\.p), closed: closed)
                } else {
                    shape = .polyline(points: points.map { Vec2($0.p.x, $0.p.y) },
                                      bulges: points.map(\.bulge), closed: closed, normal: normal)
                }
            }
            guard layerVisible else { continue }
            let entity = DWGEntity(handle: e.handle, layer: e.layer, shape: shape)
            switch e.mode {
            case 1: continue                                  // paper space
            case 2: drawing.modelSpace.append(entity)
            default:
                guard let o = e.owner else { continue }
                if o == modelHandle {
                    drawing.modelSpace.append(entity)
                } else if !paperHandles.contains(o) {
                    drawing.blockEntities[o, default: []].append(entity)
                }
            }
        }
    }
}
