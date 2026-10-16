import Compression
import Foundation
import simd

/// 3MF export: one object per body, in millimetres, with welded (watertight) meshes.
/// Better than STL for 3D printing: units and part names travel with the file.
public enum ThreeMF {
    public struct Part {
        public var name: String
        public var shape: Shape
        public init(name: String, shape: Shape) { self.name = name; self.shape = shape }
    }

    public static func write(_ parts: [Part], to url: URL, linearDeflection: Double) throws {
        var objects = "", items = ""
        for (i, part) in parts.enumerated() {
            let mesh = try part.shape.mesh(linearDeflection: linearDeflection, angularDeflection: 0.2)
            let (vertices, triangles) = weld(mesh)
            guard !triangles.isEmpty else { continue }
            var v = "", t = ""
            v.reserveCapacity(vertices.count * 48)
            t.reserveCapacity(triangles.count * 40)
            for p in vertices { v += "<vertex x=\"\(num(p.x))\" y=\"\(num(p.y))\" z=\"\(num(p.z))\"/>" }
            for tri in triangles { t += "<triangle v1=\"\(tri.0)\" v2=\"\(tri.1)\" v3=\"\(tri.2)\"/>" }
            let id = i + 1
            objects += "<object id=\"\(id)\" name=\"\(xml(part.name))\" type=\"model\"><mesh><vertices>\(v)</vertices><triangles>\(t)</triangles></mesh></object>"
            items += "<item objectid=\"\(id)\"/>"
        }
        guard !items.isEmpty else { throw KernelError("Keine Geometrie zum Exportieren") }
        let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="de-DE" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\
        <metadata name="Application">6axis</metadata><resources>\(objects)</resources><build>\(items)</build></model>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """
        let zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rels.utf8))
        zip.add("3D/3dmodel.model", Data(model.utf8))
        try zip.data().write(to: url, options: .atomic)
    }

    /// Merges vertices at the same position (the tessellation repeats them per face), so slicers get
    /// one closed surface; drops degenerate triangles.
    static func weld(_ m: TriangleMesh) -> ([SIMD3<Float>], [(Int, Int, Int)]) {
        var index: [SIMD3<Int32>: Int] = [:]
        var vertices: [SIMD3<Float>] = []
        var remap = [Int](repeating: 0, count: m.positions.count)
        for (i, p) in m.positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x * 10000).rounded()), Int32((p.y * 10000).rounded()), Int32((p.z * 10000).rounded()))
            if let j = index[key] { remap[i] = j } else {
                index[key] = vertices.count
                remap[i] = vertices.count
                vertices.append(p)
            }
        }
        var tris: [(Int, Int, Int)] = []
        tris.reserveCapacity(m.indices.count / 3)
        for t in stride(from: 0, to: m.indices.count - 2, by: 3) {
            let a = remap[Int(m.indices[t])], b = remap[Int(m.indices[t + 1])], c = remap[Int(m.indices[t + 2])]
            if a != b && b != c && a != c { tris.append((a, b, c)) }
        }
        return (vertices, tris)
    }

    private static func num(_ f: Float) -> String {
        let s = String(format: "%.5f", f)
        var t = Substring(s)
        while t.hasSuffix("0") { t = t.dropLast() }
        if t.hasSuffix(".") { t = t.dropLast() }
        return t == "-0" ? "0" : String(t)
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Minimal ZIP archive writer (deflate via Apple's Compression framework, store when that doesn't help).
final class ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count: UInt16 = 0

    func add(_ name: String, _ content: Data) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(content)
        let deflated = Self.deflate(content)
        let (method, payload): (UInt16, Data) = deflated.map { $0.count < content.count ? (8, $0) : (0, content) } ?? (0, content)
        let offset = UInt32(out.count)
        // Local file header
        out.append(le32(0x0403_4b50)); out.append(le16(20)); out.append(le16(0x0800)); out.append(le16(method))
        out.append(le16(0)); out.append(le16(0x21))                      // time, date (1980-01-01)
        out.append(le32(crc)); out.append(le32(UInt32(payload.count))); out.append(le32(UInt32(content.count)))
        out.append(le16(UInt16(nameData.count))); out.append(le16(0))
        out.append(nameData); out.append(payload)
        // Central directory entry
        central.append(le32(0x0201_4b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800))
        central.append(le16(method)); central.append(le16(0)); central.append(le16(0x21))
        central.append(le32(crc)); central.append(le32(UInt32(payload.count))); central.append(le32(UInt32(content.count)))
        central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
        central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
        central.append(nameData)
        count += 1
    }

    func data() -> Data {
        var d = out
        let start = UInt32(d.count)
        d.append(central)
        d.append(le32(0x0605_4b50)); d.append(le16(0)); d.append(le16(0)); d.append(le16(count)); d.append(le16(count))
        d.append(le32(UInt32(central.count))); d.append(le32(start)); d.append(le16(0))
        return d
    }

    /// Raw deflate stream (what ZIP stores), or nil on failure.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var dst = Data(count: capacity)
        let n = dst.withUnsafeMutableBytes { d in
            data.withUnsafeBytes { s in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? dst.prefix(n) : nil
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
