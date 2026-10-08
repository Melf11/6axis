import Foundation
import simd

/// Minimal DXF R12 (AC1009) writer: lines, circles, filled triangles and text on named layers.
/// R12 is read by practically every CAD/CAM, laser and CNC program. Units: millimetres.
public struct DXFWriter {
    public struct Layer {
        public var name: String
        public var color: Int          // AutoCAD colour index
        public var lineType: String    // CONTINUOUS, DASHED, CENTER
    }

    private var layers: [Layer] = []
    private var body = ""

    public init() {}

    public mutating func layer(_ name: String, color: Int, lineType: String = "CONTINUOUS") {
        guard !layers.contains(where: { $0.name == name }) else { return }
        layers.append(Layer(name: name, color: color, lineType: lineType))
    }

    private static func f(_ v: Double) -> String { String(format: "%.4f", v) }

    public mutating func line(_ a: Vec2, _ b: Vec2, layer: String) {
        body += "0\nLINE\n8\n\(layer)\n10\n\(Self.f(a.x))\n20\n\(Self.f(a.y))\n30\n0.0\n11\n\(Self.f(b.x))\n21\n\(Self.f(b.y))\n31\n0.0\n"
    }

    public mutating func polyline(_ pts: [Vec2], layer: String) {
        for i in 0..<max(0, pts.count - 1) { line(pts[i], pts[i + 1], layer: layer) }
    }

    public mutating func circle(_ c: Vec2, _ r: Double, layer: String) {
        body += "0\nCIRCLE\n8\n\(layer)\n10\n\(Self.f(c.x))\n20\n\(Self.f(c.y))\n30\n0.0\n40\n\(Self.f(r))\n"
    }

    public mutating func triangle(_ a: Vec2, _ b: Vec2, _ c: Vec2, layer: String) {
        // SOLID uses the vertex order 1-2-4-3; a triangle repeats the last vertex.
        body += "0\nSOLID\n8\n\(layer)\n"
        for (i, p) in [a, b, c, c].enumerated() {
            body += "\(10 + i)\n\(Self.f(p.x))\n\(20 + i)\n\(Self.f(p.y))\n\(30 + i)\n0.0\n"
        }
    }

    public mutating func text(_ s: String, at p: Vec2, height: Double, angle: Double = 0, align: Int = 0, layer: String) {
        // align: 0 left, 1 centre, 2 right (horizontal justification, baseline).
        let t = s.replacingOccurrences(of: "Ø", with: "%%c").replacingOccurrences(of: "\n", with: " ")
        body += "0\nTEXT\n8\n\(layer)\n10\n\(Self.f(p.x))\n20\n\(Self.f(p.y))\n30\n0.0\n40\n\(Self.f(height))\n1\n\(t)\n50\n\(Self.f(angle * 180 / .pi))\n"
        if align != 0 {
            body += "72\n\(align)\n11\n\(Self.f(p.x))\n21\n\(Self.f(p.y))\n31\n0.0\n"
        }
    }

    public func output() -> String {
        var s = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
        s += "0\nSECTION\n2\nTABLES\n"
        s += "0\nTABLE\n2\nLTYPE\n70\n3\n"
        s += "0\nLTYPE\n2\nCONTINUOUS\n70\n0\n3\nDurchgehend\n72\n65\n73\n0\n40\n0.0\n"
        s += "0\nLTYPE\n2\nDASHED\n70\n0\n3\nStrich\n72\n65\n73\n2\n40\n4.0\n49\n3.0\n49\n-1.0\n"
        s += "0\nLTYPE\n2\nCENTER\n70\n0\n3\nStrichpunkt\n72\n65\n73\n4\n40\n11.0\n49\n8.0\n49\n-1.2\n49\n0.6\n49\n-1.2\n"
        s += "0\nENDTAB\n"
        s += "0\nTABLE\n2\nLAYER\n70\n\(layers.count + 1)\n"
        s += "0\nLAYER\n2\n0\n70\n0\n62\n7\n6\nCONTINUOUS\n"
        for l in layers {
            s += "0\nLAYER\n2\n\(l.name)\n70\n0\n62\n\(l.color)\n6\n\(l.lineType)\n"
        }
        s += "0\nENDTAB\n0\nENDSEC\n"
        s += "0\nSECTION\n2\nENTITIES\n" + body + "0\nENDSEC\n0\nEOF\n"
        return s
    }
}

