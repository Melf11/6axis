import Foundation
import simd

public enum DWGImportError: LocalizedError, Equatable {
    case notDWG
    case unsupportedVersion(String)
    case passwordProtected
    case damaged
    case empty
    case tooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .notDWG: return String(localized: "Das ist keine DWG-Datei.")
        case let .unsupportedVersion(v):
            return String(localized: "Diese DWG-Version wird nicht unterstützt (\(v)). Lesbar sind die Formate R13 bis 2018.")
        case .passwordProtected: return String(localized: "Die DWG-Datei ist mit einem Passwort geschützt.")
        case .damaged: return String(localized: "Die DWG-Datei ist beschädigt und konnte nicht gelesen werden.")
        case .empty: return String(localized: "Die DWG-Datei enthält im Modellbereich keine 2D-Geometrie, die sich übernehmen lässt.")
        case let .tooLarge(limit): return String(localized: "Die Zeichnung ist zu groß: Eine Skizze nimmt höchstens \(limit) Linien und Bögen auf.")
        }
    }
}

/// A DWG drawing turned into a sketch on the XY plane.
public struct DWGImportResult: Sendable {
    public var sketch: Sketch
    /// Curves in the sketch, without texts.
    public var curveCount: Int
    public var textCount: Int
    /// What the drawing's unit was taken as; nil if the drawing has no unit and its numbers were read as mm.
    public var unit: String?
    public var skipped: [DWGSkipped: Int]
    /// Some objects did not lie in the XY plane and were projected onto it.
    public var flattened: Bool

    /// The message after the import: what came in, and what did not.
    public var summary: String {
        var parts = [String(localized: "DWG übernommen: \(curveCount) Kurven, \(textCount) Texte, in \(unit ?? String(localized: "mm (ohne Einheit in der Datei)"))")]
        let missing = DWGSkipped.allCases.compactMap { kind -> String? in
            guard let n = skipped[kind], n > 0 else { return nil }
            switch kind {
            case .dimension: return n == 1 ? String(localized: "1 Bemaßung") : String(localized: "\(n) Bemaßungen")
            case .hatch: return n == 1 ? String(localized: "1 Schraffur") : String(localized: "\(n) Schraffuren")
            case .solid3D: return n == 1 ? String(localized: "1 3D-Objekt") : String(localized: "\(n) 3D-Objekte")
            case .tilted: return n == 1 ? String(localized: "1 schräg liegendes Objekt") : String(localized: "\(n) schräg liegende Objekte")
            case .rotatedText: return n == 1 ? String(localized: "1 gedrehter Text") : String(localized: "\(n) gedrehte Texte")
            case .other: return n == 1 ? String(localized: "1 sonstiges Objekt") : String(localized: "\(n) sonstige Objekte")
            }
        }
        if !missing.isEmpty { parts.append(String(localized: "Nicht übernommen: \(missing.joined(separator: ", "))")) }
        if flattened { parts.append(String(localized: "Höhen wurden auf die Ebene gelegt")) }
        return parts.joined(separator: ". ")
    }
}

public enum DWGImporter {
    /// More than this is no sketch any more. Far above a house plan, and the solver and the drawing stay usable.
    public static let maxCurves = 20_000
    /// Blocks can hold blocks: without a limit a small file could unfold into almost anything.
    static let maxPoints = 500_000
    static let maxInserts = 1_000_000

    public static func importFile(at url: URL) throws -> DWGImportResult {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 512 * 1024 * 1024 else { throw DWGImportError.tooLarge(limit: maxCurves) }
        return try importData([UInt8](try Data(contentsOf: url)))
    }

    public static func importData(_ bytes: [UInt8]) throws -> DWGImportResult {
        do {
            let drawing = try DWGReader.read(bytes)
            var flattener = DWGFlattener(drawing)
            try flattener.run()
            return try flattener.result()
        } catch is DWGCorrupt {
            throw DWGImportError.damaged
        }
    }
}

// MARK: - Flat geometry