extension DrawingPage {
    /// The sheet as DXF in paper millimetres, with ISO 128 line types on separate layers.
    public func dxf() -> String {
        var w = DXFWriter()
        w.layer("KONTUR", color: 7)
        w.layer("VERDECKT", color: 8, lineType: "DASHED")
        w.layer("MITTELLINIE", color: 1, lineType: "CENTER")
        w.layer("BEMASSUNG", color: 3)
        w.layer("DUENN", color: 9)
        w.layer("RAHMEN", color: 7)
        w.layer("ISOMETRIE", color: 5)
        w.layer("TEXT", color: 7)
        w.layer("SCHRAFFUR", color: 8)
        for l in lines {
            let layer: String
            switch l.style {
            case .visible: layer = l.group == nil ? "KONTUR" : "BEMASSUNG"
            case .hidden: layer = "VERDECKT"
            case .center: layer = "MITTELLINIE"
            case .thin: layer = l.group == nil ? "DUENN" : "BEMASSUNG"
            case .frame: layer = "RAHMEN"
            case .iso: layer = "ISOMETRIE"
            case .hatch: layer = "SCHRAFFUR"
            }
            w.polyline(l.points, layer: layer)
        }
        for a in arrows {
            let u = simd_normalize(a.direction), n = Vec2(-u.y, u.x)
            let back = a.tip - u * 3, half = 3 * tan(15 * Double.pi / 180)
            w.triangle(a.tip, back + n * half, back - n * half, layer: "BEMASSUNG")
        }
        for t in texts {
            let align = t.anchor == .left ? 0 : (t.anchor == .center ? 1 : 2)
            w.text(t.text, at: t.position, height: t.height, angle: t.angle, align: align, layer: t.group == nil ? "TEXT" : "BEMASSUNG")
        }
        return w.output()
    }
}

extension DrawingGenerator {
    /// Part outlines at true size (1:1) for CNC and laser: the main face of every distinct part
    /// (as on the part sheets) with holes as real circles, laid out side by side, one layer per position.
    public func partsDXF(_ input: Input) -> String {
        var w = DXFWriter()
        w.layer("BESCHRIFTUNG", color: 7)
        var x = 0.0
        for g in groupParts(input.parts) {
            let shape = Self.normalized(g.shape)
            guard let p = try? shape.project(viewDir: Vec3(0, -1, 0), xDir: Vec3(1, 0, 0), deflection: 0.02),
                  let b = p.bounds else { continue }
            let layer = "POS_\(g.position)"
            w.layer(layer, color: 1 + (g.position - 1) % 6)
            let shift = Vec2(x - b.min.x, -b.min.y)
            let circles = p.circles.filter { $0.full && !$0.hidden }
            for line in p.polylines where !line.hidden && !line.smooth {
                // Full circles are written as CIRCLE entities instead of polygons.
                if line.points.count > 8, let first = line.points.first, let last = line.points.last, simd_distance(first, last) < 1e-6,
                   circles.contains(where: { c in line.points.allSatisfy { abs(simd_distance($0, c.center) - c.radius) < 0.05 } }) {
                    continue
                }
                w.polyline(line.points.map { $0 + shift }, layer: layer)
            }
            for c in circles { w.circle(c.center + shift, c.radius, layer: layer) }
            let label = "Pos. \(g.position) \(g.name) \(g.count)x \(g.length)x\(g.width)x\(g.thickness)"
            w.text(label, at: Vec2(x, b.max.y - b.min.y + 8), height: 5, layer: "BESCHRIFTUNG")
            x += (b.max.x - b.min.x) + 40
        }
        return w.output()
    }
}