/// A 2D affine map: x' = a x + c y + tx, y' = b x + d y + ty.
struct DWGMatrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0

    func apply(_ p: Vec2) -> Vec2 { Vec2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }
    func applyVector(_ v: Vec2) -> Vec2 { Vec2(a * v.x + c * v.y, b * v.x + d * v.y) }

    func then(_ m: DWGMatrix) -> DWGMatrix {
        DWGMatrix(a: m.a * a + m.c * b, b: m.b * a + m.d * b,
                  c: m.a * c + m.c * d, d: m.b * c + m.d * d,
                  tx: m.a * tx + m.c * ty + m.tx, ty: m.b * tx + m.d * ty + m.ty)
    }

    var determinant: Double { a * d - b * c }
    /// Keeps circles round: rotation, mirroring and the same scale in all directions.
    var isSimilarity: Bool {
        let e = max(abs(a) + abs(b), abs(c) + abs(d), 1e-30)
        return abs(a * c + b * d) < 1e-9 * e * e && abs((a * a + b * b) - (c * c + d * d)) < 1e-9 * e * e
    }
    var uniformScale: Double { sqrt(abs(determinant)) }
    /// How text and arcs turn, in radians.
    var rotation: Double { atan2(b, a) }

    static func translation(_ x: Double, _ y: Double) -> DWGMatrix { DWGMatrix(tx: x, ty: y) }
    static func scale(_ x: Double, _ y: Double) -> DWGMatrix { DWGMatrix(a: x, d: y) }
    static func rotation(_ t: Double) -> DWGMatrix { DWGMatrix(a: cos(t), b: sin(t), c: -sin(t), d: cos(t)) }
}

/// Follows the entities through blocks, turns them into flat curves and collects them in a sketch.
struct DWGFlattener {
    private let drawing: DWGDrawing
    private let scale: Double
    private var sketch = Sketch(plane: .xy)
    private var curves = 0
    private var texts = 0
    private var skipped: [DWGSkipped: Int]
    private var flattened = false
    /// Ends of curves that meet share a point, otherwise no closed area would be found.
    private var grid: [SIMD2<Int>: [Int]] = [:]
    private static let mergeDistance = 0.001
    private var stack: Set<UInt64> = []
    private var inserts = 0

    init(_ drawing: DWGDrawing) {
        self.drawing = drawing
        self.skipped = drawing.skipped
        self.scale = Self.millimetres(perUnit: drawing.units).value
        addToGrid(id: Sketch.originId, at: .zero)
    }

    /// $INSUNITS as millimetres per drawing unit. A drawing without a unit is read in mm.
    private static func millimetres(perUnit units: Int) -> (value: Double, name: String?) {
        switch units {
        case 1: return (25.4, String(localized: "Zoll"))
        case 2: return (304.8, String(localized: "Fuß"))
        case 3: return (1_609_344, String(localized: "Meilen"))
        case 4: return (1, "mm")
        case 5: return (10, "cm")
        case 6: return (1000, "m")
        case 7: return (1_000_000, "km")
        case 8: return (25.4e-6, "µin")
        case 9: return (0.0254, "mil")
        case 10: return (914.4, "yd")
        case 11: return (1e-7, "Å")
        case 12: return (1e-6, "nm")
        case 13: return (1e-3, "µm")
        case 14: return (100, "dm")
        default: return (1, nil)
        }
    }

    mutating func run() throws {
        try draw(drawing.modelSpace, DWGMatrix.scale(scale, scale), depth: 0)
    }

    func result() throws -> DWGImportResult {
        guard curves + texts > 0 else { throw DWGImportError.empty }
        return DWGImportResult(sketch: sketch, curveCount: curves, textCount: texts,
                               unit: Self.millimetres(perUnit: drawing.units).name, skipped: skipped, flattened: flattened)
    }

    // MARK: Entities

    private mutating func draw(_ entities: [DWGEntity], _ m: DWGMatrix, depth: Int) throws {
        for e in entities { try draw(e.shape, m, depth: depth) }
    }

    private func isFinite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite && abs(v.x) < 1e12 && abs(v.y) < 1e12 }

    /// The plane of an entity with this normal seen from above: flipped for (0, 0, -1), nil if it is tilted.
    private func planeMatrix(_ normal: SIMD3<Double>) -> DWGMatrix? {
        let len = simd_length(normal)
        guard len.isFinite, len > 1e-9 else { return DWGMatrix() }
        let n = normal / len
        guard abs(n.z) > 0.999999 else { return nil }
        return n.z > 0 ? DWGMatrix() : DWGMatrix(a: -1)
    }

    private mutating func note(_ kind: DWGSkipped) { skipped[kind, default: 0] += 1 }
    private mutating func noteHeight(_ p: SIMD3<Double>) { if abs(p.z) > 1e-6 { flattened = true } }

    private mutating func draw(_ shape: DWGShape, _ m: DWGMatrix, depth: Int) throws {
        switch shape {
        case let .line(a, b):
            guard isFinite(a), isFinite(b) else { return }
            noteHeight(a); noteHeight(b)
            try addLine(m.apply(Vec2(a.x, a.y)), m.apply(Vec2(b.x, b.y)))

        case let .circle(c, r, normal):
            guard let plane = planeMatrix(normal) else { return note(.tilted) }
            guard isFinite(c), r.isFinite, r > 0 else { return }
            noteHeight(c)
            try addCircle(Vec2(c.x, c.y), r, plane.then(m))

        case let .arc(c, r, start, end, normal):
            guard let plane = planeMatrix(normal) else { return note(.tilted) }
            guard isFinite(c), r.isFinite, r > 0, start.isFinite, end.isFinite else { return }
            noteHeight(c)
            try addArc(Vec2(c.x, c.y), r, from: start, to: end, plane.then(m))

        case let .polyline(points, bulges, closed, normal):
            guard let plane = planeMatrix(normal) else { return note(.tilted) }
            try addPolyline(points, bulges, closed: closed, plane.then(m))

        case let .polyline3D(points, closed):
            let finite = points.filter(isFinite)
            finite.forEach { noteHeight($0) }
            try addPolyline(finite.map { Vec2($0.x, $0.y) }, [], closed: closed, m)

        case let .ellipse(c, major, ratio, start, end, normal):
            guard let plane = planeMatrix(normal) else { return note(.tilted) }
            guard isFinite(c), isFinite(major), ratio.isFinite, start.isFinite, end.isFinite else { return }
            noteHeight(c)
            try addEllipse(c, major, ratio, start, end, flipped: plane.a < 0, m)

        case let .fitSpline(points, closed):
            let finite = points.filter(isFinite)
            finite.forEach { noteHeight($0) }
            try addSpline(finite.map { m.apply(Vec2($0.x, $0.y)) }, closed: closed)

        case let .nurbs(degree, knots, control, weights, closed):
            let finite = control.filter(isFinite)
            guard finite.count == control.count else { return }
            control.forEach { noteHeight($0) }
            let sampled = Self.sample(degree: degree, knots: knots, control: control, weights: weights)
            if degree == 1 {
                try addPolyline(sampled, [], closed: closed, m)
            } else {
                try addSpline(sampled.map(m.apply), closed: closed)
            }

        case let .text(s, at, height, rotation, normal):
            guard let plane = planeMatrix(normal) else { return note(.tilted) }
            guard isFinite(at) else { return }
            let total = plane.then(m)
            try addText(Self.plainText(s), at: total.apply(Vec2(at.x, at.y)), height: height * total.uniformScale,
                        rotation: rotation + total.rotation)

        case let .mtext(s, at, height, xAxis, attachment, width, normal):
            guard planeMatrix(normal) != nil else { return note(.tilted) }
            guard isFinite(at), height.isFinite else { return }
            try addMText(s, at: at, height: height, xAxis: xAxis, attachment: attachment, width: width, m)

        case let .insert(block, at, scale, rotation, normal, columns, rows, columnSpacing, rowSpacing):
            guard let plane = planeMatrix(normal) else { return note(.tilted) }
            guard isFinite(at), isFinite(scale), rotation.isFinite, columnSpacing.isFinite, rowSpacing.isFinite else { return }
            guard depth < 16, !stack.contains(block), let def = drawing.blocks[block], !def.isXref else { return }
            let entities = drawing.blockEntities[block] ?? []
            guard !entities.isEmpty else { return }
            stack.insert(block)
            defer { stack.remove(block) }
            for row in 0..<max(rows, 1) {
                for column in 0..<max(columns, 1) {
                    inserts += 1
                    guard inserts <= DWGImporter.maxInserts else { throw DWGImportError.tooLarge(limit: DWGImporter.maxCurves) }
                    // Inner first: block base to origin, scale, grid step, rotation, to the insertion point.
                    var inner = DWGMatrix.translation(-def.base.x, -def.base.y)
                        .then(.scale(scale.x, scale.y))
                        .then(.translation(Double(column) * columnSpacing, Double(row) * rowSpacing))
                    inner = inner.then(.rotation(rotation)).then(.translation(at.x, at.y))
                    try draw(entities, inner.then(plane).then(m), depth: depth + 1)
                }
            }
        }
    }

    // MARK: Curves in the sketch

    private func gridCell(_ p: Vec2) -> SIMD2<Int> {
        SIMD2(Int((p.x / Self.mergeDistance).rounded()), Int((p.y / Self.mergeDistance).rounded()))
    }

    private mutating func addToGrid(id: Int, at p: Vec2) { grid[gridCell(p), default: []].append(id) }

    private mutating func point(_ p: Vec2) throws -> Int {
        guard sketch.points.count < DWGImporter.maxPoints else { throw DWGImportError.tooLarge(limit: DWGImporter.maxCurves) }
        let cell = gridCell(p)
        for dx in -1...1 {
            for dy in -1...1 {
                for id in grid[cell &+ SIMD2(dx, dy)] ?? [] {
                    if let q = sketch.point(id), simd_length(q - p) <= Self.mergeDistance { return id }
                }
            }
        }
        let id = sketch.addPoint(p)
        addToGrid(id: id, at: p)
        return id
    }

    private func usable(_ p: Vec2) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) < 1e10 && abs(p.y) < 1e10 }

    private mutating func countCurve() throws {
        curves += 1
        guard curves <= DWGImporter.maxCurves else { throw DWGImportError.tooLarge(limit: DWGImporter.maxCurves) }
    }

    private mutating func addLine(_ a: Vec2, _ b: Vec2) throws {
        guard usable(a), usable(b), simd_length(a - b) > Self.mergeDistance else { return }
        try countCurve()
        let start = try point(a)
        sketch.addLine(start, try point(b))
    }

    /// Counter-clockwise, in (0, 2π]. Equal angles mean the full round.
    private static func sweep(from start: Double, to end: Double) -> Double {
        let d = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        guard d.isFinite else { return 2 * .pi }
        return d <= 0 ? d + 2 * .pi : d
    }

    private mutating func addCircle(_ c: Vec2, _ r: Double, _ m: DWGMatrix) throws {
        guard m.isSimilarity else {
            let points = (0..<48).map { i -> Vec2 in
                let t = Double(i) / 48 * 2 * .pi
                return m.apply(c + r * Vec2(cos(t), sin(t)))
            }
            return try addSpline(points, closed: true)
        }
        let center = m.apply(c)
        let radius = r * m.uniformScale
        guard usable(center), radius.isFinite, radius > Self.mergeDistance, radius < 1e10 else { return }
        try countCurve()
        sketch.addCircle(center: try point(center), radius: radius)
    }

    private mutating func addArc(_ c: Vec2, _ r: Double, from start: Double, to end: Double, _ m: DWGMatrix) throws {
        let sweep = Self.sweep(from: start, to: end)
        guard m.isSimilarity else {
            let n = max(Int(ceil(sweep / (2 * .pi) * 48)), 4)
            let points = (0...n).map { i -> Vec2 in
                let t = start + sweep * Double(i) / Double(n)
                return m.apply(c + r * Vec2(cos(t), sin(t)))
            }
            return try addSpline(points, closed: false)
        }
        var a = m.apply(c + r * Vec2(cos(start), sin(start)))
        var b = m.apply(c + r * Vec2(cos(start + sweep), sin(start + sweep)))
        // Mirroring turns the direction around; sketch arcs always run counter-clockwise.
        if m.determinant < 0 { swap(&a, &b) }
        let center = m.apply(c)
        guard usable(center), usable(a), usable(b), r * m.uniformScale > Self.mergeDistance, r * m.uniformScale < 1e10 else { return }
        try countCurve()
        if simd_length(a - b) <= Self.mergeDistance {
            sketch.addCircle(center: try point(center), radius: r * m.uniformScale)
            return
        }
        // The ends stay exact where they meet others; the arc's radius follows from the start point.
        let middle = try point(center)
        let first = try point(a)
        sketch.addArc(center: middle, start: first, end: try point(b))
    }

    private mutating func addPolyline(_ points: [Vec2], _ bulges: [Double], closed: Bool, _ m: DWGMatrix) throws {
        guard points.count >= 2 else { return }
        let n = points.count
        for i in 0..<(closed ? n : n - 1) {
            let p = points[i], q = points[(i + 1) % n]
            guard usable(p), usable(q) else { continue }
            let bulge = bulges.count == n && bulges[i].isFinite ? bulges[i] : 0
            guard abs(bulge) > 1e-9, simd_length(q - p) > 1e-12 else {
                try addLine(m.apply(p), m.apply(q))
                continue
            }
            // Bulge: tan(sweep / 4), positive runs counter-clockwise from p to q.
            let chord = q - p
            let center = (p + q) / 2 + Vec2(-chord.y, chord.x) * ((1 - bulge * bulge) / (4 * bulge))
            let radius = simd_length(p - center)
            let (from, to) = bulge > 0 ? (p, q) : (q, p)
            try addArc(center, radius, from: atan2(from.y - center.y, from.x - center.x),
                       to: atan2(to.y - center.y, to.x - center.x), m)
        }
    }

    private mutating func addSpline(_ raw: [Vec2], closed: Bool) throws {
        var points: [Vec2] = []
        for p in raw where usable(p) {
            if let last = points.last, simd_length(last - p) <= Self.mergeDistance { continue }
            points.append(p)
        }
        var isClosed = closed
        if points.count > 2, let f = points.first, let l = points.last, simd_length(f - l) <= Self.mergeDistance {
            points.removeLast()
            isClosed = true
        }
        guard points.count >= 2 else { return }
        if points.count == 2 { return try addLine(points[0], points[1]) }
        try countCurve()
        var ids: [Int] = []
        ids.reserveCapacity(points.count)
        for p in points { ids.append(try point(p)) }
        sketch.addSpline(ids, closed: isClosed)
    }

    private mutating func addEllipse(_ c: SIMD3<Double>, _ major: SIMD3<Double>, _ ratio: Double, _ start: Double, _ end: Double,
                                     flipped: Bool, _ m: DWGMatrix) throws {
        let u = Vec2(major.x, major.y)
        // The minor axis is the major one turned by 90° about the normal.
        let v = (flipped ? Vec2(u.y, -u.x) : Vec2(-u.y, u.x)) * ratio
        let sweep = Self.sweep(from: start, to: end)
        let full = sweep >= 2 * .pi - 1e-9
        let n = max(Int(ceil(sweep / (2 * .pi) * 48)), 6)
        let center = Vec2(c.x, c.y)
        let points = (0..<(full ? n : n + 1)).map { i -> Vec2 in
            let t = start + sweep * Double(i) / Double(n)
            return m.apply(center + u * cos(t) + v * sin(t))
        }
        try addSpline(points, closed: full)
    }

    /// Points along a NURBS curve, for the sketch's spline through points.
    static func sample(degree: Int, knots: [Double], control: [SIMD3<Double>], weights: [Double]) -> [Vec2] {
        let flat = control.map { Vec2($0.x, $0.y) }
        let n = control.count
        guard (1...25).contains(degree), n > degree, knots.count == n + degree + 1, knots.allSatisfy(\.isFinite) else { return flat }
        if degree == 1 { return flat }
        let w = weights.count == n ? weights : [Double](repeating: 1, count: n)
        let low = knots[degree], high = knots[n]
        guard high > low else { return flat }
        let count = min(max(n * 4, 16), 256)
        return (0...count).map { i in
            let t = low + (high - low) * Double(i) / Double(count)
            var span = degree
            while span < n - 1, t >= knots[span + 1] { span += 1 }
            // De Boor, in homogeneous coordinates
            var d = (0...degree).map { j -> SIMD3<Double> in
                let k = span - degree + j
                return SIMD3(flat[k].x * w[k], flat[k].y * w[k], w[k])
            }
            if degree >= 1 {
                for r in 1...degree {
                    for j in stride(from: degree, through: r, by: -1) {
                        let k = span - degree + j
                        let denominator = knots[k + degree - r + 1] - knots[k]
                        let alpha = denominator == 0 ? 0 : (t - knots[k]) / denominator
                        d[j] = d[j - 1] * (1 - alpha) + d[j] * alpha
                    }
                }
            }
            let h = d[degree]
            return h.z == 0 ? flat[span] : Vec2(h.x / h.z, h.y / h.z)
        }
    }

    // MARK: Texts

    /// Texts stay readable notes beside the geometry: as construction text they never turn into areas that get
    /// in the way of an extrusion. Sketch texts cannot turn, so a turned one is left out and reported.
    private mutating func addText(_ s: String, at p: Vec2, height: Double, rotation: Double) throws {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, usable(p), height.isFinite, height > 0 else { return }
        var turn = rotation.truncatingRemainder(dividingBy: 2 * .pi)
        if turn < 0 { turn += 2 * .pi }
        guard turn < 0.001 || 2 * .pi - turn < 0.001 else { return note(.rotatedText) }
        guard texts < DWGImporter.maxCurves else { return }
        texts += 1
        sketch.addText(text, at: sketch.addPoint(p), height: height, construction: true)
    }

    private mutating func addMText(_ s: String, at: SIMD3<Double>, height: Double, xAxis: SIMD3<Double>, attachment: Int,
                                   width: Double, _ m: DWGMatrix) throws {
        let lines = Self.plainMText(s)
        guard !lines.isEmpty else { return }
        let lineStep = height * 5 / 3
        let dir = Vec2(xAxis.x, xAxis.y)
        let rotation = simd_length(dir) > 1e-9 ? atan2(dir.y, dir.x) : 0
        // Attachment 1...9: top, middle, bottom row, each left, centre, right.
        let row = (attachment - 1) / 3, column = (attachment - 1) % 3
        let block = lineStep * Double(lines.count - 1) + height
        let top = row == 0 ? 0 : (row == 1 ? block / 2 : block)
        let left = column == 0 ? 0 : (column == 1 ? -width / 2 : -width)
        let turn = DWGMatrix.rotation(rotation).then(.translation(at.x, at.y)).then(m)
        for (i, line) in lines.enumerated() {
            let p = turn.apply(Vec2(left, top - height - Double(i) * lineStep))
            try addText(line, at: p, height: height * turn.uniformScale, rotation: turn.rotation)
        }
    }

    /// Turns control codes of TEXT into plain characters.
    static func plainText(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let r = rest.range(of: "%%") {
            out += decodeUnicode(String(rest[..<r.lowerBound]))
            rest = rest[r.upperBound...]
            guard let code = rest.first else { break }
            rest = rest.dropFirst()
            switch code.lowercased() {
            case "c": out += "Ø"
            case "d": out += "°"
            case "p": out += "±"
            case "%": out += "%"
            case "u", "o": break        // underline and overline on or off
            default: out += "%%" + String(code)
            }
        }
        return out + decodeUnicode(String(rest))
    }

    /// `\U+00E4` is how older files write characters outside their code page.
    private static func decodeUnicode(_ s: String) -> String {
        guard s.contains("\\U+") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("\\U+"), let end = s.index(i, offsetBy: 7, limitedBy: s.endIndex),
               let v = UInt32(s[s.index(i, offsetBy: 3)..<end], radix: 16), let u = Unicode.Scalar(v) {
                out.unicodeScalars.append(u)
                i = end
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// The lines of an MTEXT without its formatting codes.
    static func plainMText(_ s: String) -> [String] {
        var lines: [String] = []
        var line = ""
        var i = s.startIndex
        func advance(_ k: inout String.Index) { k = s.index(after: k) }
        while i < s.endIndex {
            let c = s[i]
            advance(&i)
            switch c {
            case "{", "}":
                continue
            case "\\":
                guard i < s.endIndex else { break }
                let code = s[i]
                advance(&i)
                switch code {
                case "P", "n":
                    lines.append(line)
                    line = ""
                case "~":
                    line.append(" ")
                case "\\", "{", "}":
                    line.append(code)
                case "U":
                    if s[i...].hasPrefix("+"), let end = s.index(i, offsetBy: 5, limitedBy: s.endIndex),
                       let v = UInt32(s[s.index(after: i)..<end], radix: 16), let u = Unicode.Scalar(v) {
                        line.unicodeScalars.append(u)
                        i = end
                    }
                case "L", "l", "O", "o", "K", "k":
                    continue
                case "S":
                    // Stacked fraction: 1/2 or 1^2, up to the semicolon.
                    while i < s.endIndex, s[i] != ";" {
                        line.append(s[i] == "^" || s[i] == "#" ? "/" : s[i])
                        advance(&i)
                    }
                    if i < s.endIndex { advance(&i) }
                default:
                    // \f, \H, \W, \C, \A, \Q, \T, \p ... carry a value up to the semicolon.
                    while i < s.endIndex, s[i] != ";" { advance(&i) }
                    if i < s.endIndex { advance(&i) }
                }
            default:
                line.append(c)
            }
        }
        lines.append(line)
        return lines.map(plainText).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