extension DrawingPage {
    /// The sheet as SVG in millimetres, for the web and vector editors. Lines carry a class per
    /// ISO line type. `cropToViews` frames only the orthographic views with their dimensions.
    public func svg(cropToViews: Bool = false) -> String {
        let h = sheet.height
        var box = (x: 0.0, y: 0.0, w: sheet.width, h: h)
        if cropToViews {
            var lo = Vec2(repeating: .greatestFiniteMagnitude), hi = -lo
            for v in views where v.id != "iso" && !v.id.hasPrefix("detail.") { lo = simd_min(lo, v.min); hi = simd_max(hi, v.max) }
            for d in dimensions where !d.id.hasPrefix("balloon.") {
                for s in d.segments { lo = simd_min(lo, simd_min(s.0, s.1)); hi = simd_max(hi, simd_max(s.0, s.1)) }
                lo = simd_min(lo, d.textCenter - Vec2(8, 4)); hi = simd_max(hi, d.textCenter + Vec2(8, 4))
            }
            if lo.x <= hi.x {
                lo -= Vec2(4, 4); hi += Vec2(4, 4)
                box = (lo.x, h - hi.y, hi.x - lo.x, hi.y - lo.y)
            }
        }
        func pt(_ p: Vec2) -> String { String(format: "%.2f,%.2f", p.x, h - p.y) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let vb = String(format: "%.1f %.1f %.1f %.1f", box.x, box.y, box.w, box.h)
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(vb)\" width=\"\(Int(box.w))mm\" height=\"\(Int(box.h))mm\">\n"
        for l in lines where l.points.count >= 2 {
            let cls: String
            switch l.style {
            case .frame: if cropToViews { continue }; cls = "frame"
            case .visible: cls = l.group == nil ? "visible" : "dim"
            case .hidden: cls = "hidden"
            case .center: cls = "center"
            case .thin: cls = l.group == nil ? "thin" : "dim"
            case .iso: cls = "iso"
            case .hatch: cls = "hatch"
            }
            let dash = l.style.dash.map { " stroke-dasharray=\"\($0.map { String(format: "%.2f", $0) }.joined(separator: " "))\"" } ?? ""
            out += "<polyline class=\"\(cls)\" points=\"\(l.points.map(pt).joined(separator: " "))\" fill=\"none\" stroke-width=\"\(l.style.width)\"\(dash)/>\n"
        }
        for a in arrows {
            let u = simd_normalize(a.direction), n = Vec2(-u.y, u.x)
            let back = a.tip - u * 3, half = 3 * tan(15 * Double.pi / 180)
            out += "<polygon class=\"arrow\" points=\"\(pt(a.tip)) \(pt(back + n * half)) \(pt(back - n * half))\"/>\n"
        }
        for t in texts {
            let anchor = t.anchor == .left ? "start" : (t.anchor == .center ? "middle" : "end")
            let p = Vec2(t.position.x, h - t.position.y)
            let rot = t.angle != 0 ? " transform=\"rotate(\(String(format: "%.2f", -t.angle * 180 / .pi)) \(String(format: "%.2f,%.2f", p.x, p.y)))\"" : ""
            out += "<text class=\"\(t.group == nil ? "label" : "value")\" x=\"\(String(format: "%.2f", p.x))\" y=\"\(String(format: "%.2f", p.y))\" font-size=\"\(String(format: "%.2f", t.height / 0.72))\" text-anchor=\"\(anchor)\"\(t.bold ? " font-weight=\"600\"" : "")\(rot)>\(esc(t.text))</text>\n"
        }
        return out + "</svg>\n"
    }
}
