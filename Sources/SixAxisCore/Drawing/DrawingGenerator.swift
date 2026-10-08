import Foundation
import simd

/// Builds a standards-based three-view drawing (projection method 1, ISO 5456-2) with automatic
/// baseline dimensioning from the reference ("Anschlag") edges, in whole millimetres.
/// Pure model code: no UI, safe to run on a background queue.
public final class DrawingGenerator: @unchecked Sendable {
    /// A body to draw, with its name for the parts list.
    public struct Part: Sendable {
        public var name: String
        public var shape: Shape
        public var material: String
        public var grain: GrainDirection
        public init(name: String, shape: Shape, material: String = "", grain: GrainDirection = .none) {
            self.name = name
            self.shape = shape
            self.material = material
            self.grain = grain
        }
    }

    public struct Input: Sendable {
        public var parts: [Part]
        public var settings: DrawingSettings
        public var fallbackTitle: String
        public var date: Date

        public init(parts: [Part], settings: DrawingSettings, fallbackTitle: String, date: Date = Date()) {
            self.parts = parts
            self.settings = settings
            self.fallbackTitle = fallbackTitle
            self.date = date
        }

        public init(shapes: [Shape], settings: DrawingSettings, fallbackTitle: String, date: Date = Date()) {
            self.init(parts: shapes.enumerated().map { Part(name: String(localized: "Teil \($0.offset + 1)"), shape: $0.element) },
                      settings: settings, fallbackTitle: fallbackTitle, date: date)
        }

        public var shapes: [Shape] { parts.map(\.shape) }
    }

    enum View: String, CaseIterable {
        case front, top, left, iso

        /// Direction towards the viewer and the drawing's horizontal axis (Z-up world, front = -Y).
        var axes: (dir: Vec3, x: Vec3) {
            switch self {
            case .front: return (Vec3(0, -1, 0), Vec3(1, 0, 0))
            case .top: return (Vec3(0, 0, 1), Vec3(1, 0, 0))
            case .left: return (Vec3(-1, 0, 0), Vec3(0, -1, 0))
            case .iso: return (simd_normalize(Vec3(1, -1, 1)), simd_normalize(Vec3(1, 1, 0)))
            }
        }
    }

    private var cache: [String: Projection2D] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Projections

    func projection(_ shapes: [Shape], _ view: View) -> Projection2D? {
        let key = view.rawValue + shapes.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ",")
        lock.lock()
        if let p = cache[key] { lock.unlock(); return p }
        lock.unlock()
        let shape = shapes.count == 1 ? shapes[0] : Shape.compound(shapes)
        var size = 100.0
        if let bb = shape.boundingBox { size = max(simd_length(bb.max - bb.min), 1) }
        let (dir, x) = view.axes
        guard let p = try? shape.project(viewDir: dir, xDir: x, deflection: size * 0.0004) else { return nil }
        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = p
        lock.unlock()
        return p
    }

    // MARK: - Feature extraction

    /// A position along one axis of a view, with the extent of the edges found there (for extension lines).
    struct Feature {
        var position: Double
        var low: Double
        var high: Double
        var isHole = false
    }

    struct ViewData {
        var projection: Projection2D
        var minP: Vec2
        var maxP: Vec2
        var xs: [Feature] = []   // positions of vertical edges
        var ys: [Feature] = []   // positions of horizontal edges
        var holes: [Circle2D] = []
        /// Visible arcs (fillets, rounded corners) seen in true shape.
        var arcs: [Circle2D] = []
        /// Small 45° edges (chamfers), as segments.
        var chamfers: [(Vec2, Vec2)] = []
        /// Other inclined straight edges (slopes, steep chamfers).
        var slopes: [(Vec2, Vec2)] = []

        var size: Vec2 { maxP - minP }
    }

    static func analyze(_ p: Projection2D) -> ViewData? {
        guard let b = p.bounds else { return nil }
        var v = ViewData(projection: p, minP: b.min, maxP: b.max)
        let span = max(b.max.x - b.min.x, b.max.y - b.min.y)
        let tol = max(span * 1e-4, 1e-4)
        let minLen = max(span * 0.01, 0.5)
        for line in p.polylines where !line.hidden && !line.smooth {
            for i in 0..<max(0, line.points.count - 1) {
                let a = line.points[i], c = line.points[i + 1]
                let d = c - a
                if abs(d.x) < tol, abs(d.y) >= minLen {
                    v.xs.append(Feature(position: (a.x + c.x) / 2, low: min(a.y, c.y), high: max(a.y, c.y)))
                } else if abs(d.y) < tol, abs(d.x) >= minLen {
                    v.ys.append(Feature(position: (a.y + c.y) / 2, low: min(a.x, c.x), high: max(a.x, c.x)))
                }
            }
        }
        v.holes = p.circles.filter { $0.full && !$0.hidden && $0.radius > minLen * 0.2 }
        // Deduplicate concentric circles of the same size (both ends of a through hole).
        var unique: [Circle2D] = []
        for h in v.holes where !unique.contains(where: { simd_distance($0.center, h.center) < tol * 10 && abs($0.radius - h.radius) < tol * 10 }) {
            unique.append(h)
        }
        v.holes = unique
        // Arcs: the same fillet often appears twice on top of each other (both ends of the rounded edge).
        var arcs: [Circle2D] = []
        for a in p.circles where !a.full && !a.hidden && a.radius > 0.2 && a.sweep > 0.05 {
            if !arcs.contains(where: { simd_distance($0.center, a.center) < tol * 10 && abs($0.radius - a.radius) < tol * 10 }) {
                arcs.append(a)
            }
        }
        v.arcs = arcs

        // Inclined straight edges. A chamfer is short and at 45°; everything else is a slope that gets an
        // angle dimension, and its end points join the baseline dimensions.
        var inclined: [(Vec2, Vec2)] = []
        for line in p.polylines where !line.hidden && !line.smooth && line.points.count == 2 {
            let a = line.points[0], c = line.points[1]
            let d = c - a
            guard abs(d.x) >= tol * 10, abs(d.y) >= tol * 10, simd_length(d) >= 0.3 else { continue }
            if !inclined.contains(where: { (simd_distance($0.0, a) < tol * 10 && simd_distance($0.1, c) < tol * 10)
                || (simd_distance($0.0, c) < tol * 10 && simd_distance($0.1, a) < tol * 10) }) {
                inclined.append((a, c))
            }
        }
        let small = min(b.max.x - b.min.x, b.max.y - b.min.y) * 0.25
        for seg in inclined {
            let d = seg.1 - seg.0
            if abs(abs(d.x) - abs(d.y)) < max(abs(d.x), abs(d.y)) * 0.01 && max(abs(d.x), abs(d.y)) <= max(small, 1) {
                v.chamfers.append(seg)
            } else {
                v.slopes.append(seg)
                for p in [seg.0, seg.1] {
                    v.xs.append(Feature(position: p.x, low: p.y, high: p.y))
                    v.ys.append(Feature(position: p.y, low: p.x, high: p.x))
                }
            }
        }
        return v
    }

    /// Merges positions closer than 0.5 mm and drops the reference position itself.
    static func baseline(_ features: [Feature], from base: Double) -> [Feature] {
        var merged: [Feature] = []
        for f in features.sorted(by: { $0.position < $1.position }) {
            if let last = merged.last, abs(last.position - f.position) < 0.5 {
                merged[merged.count - 1].low = min(last.low, f.low)
                merged[merged.count - 1].high = max(last.high, f.high)
                merged[merged.count - 1].isHole = last.isHole || f.isHole
            } else {
                merged.append(f)
            }
        }
        return merged.filter { abs($0.position - base) >= 0.5 }
    }

    // MARK: - View sets

    /// The three orthographic views of a set of shapes plus their (visible) dimension lists.
    struct ViewSet {
        var prefix: String
        var front: ViewData
        var top: ViewData
        var side: ViewData
        var frontX: [(Feature, String)] = []
        var frontZ: [(Feature, String)] = []
        var sideY: [(Feature, String)] = []
        var sideZ: [(Feature, String)] = []
        var topX: [(Feature, String)] = []
        var topY: [(Feature, String)] = []
        var rows = (frontBelow: 0, frontLeft: 0, sideRight: 0, topBelow: 0, topLeft: 0)
        /// Section A–A: plane position (model X) and per-body cut-face outlines in side-view coordinates.
        var sectionX: Double?
        var sideHatch: [[[Vec2]]] = []

        static func band(_ n: Int) -> Double { n == 0 ? 6 : 10 + 7 * Double(n - 1) + 6 }

        /// Paper space needed at scale s.
        func layoutSize(_ s: Double) -> (w: Double, h: Double, gapV: Double, gapH: Double, left: Double) {
            let left = max(Self.band(rows.frontLeft), Self.band(rows.topLeft))
            let gapV = Self.band(rows.frontBelow) + 8
            let gapH = 22.0
            let w = left + front.size.x * s + gapH + side.size.x * s + Self.band(rows.sideRight)
            let h = front.size.y * s + gapV + top.size.y * s + Self.band(rows.topBelow) + 4
            return (w, h, gapV, gapH, left)
        }

        func fits(_ s: Double, _ size: Vec2) -> Bool {
            let l = layoutSize(s)
            return l.w <= size.x && l.h <= size.y
        }

        func bestScale(_ size: Vec2) -> DrawingScale? { DrawingScale.all.first { fits($0.factor, size) } }
    }

    func makeViewSet(_ shapes: [Shape], prefix: String, settings: DrawingSettings, section: Bool = false) -> ViewSet? {
        guard !shapes.isEmpty,
              let front = projection(shapes, .front).flatMap(Self.analyze),
              let top = projection(shapes, .top).flatMap(Self.analyze) else { return nil }
        // Section A–A: the left view shows what remains behind the cutting plane, cut faces hatched.
        var sectionX: Double?
        var hatch: [[[Vec2]]] = []
        var sideShapes = shapes
        if section, let cut = sectionCut(shapes, x: settings.sectionX) {
            sectionX = cut.x
            sideShapes = cut.remaining
            hatch = cut.faces.map { $0.faceOutlines(viewDir: View.left.axes.dir, xDir: View.left.axes.x, deflection: 0.05) }
        }
        guard let side = projection(sideShapes, .left).flatMap(Self.analyze) else { return nil }
        var set = ViewSet(prefix: prefix, front: front, top: top, side: side)
        set.sectionX = sectionX
        set.sideHatch = hatch
        func holeX(_ v: ViewData) -> [Feature] { v.holes.map { Feature(position: $0.center.x, low: $0.center.y - $0.radius, high: $0.center.y + $0.radius, isHole: true) } }
        func holeY(_ v: ViewData) -> [Feature] { v.holes.map { Feature(position: $0.center.y, low: $0.center.x - $0.radius, high: $0.center.x + $0.radius, isHole: true) } }
        // Edges created by 45° chamfers show up as extra lines in the other views; their positions
        // repeat the chamfer callout and are left out (ISO: each dimension only once).
        let chamferSizes = Set((front.chamfers + top.chamfers + side.chamfers).map { Int((abs($0.1.x - $0.0.x) * 10).rounded()) })
        func withoutChamferEdges(_ f: [Feature], _ lo: Double, _ hi: Double) -> [Feature] {
            guard !chamferSizes.isEmpty else { return f }
            return f.filter { feat in
                !chamferSizes.contains { c in
                    let size = Double(c) / 10
                    return abs(feat.position - lo - size) < 0.25 || abs(hi - feat.position - size) < 0.25
                }
            }
        }
        let frontXAll = Self.baseline(withoutChamferEdges(front.xs, front.minP.x, front.maxP.x) + holeX(front), from: front.minP.x)
        let frontZAll = Self.baseline(withoutChamferEdges(front.ys, front.minP.y, front.maxP.y) + holeY(front), from: front.minP.y)
        let sideYAll = Self.baseline(withoutChamferEdges(side.xs, side.minP.x, side.maxP.x) + holeX(side), from: side.minP.x)
        // Heights are dimensioned in the front view; the side view only adds heights of side holes.
        let frontZValues = Set(frontZAll.map { Int(($0.position - front.minP.y).rounded()) })
        let sideZAll = Self.baseline(holeY(side), from: side.minP.y).filter { !frontZValues.contains(Int(($0.position - side.minP.y).rounded())) }
        // Top view: only hole positions, X values not already given in the front view.
        let frontXValues = Set(frontXAll.map { Int(($0.position - front.minP.x).rounded()) })
        let topXAll = Self.baseline(holeX(top), from: top.minP.x).filter { !frontXValues.contains(Int(($0.position - top.minP.x).rounded())) }
        let topYAll = Self.baseline(holeY(top), from: top.minP.y)

        // Stable ids ("front.x.481", "p2.front.x.300") let manual edits survive model changes;
        // hidden ones close up their row.
        func visible(_ f: [Feature], _ view: String, _ axis: String, _ base: Double) -> [(Feature, String)] {
            guard settings.showDimensions else { return [] }
            return f.map { ($0, Self.dimensionId(prefix + view, axis, $0.position - base)) }
                .filter { !settings.hiddenDimensions.contains($0.1) }
        }
        set.frontX = visible(frontXAll, "front", "x", front.minP.x)
        set.frontZ = visible(frontZAll, "front", "y", front.minP.y)
        set.sideY = visible(sideYAll, "left", "x", side.minP.x)
        set.sideZ = visible(sideZAll, "left", "y", side.minP.y)
        set.topX = visible(topXAll, "top", "x", top.minP.x)
        set.topY = visible(topYAll, "top", "y", top.minP.y)
        func depth(_ f: [(Feature, String)]) -> Int { f.isEmpty ? 0 : (Self.assignRows(f, settings.dimensionOffsets).max() ?? 0) + 1 }
        set.rows = (max(depth(set.frontX), depth(set.sideY)), depth(set.frontZ), depth(set.sideZ), depth(set.topX), depth(set.topY))
        return set
    }

    // MARK: - Section A–A

    private var sectionCache: [String: (x: Double, remaining: [Shape], faces: [Shape])] = [:]

    /// Removes the material in front of the plane X = x (seen from the left) and returns the cut faces per body.
    func sectionCut(_ shapes: [Shape], x requested: Double?) -> (x: Double, remaining: [Shape], faces: [Shape])? {
        let all = shapes.count == 1 ? shapes[0] : Shape.compound(shapes)
        guard let bb = all.boundingBox else { return nil }
        let x = min(max(requested ?? (bb.min.x + bb.max.x) / 2, bb.min.x + 0.01), bb.max.x - 0.01)
        let key = shapes.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ",") + "@\(Int((x * 100).rounded()))"
        lock.lock()
        if let c = sectionCache[key] { lock.unlock(); return c }
        lock.unlock()
        let pad = Vec3(10, 10, 10)
        guard let box = try? Shape.box(min: bb.min - pad, max: Vec3(x, bb.max.y + 10, bb.max.z + 10)) else { return nil }
        let size = simd_length(bb.max - bb.min) + 100
        guard let plane = try? Shape.planeFace(origin: Vec3(x, (bb.min.y + bb.max.y) / 2, (bb.min.z + bb.max.z) / 2),
                                               normal: Vec3(1, 0, 0), xDir: Vec3(0, 1, 0), halfSize: size) else { return nil }
        var remaining: [Shape] = [], faces: [Shape] = []
        for s in shapes {
            if let r = try? s.boolean(.cut, box), r.solidCount > 0 { remaining.append(r) }
            if let f = try? s.boolean(.common, plane), f.faceCount > 0 { faces.append(f) }
        }
        let result = (x, remaining.isEmpty ? shapes : remaining, faces)
        lock.lock()
        if sectionCache.count > 16 { sectionCache.removeAll() }
        sectionCache[key] = result
        lock.unlock()
        return result
    }

    /// Hatch lines (paper mm) inside closed outlines, even-odd rule.
    static func hatch(_ outlines: [[Vec2]], angle: Double, spacing: Double) -> [(Vec2, Vec2)] {
        let d = Vec2(cos(angle), sin(angle)), n = Vec2(-d.y, d.x)
        var edges: [(Vec2, Vec2)] = []
        for poly in outlines where poly.count >= 2 {
            for i in 0..<(poly.count - 1) { edges.append((poly[i], poly[i + 1])) }
        }
        guard !edges.isEmpty else { return [] }
        let ts = edges.flatMap { [simd_dot($0.0, n), simd_dot($0.1, n)] }
        guard let tMin = ts.min(), let tMax = ts.max() else { return [] }
        var out: [(Vec2, Vec2)] = []
        var t = (tMin / spacing).rounded(.up) * spacing
        while t < tMax {
            var hits: [Double] = []
            for (a, b) in edges {
                let na = simd_dot(a, n) - t, nb = simd_dot(b, n) - t
                if (na < 0) != (nb < 0) {
                    let p = a + (b - a) * (na / (na - nb))
                    hits.append(simd_dot(p, d))
                }
            }
            hits.sort()
            var i = 0
            while i + 1 < hits.count {
                if hits[i + 1] - hits[i] > 1e-6 { out.append((n * t + d * hits[i], n * t + d * hits[i + 1])) }
                i += 2
            }
            t += spacing
        }
        return out
    }

    private func addSection(_ page: inout DrawingPage, _ set: ViewSet, front pf: PlacedView, side pl: PlacedView) {
        guard let x = set.sectionX else { return }
        // Hatching: alternate direction per body so adjacent parts stay distinguishable (ISO 128-50).
        for (i, outlines) in set.sideHatch.enumerated() {
            let paper = outlines.map { $0.map(pl.toPaper) }
            let angle = i % 2 == 0 ? Double.pi / 4 : 3 * Double.pi / 4
            for (a, b) in Self.hatch(paper, angle: angle, spacing: 2.5 + Double(i % 3) * 0.5) {
                page.lines.append(DrawingLine(points: [a, b], style: .hatch))
            }
        }
        page.texts.append(DrawingText(text: "A–A", position: Vec2((pl.min.x + pl.max.x) / 2, pl.max.y + 6), height: 5, anchor: .center, bold: true))
        // Cutting plane in the front view: thin chain line, thick ends, arrows in the viewing direction (+X).
        let id = "section.A"
        let px = pf.toPaper(Vec2(x, 0)).x
        let top = pf.max.y + 7, bottom = pf.min.y - 7
        page.lines.append(DrawingLine(points: [Vec2(px, bottom), Vec2(px, top)], style: .center, group: id))
        page.lines.append(DrawingLine(points: [Vec2(px, pf.max.y + 1.5), Vec2(px, top)], style: .frame, group: id))
        page.lines.append(DrawingLine(points: [Vec2(px, pf.min.y - 1.5), Vec2(px, bottom)], style: .frame, group: id))
        for y in [top, bottom] {
            page.lines.append(DrawingLine(points: [Vec2(px, y), Vec2(px + 8, y)], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: Vec2(px + 8, y), direction: Vec2(1, 0), group: id))
            page.texts.append(DrawingText(text: "A", position: Vec2(px + 10, y - 1.75), height: 5, anchor: .left, bold: true, group: id))
        }
        var d = PlacedDimension(id: id, text: String(localized: "Schnitt A–A"), segments: [(Vec2(px, bottom), Vec2(px, top))],
                                textCenter: Vec2(px + 11, top), normal: Vec2(1, 0), along: Vec2(0, 1), isCustom: false)
        d.value = x
        page.dimensions.append(d)
    }

    // MARK: - Details ("Einzelheit Z")

    private func addDetails(_ page: inout DrawingPage, _ details: [DetailView], sources: [String: (ViewData, PlacedView)],
                            settings: DrawingSettings) {
        let area = Self.drawingArea(page.sheet)
        var nextRight = area.origin.x + area.size.x - 6
        for d in details {
            guard let (v, pv) = sources[d.view] else { continue }
            let k = pv.scale * d.factor
            let R = d.radius * k
            // Mark in the source view.
            let c = pv.toPaper(d.center), r = d.radius * pv.scale
            let ring = (0...48).map { c + r * Vec2(cos(Double($0) / 48 * 2 * .pi), sin(Double($0) / 48 * 2 * .pi)) }
            page.lines.append(DrawingLine(points: ring, style: .thin, group: d.markId))
            let lp = c + simd_normalize(Vec2(1, 1)) * (r + 4)
            page.texts.append(DrawingText(text: d.letter, position: lp, height: 5, anchor: .left, bold: true, group: d.markId))
            page.dimensions.append(PlacedDimension(id: d.markId, text: String(localized: "Einzelheit \(d.letter)"),
                                                   segments: (0..<48).map { (ring[$0], ring[$0 + 1]) },
                                                   textCenter: lp + Vec2(2, 2), normal: Vec2(0, 1), along: Vec2(1, 0), isCustom: false))
            // Detail view, by default stacked from the top-right corner.
            let base = Vec2(nextRight - R, area.origin.y + area.size.y - R - 10)
            nextRight -= 2 * R + 14
            let dc = base + (settings.viewOffsets[d.viewId] ?? .zero)
            let placed = PlacedView(id: d.viewId, title: String(localized: "Einzelheit \(d.letter)"), min: dc - Vec2(R, R), max: dc + Vec2(R, R),
                                    origin: dc, modelMin: d.center, scale: k, constraint: .free)
            page.views.append(placed)
            for line in v.projection.polylines where !line.smooth && (settings.showHidden || !line.hidden) {
                for seg in Self.clip(line.points, center: d.center, radius: d.radius) {
                    page.lines.append(DrawingLine(points: seg.map(placed.toPaper), style: line.hidden ? .hidden : .visible))
                }
            }
            for h in v.holes where simd_distance(h.center, d.center) < d.radius {
                let hc = placed.toPaper(h.center), hr = h.radius * k + 2.5
                page.lines.append(DrawingLine(points: [hc - Vec2(hr, 0), hc + Vec2(hr, 0)], style: .center))
                page.lines.append(DrawingLine(points: [hc - Vec2(0, hr), hc + Vec2(0, hr)], style: .center))
            }
            let boundary = (0...64).map { dc + R * Vec2(cos(Double($0) / 64 * 2 * .pi), sin(Double($0) / 64 * 2 * .pi)) }
            page.lines.append(DrawingLine(points: boundary, style: .thin))
            page.texts.append(DrawingText(text: "\(d.letter) (\(Self.ratio(k)))", position: dc + Vec2(0, R + 4), height: 5, anchor: .center, bold: true))
            // Corners inside the detail can anchor user dimensions.
            let snaps = page.snapPoints.filter { $0.view == pv.id && simd_distance($0.model, d.center) <= d.radius }
            page.snapPoints += snaps.map { DrawingSnapPoint(view: d.viewId, paper: placed.toPaper($0.model), model: $0.model) }
        }
    }

    /// Parts of a polyline inside a circle.
    static func clip(_ pts: [Vec2], center c: Vec2, radius r: Double) -> [[Vec2]] {
        var out: [[Vec2]] = []
        var current: [Vec2] = []
        func inside(_ p: Vec2) -> Bool { simd_distance(p, c) <= r }
        for i in 0..<max(0, pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            // |a + t d - c|² = r²
            let f = a - c
            let A = simd_dot(d, d), B = 2 * simd_dot(f, d), C = simd_dot(f, f) - r * r
            var t0 = 0.0, t1 = 1.0
            if A < 1e-12 { if !inside(a) { continue } } else {
                let disc = B * B - 4 * A * C
                if disc < 0 { if !current.isEmpty { out.append(current); current = [] }; continue }
                let s = sqrt(disc)
                t0 = max(0, (-B - s) / (2 * A)); t1 = min(1, (-B + s) / (2 * A))
                if t0 >= t1 { if !current.isEmpty { out.append(current); current = [] }; continue }
            }
            let p0 = a + d * t0, p1 = a + d * t1
            if current.isEmpty || simd_distance(current.last!, p0) > 1e-9 {
                if !current.isEmpty { out.append(current) }
                current = [p0]
            }
            current.append(p1)
            if t1 < 1 { out.append(current); current = [] }
        }
        if current.count > 1 { out.append(current) }
        return out.filter { $0.count > 1 }
    }

    /// Scale as ISO ratio, e.g. 0.5 → "1:2", 2 → "2:1".
    static func ratio(_ k: Double) -> String {
        if k >= 1 {
            let v = (k * 10).rounded() / 10
            return v == v.rounded() ? "\(Int(v)):1" : String(format: "%.1f:1", v)
        }
        let v = (1 / k * 10).rounded() / 10
        return v == v.rounded() ? "1:\(Int(v))" : String(format: "1:%.1f", v)
    }

    /// Draws a view set centred in `region` at scale `s` and returns the placed views (front, left, top).
    @discardableResult
    func emit(_ set: ViewSet, into page: inout DrawingPage, region: (origin: Vec2, size: Vec2), s: Double,
              settings: DrawingSettings, sources: inout [String: (ViewData, PlacedView)]) -> [PlacedView] {
        let L = set.layoutSize(s)
        let p = set.prefix
        // Manual offsets keep the projection alignment: the front view moves everything,
        // the top view only vertically, the side view only horizontally.
        let all = settings.viewOffsets[p + "front"] ?? .zero
        let originX = region.origin.x + (region.size.x - L.w) / 2 + L.left
        let frontTop = region.origin.y + region.size.y - (region.size.y - L.h) / 2 - 2
        let frontOrigin = Vec2(originX, frontTop - set.front.size.y * s) + all
        let sideOrigin = Vec2(frontOrigin.x + set.front.size.x * s + L.gapH + (settings.viewOffsets[p + "left"]?.x ?? 0), frontOrigin.y)
        let topOrigin = Vec2(frontOrigin.x, frontOrigin.y - L.gapV - set.top.size.y * s + (settings.viewOffsets[p + "top"]?.y ?? 0))

        let pf = Self.place(p + "front", String(localized: "Vorderansicht"), set.front, frontOrigin, .all, s)
        let pl = Self.place(p + "left", String(localized: "Seitenansicht von links"), set.side, sideOrigin, .horizontal, s)
        let pt = Self.place(p + "top", String(localized: "Draufsicht"), set.top, topOrigin, .vertical, s)
        page.views += [pf, pl, pt]

        for (v, pv) in [(set.front, pf), (set.side, pl), (set.top, pt)] {
            addView(&page, v, pv.toPaper, showHidden: settings.showHidden)
            addCenterLines(&page, v, map: pv.toPaper, s: s)
            addSnapPoints(&page, v, pv)
        }
        let o = settings.dimensionOffsets
        horizontalBaseline(&page, set.frontX, base: set.front.minP.x, map: pf.toPaper, view: set.front, offsets: o)
        verticalBaseline(&page, set.frontZ, base: set.front.minP.y, map: pf.toPaper, view: set.front, leftSide: true, offsets: o)
        horizontalBaseline(&page, set.sideY, base: set.side.minP.x, map: pl.toPaper, view: set.side, offsets: o)
        verticalBaseline(&page, set.sideZ, base: set.side.minP.y, map: pl.toPaper, view: set.side, leftSide: false, offsets: o)
        horizontalBaseline(&page, set.topX, base: set.top.minP.x, map: pt.toPaper, view: set.top, offsets: o)
        verticalBaseline(&page, set.topY, base: set.top.minP.y, map: pt.toPaper, view: set.top, leftSide: true, offsets: o)
        if settings.showDimensions {
            var radiiDone = Set<Int>(), chamfersDone = Set<Int>()
            for (v, pv) in [(set.front, pf), (set.top, pt), (set.side, pl)] {
                addRadiusLabels(&page, v, viewId: pv.id, map: pv.toPaper, s: s, hidden: settings.hiddenDimensions, offsets: o, done: &radiiDone)
                addChamferLabels(&page, v, viewId: pv.id, map: pv.toPaper, hidden: settings.hiddenDimensions, offsets: o, done: &chamfersDone)
                addAngleDimensions(&page, v, viewId: pv.id, map: pv.toPaper, hidden: settings.hiddenDimensions, offsets: o)
                addHoleLabels(&page, v, viewId: pv.id, map: pv.toPaper, s: s, hidden: settings.hiddenDimensions, offsets: o)
            }
        }
        addSection(&page, set, front: pf, side: pl)
        sources[pf.id] = (set.front, pf)
        sources[pl.id] = (set.side, pl)
        sources[pt.id] = (set.top, pt)
        return [pf, pl, pt]
    }

    static func place(_ id: String, _ title: String, _ v: ViewData, _ origin: Vec2, _ c: PlacedView.Constraint, _ k: Double) -> PlacedView {
        PlacedView(id: id, title: title, min: origin, max: origin + v.size * k, origin: origin, modelMin: v.minP, scale: k, constraint: c)
    }

    // MARK: - Parts

    /// Identical bodies (same size, volume and topology) share one position number.
    public struct PartGroup: Sendable {
        public var position: Int
        public var name: String
        public var count: Int
        /// Cut sizes: length ≥ width ≥ thickness (bounding box, whole mm).
        public var length: Int
        public var width: Int
        public var thickness: Int
        public var material: String
        public var grain: GrainDirection
        var shape: Shape
    }

    public func groupParts(_ parts: [Part]) -> [PartGroup] {
        var groups: [(key: String, group: PartGroup)] = []
        for part in parts {
            guard let bb = part.shape.boundingBox else { continue }
            let e = (bb.max - bb.min)
            let sorted = [e.x, e.y, e.z].sorted(by: >)
            // Same size, volume, topology, material and grain → same part.
            let key = sorted.map { String(format: "%.1f", $0) }.joined(separator: "x")
                + "|\(Int(part.shape.volume.rounded()))|\(part.shape.faceCount)|\(part.material)|\(part.grain.rawValue)"
            if let i = groups.firstIndex(where: { $0.key == key }) {
                groups[i].group.count += 1
            } else {
                groups.append((key, PartGroup(position: groups.count + 1, name: part.name, count: 1,
                                              length: Int(sorted[0].rounded()), width: Int(sorted[1].rounded()),
                                              thickness: Int(sorted[2].rounded()), material: part.material,
                                              grain: part.grain, shape: part.shape)))
            }
        }
        return groups.map(\.group)
    }

    /// Orients a part for its own drawing: length → X, width → Z (up), thickness → Y (depth),
    /// so the front view shows the main face with its drilling pattern.
    static func normalized(_ shape: Shape) -> Shape {
        guard let bb = shape.boundingBox else { return shape }
        let e = bb.max - bb.min
        let order = [0, 1, 2].sorted { e[$0] > e[$1] }
        func axis(_ i: Int) -> Vec3 { i == 0 ? Vec3(1, 0, 0) : (i == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1)) }
        let newX = axis(order[0]), newZ = axis(order[1])
        var newY = axis(order[2])
        // Proper rotation only (no mirroring): y = z × x.
        if simd_dot(simd_cross(newZ, newX), newY) < 0 { newY = -newY }
        let r = simd_double3x3(rows: [newX, newY, newZ])
        guard let rotated = try? shape.transformed(rotation: r, translation: .zero),
              let rb = rotated.boundingBox,
              let moved = try? rotated.translated(-rb.min) else { return shape }
        return moved
    }

    // MARK: - Generate

    /// First sheet only (assembly). Kept for callers that need a single page.
    public func generate(_ input: Input) -> DrawingPage { generatePages(input)[0] }

    /// All sheets: the assembly ("Gesamtansicht") and, for several bodies, part sheets ("Einzelteile").
    public func generatePages(_ input: Input) -> [DrawingPage] {
        let settings = input.settings
        let groups = groupParts(input.parts)
        let multi = input.parts.count > 1
        let sheets: [Sheet] = settings.sheet == .auto ? [.a4, .a3, .a2] : [sheetFor(settings.sheet)!]

        guard let set = makeViewSet(input.shapes, prefix: "", settings: settings, section: settings.sectionLeft) else {
            var page = DrawingPage(sheet: sheets[0], scale: DrawingScale.named("1:1")!)
            page.texts.append(DrawingText(text: String(localized: "Keine sichtbaren Körper"), position: Vec2(page.sheet.width / 2, page.sheet.height / 2 + 10), height: 5))
            var pages = [page]
            addTitleBlocks(&pages, input)
            return pages
        }

        // Space for the parts list (above the title block) and the balloon row (above the front view).
        let listHeight = multi && settings.showPartsList ? Self.listRowHeight * Double(groups.count + 1) + 2 : 0
        let balloonBand = multi && settings.showBalloons ? 18.0 : 0
        func region(_ sheet: Sheet) -> (origin: Vec2, size: Vec2) {
            var a = Self.drawingArea(sheet)
            a.origin.y += listHeight
            a.size.y -= listHeight + balloonBand
            return a
        }

        // Sheet and scale.
        var sheet = sheets[0]
        var scale = DrawingScale.all.last!
        if let fixed = settings.scale.flatMap(DrawingScale.named) {
            scale = fixed
            sheet = sheets.first { set.fits(fixed.factor, region($0).size) } ?? sheets.last!
        } else {
            var chosen: (Sheet, DrawingScale)?
            for s in sheets {
                guard let sc = set.bestScale(region(s).size) else { continue }
                if chosen == nil { chosen = (s, sc) }
                // Go to a larger sheet only if the smaller one forces a very small scale.
                if let c = chosen, c.1.factor < 0.1, sc.factor > c.1.factor { chosen = (s, sc) }
            }
            if let chosen { (sheet, scale) = chosen } else { sheet = sheets.last! }
        }

        var page = DrawingPage(sheet: sheet, scale: scale)
        page.isEmpty = false
        let s = scale.factor
        let r = region(sheet)
        var sources: [String: (ViewData, PlacedView)] = [:]
        let placed = emit(set, into: &page, region: r, s: s, settings: settings, sources: &sources)
        for c in settings.customDimensions where !settings.hiddenDimensions.contains(c.key) {
            addCustomDimension(&page, c)
        }

        // Pictorial view in the free quadrant (right of the top view, above the parts list); freely movable.
        let sideView = placed[1]
        if settings.showIso, let iso = projection(input.shapes, .iso).flatMap(Self.analyze) {
            let area = Self.drawingArea(sheet)
            let regionMin = Vec2(sideView.min.x, r.origin.y + 2)
            let regionMax = Vec2(area.origin.x + area.size.x - 4, sideView.min.y - ViewSet.band(set.rows.frontBelow) - 2)
            let free = regionMax - regionMin
            if free.x > 35 && free.y > 30 {
                let fit = min(free.x / max(iso.size.x, 1e-6), free.y / max(iso.size.y, 1e-6)) * 0.9
                let k = min(fit, s)
                let center = (regionMin + regionMax) / 2 + (settings.viewOffsets["iso"] ?? .zero)
                let pi = Self.place("iso", String(localized: "Isometrie"), iso, center - iso.size * k / 2, .free, k)
                page.views.append(pi)
                for line in iso.projection.polylines where !line.hidden && !line.smooth {
                    page.lines.append(DrawingLine(points: line.points.map(pi.toPaper), style: .iso))
                }
            }
        }

        if multi && settings.showBalloons {
            addBalloons(&page, groups: groups, parts: input.parts, front: placed[0], top: r.origin.y + r.size.y + balloonBand - 4,
                        offsets: settings.dimensionOffsets, hidden: settings.hiddenDimensions)
        }
        if multi && settings.showPartsList {
            addPartsList(&page, groups, material: settings.material)
        }
        addDetails(&page, settings.details.filter { sources[$0.view] != nil }, sources: sources, settings: settings)

        var pages = [page]
        if multi && settings.showPartSheets {
            pages += partSheets(groups, sheet: sheet, settings: settings)
        }
        addTitleBlocks(&pages, input)
        return pages
    }

    // MARK: - Balloons (ISO 6433)

    private func addBalloons(_ page: inout DrawingPage, groups: [PartGroup], parts: [Part], front: PlacedView, top: Double,
                             offsets: [String: DimensionOffset], hidden: Set<String>) {
        // Anchor: centre of the first body of each group, seen in the front view (x = X, y = Z).
        var anchors: [(PartGroup, Vec2)] = []
        for g in groups {
            guard let part = parts.first(where: { $0.shape === g.shape }) ?? parts.first(where: { $0.name == g.name }),
                  let bb = part.shape.boundingBox else { continue }
            // Spread anchors along the part's width (golden-ratio steps), so parts sharing a centre
            // (e.g. bottom and shelf) get separate leaders that don't run through each other's dots.
            let f = 0.25 + 0.5 * (Double(g.position) * 0.618).truncatingRemainder(dividingBy: 1)
            let x = bb.min.x + (bb.max.x - bb.min.x) * f
            anchors.append((g, front.toPaper(Vec2(x, (bb.min.z + bb.max.z) / 2))))
        }
        anchors.sort { $0.1.x < $1.1.x }
        let radius = 4.5, spacing = 12.0
        var lastX = -Double.infinity
        for (g, anchor) in anchors {
            let id = "balloon.\(g.position)"
            guard !hidden.contains(id) else { continue }
            var x = max(anchor.x, lastX + spacing)
            lastX = x
            let shift = offsets[id].map { Vec2($0.along, $0.distance) } ?? .zero
            x += shift.x
            let c = Vec2(x, top - radius + shift.y)
            let dir = simd_normalize(anchor - c)
            let start = c + dir * radius
            page.lines.append(DrawingLine(points: [start, anchor], style: .thin, group: id))
            page.lines.append(DrawingLine(points: (0...40).map { c + radius * Vec2(cos(Double($0) / 40 * 2 * .pi), sin(Double($0) / 40 * 2 * .pi)) },
                                          style: .thin, group: id))
            // Leader ends with a dot inside the part.
            page.lines.append(DrawingLine(points: (0...12).map { anchor + 0.6 * Vec2(cos(Double($0) / 12 * 2 * .pi), sin(Double($0) / 12 * 2 * .pi)) },
                                          style: .visible, group: id))
            page.texts.append(DrawingText(text: "\(g.position)", position: c - Vec2(0, 1.75), height: 3.5, anchor: .center, group: id))
            page.dimensions.append(PlacedDimension(id: id, text: String(localized: "Pos. \(g.position)"), segments: [(start, anchor)],
                                                   textCenter: c, normal: Vec2(0, 1), along: Vec2(1, 0), isCustom: false))
        }
    }

    // MARK: - Parts list / cut list (ISO 7573, above the title block)

    static let listRowHeight = 6.0

    private func addPartsList(_ page: inout DrawingPage, _ groups: [PartGroup], material: String) {
        let x1 = page.sheet.width - 10, x0 = x1 - Self.titleWidth
        let y0 = 10 + Self.titleHeight
        let rh = Self.listRowHeight
        // Columns: Pos | Benennung | Anzahl | Länge | Breite | Dicke | Material
        let widths: [Double] = [12, 58, 16, 22, 22, 20, 30]
        var xs = [x0]
        for w in widths { xs.append(xs.last! + w) }
        let rows = groups.count + 1
        let top = y0 + rh * Double(rows)
        page.lines.append(DrawingLine(points: [Vec2(x0, y0), Vec2(x0, top), Vec2(x1, top), Vec2(x1, y0)], style: .frame))
        for i in 1..<rows {
            page.lines.append(DrawingLine(points: [Vec2(x0, y0 + rh * Double(i)), Vec2(x1, y0 + rh * Double(i))], style: i == 1 ? .visible : .thin))
        }
        for x in xs.dropFirst().dropLast() {
            page.lines.append(DrawingLine(points: [Vec2(x, y0), Vec2(x, top)], style: .thin))
        }
        func row(_ i: Int, _ cells: [String], bold: Bool = false) {
            let y = y0 + rh * Double(i) + 1.9
            for (c, text) in cells.enumerated() {
                let numeric = c == 0 || (c >= 2 && c <= 5)
                let pos = numeric ? Vec2(xs[c + 1] - 1.5, y) : Vec2(xs[c] + 1.5, y)
                page.texts.append(DrawingText(text: text, position: pos, height: bold ? 2.2 : 2.5, anchor: numeric ? .right : .left, bold: bold))
            }
        }
        // Header next to the title block, positions numbered upwards.
        row(0, [String(localized: "Pos."), String(localized: "Benennung"), String(localized: "Anzahl"), String(localized: "Länge"), String(localized: "Breite"), String(localized: "Dicke"), String(localized: "Material")], bold: true)
        for (i, g) in groups.enumerated() {
            let mat = g.material.isEmpty ? material : g.material
            let grain = g.grain == .none ? "" : (g.grain == .length ? " ↔" : " ↕")
            row(i + 1, ["\(g.position)", g.name, "\(g.count)", "\(g.length)", "\(g.width)", "\(g.thickness)", mat + grain])
        }
    }

    // MARK: - Part sheets

    private func partSheets(_ groups: [PartGroup], sheet: Sheet, settings: DrawingSettings) -> [DrawingPage] {
        let sets: [(PartGroup, ViewSet)] = groups.compactMap { g in
            makeViewSet([Self.normalized(g.shape)], prefix: "p\(g.position).", settings: settings).map { (g, $0) }
        }
        guard !sets.isEmpty else { return [] }
        let area = Self.drawingArea(sheet)
        // Cells per sheet: as many as possible while every part still fits at 1:20 or larger.
        let layouts: [(cols: Int, rows: Int)] = [(2, 2), (2, 1), (1, 1)]
        func cellSize(_ l: (cols: Int, rows: Int)) -> Vec2 {
            Vec2(area.size.x / Double(l.cols), area.size.y / Double(l.rows) - 10)   // 10 mm for the part title
        }
        let layout = layouts.first { l in sets.allSatisfy { ($0.1.bestScale(cellSize(l))?.factor ?? 0) >= 0.05 } } ?? (1, 1)
        let perSheet = layout.cols * layout.rows
        let size = cellSize(layout)

        var pages: [DrawingPage] = []
        for (n, chunk) in stride(from: 0, to: sets.count, by: perSheet).map({ Array(sets[$0..<min($0 + perSheet, sets.count)]) }).enumerated() {
            var page = DrawingPage(sheet: sheet, scale: DrawingScale.named("1:1")!)
            page.name = pages.isEmpty && sets.count <= perSheet ? String(localized: "Einzelteile") : String(localized: "Einzelteile \(n + 1)")
            page.isEmpty = false
            var scales: Set<String> = []
            var sources: [String: (ViewData, PlacedView)] = [:]
            for (i, (g, set)) in chunk.enumerated() {
                let col = i % layout.cols, row = i / layout.cols
                let origin = Vec2(area.origin.x + Double(col) * area.size.x / Double(layout.cols),
                                  area.origin.y + area.size.y - Double(row + 1) * area.size.y / Double(layout.rows))
                let sc = set.bestScale(size) ?? DrawingScale.all.last!
                scales.insert(sc.label)
                page.scale = sc
                let placed = emit(set, into: &page, region: (origin, size), s: sc.factor, settings: settings, sources: &sources)
                if g.grain != .none, let front = placed.first { addGrainArrow(&page, front, along: g.grain) }
                let mat = g.material.isEmpty ? settings.material : g.material
                let heading = String(localized: "Pos. \(g.position)   \(g.name)   \(g.count) Stück   \(g.length) × \(g.width) × \(g.thickness)")
                    + (mat.isEmpty ? "" : "   \(mat)") + "   M \(sc.label)"
                page.texts.append(DrawingText(text: heading, position: origin + Vec2(2, size.y + 4), height: 3.5, anchor: .left, bold: true))
            }
            page.scaleText = scales.count == 1 ? scales.first : String(localized: "siehe Teile")
            addDetails(&page, settings.details.filter { sources[$0.view] != nil }, sources: sources, settings: settings)
            for c in settings.customDimensions where !settings.hiddenDimensions.contains(c.key) {
                addCustomDimension(&page, c)
            }
            pages.append(page)
        }
        return pages
    }

    /// Grain direction symbol (DIN 919): double-headed arrow in the part's main face.
    private func addGrainArrow(_ page: inout DrawingPage, _ v: PlacedView, along grain: GrainDirection) {
        let c = (v.min + v.max) / 2
        let size = v.max - v.min
        let u = grain == .length ? Vec2(1, 0) : Vec2(0, 1)
        let half = (grain == .length ? size.x : size.y) * 0.3
        guard half > 4 else { return }
        let a = c - u * half, b = c + u * half
        page.lines.append(DrawingLine(points: [a, b], style: .thin))
        page.arrows.append(DrawingArrow(tip: a, direction: -u))
        page.arrows.append(DrawingArrow(tip: b, direction: u))
        let n = Vec2(-u.y, u.x)
        page.texts.append(DrawingText(text: String(localized: "Faser"), position: c + n * 1.5, height: 2.5, angle: atan2(u.y, u.x), anchor: .center))
    }

    private func addTitleBlocks(_ pages: inout [DrawingPage], _ input: Input) {
        for i in pages.indices {
            addFrameAndTitle(&pages[i], input, sheet: i + 1, of: pages.count)
        }
    }

    /// Returns a copy of `page` with one more user dimension (live preview while placing).
    public func adding(_ c: CustomDimension, to page: DrawingPage) -> DrawingPage {
        var p = page
        addCustomDimension(&p, c)
        return p
    }

    public static func dimensionId(_ view: String, _ axis: String, _ value: Double) -> String {
        "\(view).\(axis).\(Int(value.rounded()))"
    }

    // MARK: - Geometry output

    private func addView(_ page: inout DrawingPage, _ v: ViewData, _ map: (Vec2) -> Vec2, showHidden: Bool) {
        for line in v.projection.polylines where !line.smooth {
            if line.hidden && !showHidden { continue }
            page.lines.append(DrawingLine(points: line.points.map(map), style: line.hidden ? .hidden : .visible))
        }
    }

    /// Corners and line ends of visible edges plus hole centres: anchors for user dimensions.
    private func addSnapPoints(_ page: inout DrawingPage, _ v: ViewData, _ pv: PlacedView) {
        var pts: [Vec2] = v.holes.map(\.center)
        let tol = max(simd_length(v.size) * 1e-5, 1e-4)
        for line in v.projection.polylines where !line.hidden && !line.smooth {
            guard let first = line.points.first, let last = line.points.last else { continue }
            for p in [first, last] where !pts.contains(where: { simd_distance($0, p) < tol }) { pts.append(p) }
        }
        page.snapPoints += pts.map { DrawingSnapPoint(view: pv.id, paper: pv.toPaper($0), model: $0) }
    }

    private func addCenterLines(_ page: inout DrawingPage, _ v: ViewData, map: (Vec2) -> Vec2, s: Double) {
        for h in v.holes {
            let c = map(h.center)
            let r = h.radius * s + 2.5
            page.lines.append(DrawingLine(points: [c - Vec2(r, 0), c + Vec2(r, 0)], style: .center))
            page.lines.append(DrawingLine(points: [c - Vec2(0, r), c + Vec2(0, r)], style: .center))
        }
    }

    /// Ø callouts: one leader per distinct diameter, "n× Ø8" for repeated holes. Offsets move the label.
    private func addHoleLabels(_ page: inout DrawingPage, _ v: ViewData, viewId: String, map: (Vec2) -> Vec2, s: Double,
                               hidden: Set<String>, offsets: [String: DimensionOffset]) {
        let groups = Dictionary(grouping: v.holes) { Int((20 * $0.radius).rounded()) }   // diameter in 0.1 mm
        for (d10, holes) in groups.sorted(by: { $0.key < $1.key }) {
            let d = Self.mmText(Double(d10) / 10)
            let id = d10 % 10 == 0 ? "\(viewId).hole.\(d10 / 10)" : "\(viewId).hole.\(d)"
            guard !hidden.contains(id),
                  let h = holes.max(by: { $0.center.x + $0.center.y < $1.center.x + $1.center.y }) else { continue }
            let c = map(h.center)
            let shift = offsets[id].map { Vec2($0.along, $0.distance) } ?? .zero
            let text = (holes.count > 1 ? "\(holes.count)× " : "") + "Ø\(d)"
            let shelf = Double(text.count) * 2.2 + 2
            // Try the four diagonals; take the first without touching other callouts, else push outwards.
            let dirs = [Vec2(1, 1), Vec2(-1, 1), Vec2(1, -1), Vec2(-1, -1)].map(simd_normalize)
            var knee0: Vec2?
            for u in dirs where knee0 == nil {
                knee0 = Self.leaderKnee(&page, tip: c + u * h.radius * s, u: u, shift: shift, width: shelf, push: false)
            }
            let knee = knee0 ?? Self.leaderKnee(&page, tip: c + dirs[0] * h.radius * s, u: dirs[0], shift: shift, width: shelf)!
            let u = simd_normalize(knee - c)
            let rim = c + u * h.radius * s
            let right = knee.x >= rim.x - 1e-9
            let end = knee + Vec2(right ? shelf : -shelf, 0)
            page.lines.append(DrawingLine(points: [rim, knee, end], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: rim, direction: -u, group: id))
            page.texts.append(DrawingText(text: text, position: knee + Vec2(right ? 1 : -1, 1), height: 3.5,
                                          anchor: right ? .left : .right, group: id))
            page.dimensions.append(PlacedDimension(id: id, text: text, segments: [(rim, knee), (knee, end)],
                                                   textCenter: (knee + end) / 2 + Vec2(0, 2.5), normal: Vec2(0, 1), along: Vec2(1, 0), isCustom: false))
        }
    }

    static let textHeight = 3.5

    /// Whole millimetres where possible, otherwise one decimal with a comma (DIN), e.g. "2,5".
    static func mmText(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
    }

    /// Knee point for a leader label: starts 7 mm out from `tip` along `u` and moves further out
    /// until the label's area is free. Registers the area.
    static func leaderKnee(_ page: inout DrawingPage, tip: Vec2, u: Vec2, shift: Vec2, width: Double, push: Bool = true) -> Vec2? {
        func area(_ knee: Vec2) -> (min: Vec2, max: Vec2) {
            let right = knee.x >= tip.x - 1e-9
            let x0 = right ? knee.x : knee.x - width
            return (Vec2(x0 - 1, knee.y - 1), Vec2(x0 + width + 1, knee.y + 5))
        }
        func free(_ knee: Vec2) -> Bool {
            let a = area(knee)
            let overlaps = page.leaderAreas.contains { b in a.min.x < b.max.x && a.max.x > b.min.x && a.min.y < b.max.y && a.max.y > b.min.y }
            return !overlaps && !page.leaderLines.contains { Self.segmentsClose(($0.0, $0.1), (tip, knee), 2.5) }
        }
        var knee = tip + u * 7 + shift
        if !free(knee) {
            guard push else { return nil }
            for step in 1...12 {
                knee = tip + u * (7 + 5 * Double(step)) + shift
                if free(knee) { break }
            }
        }
        page.leaderAreas.append(area(knee))
        page.leaderLines.append((tip, knee))
        return knee
    }

    /// True if two segments come closer than `d` (sampled; good enough for label placement).
    static func segmentsClose(_ a: (Vec2, Vec2), _ b: (Vec2, Vec2), _ d: Double) -> Bool {
        for i in 0...10 {
            let p = a.0 + (a.1 - a.0) * (Double(i) / 10)
            let e = b.1 - b.0
            let t = max(0, min(1, simd_dot(p - b.0, e) / max(simd_length_squared(e), 1e-12)))
            if simd_distance(p, b.0 + e * t) < d { return true }
        }
        return false
    }

    /// 45° chamfers: leader to the chamfer with "Fase 2 × 45°" (ISO 129-1), "(4×)" for repeated ones,
    /// once per view set.
    private func addChamferLabels(_ page: inout DrawingPage, _ v: ViewData, viewId: String, map: (Vec2) -> Vec2,
                                  hidden: Set<String>, offsets: [String: DimensionOffset], done: inout Set<Int>) {
        let groups = Dictionary(grouping: v.chamfers) { Int((abs($0.1.x - $0.0.x) * 10).rounded()) }
        for (s10, segs) in groups.sorted(by: { $0.key < $1.key }) where !done.contains(s10) {
            done.insert(s10)
            let id = "\(viewId).chamfer.\(s10)"
            guard !hidden.contains(id),
                  let seg = segs.max(by: { ($0.0 + $0.1).x + ($0.0 + $0.1).y < ($1.0 + $1.1).x + ($1.0 + $1.1).y }) else { continue }
            let tip = map((seg.0 + seg.1) / 2)
            // Leader perpendicular to the chamfer, pointing away from the view's centre.
            let d = simd_normalize(map(seg.1) - map(seg.0))
            var u = Vec2(-d.y, d.x)
            let viewCenter = map((v.minP + v.maxP) / 2)
            if simd_dot(u, tip - viewCenter) < 0 { u = -u }
            let shift = offsets[id].map { Vec2($0.along, $0.distance) } ?? .zero
            let text = String(localized: "Fase \(Self.mmText(Double(s10) / 10)) × 45°") + (segs.count > 1 ? " (\(segs.count)×)" : "")
            let shelf = Double(text.count) * 2.0 + 2
            let knee = Self.leaderKnee(&page, tip: tip, u: u, shift: shift, width: shelf)!
            let right = knee.x >= tip.x - 1e-9
            let end = knee + Vec2(right ? shelf : -shelf, 0)
            page.lines.append(DrawingLine(points: [tip, knee, end], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: tip, direction: -simd_normalize(knee - tip), group: id))
            page.texts.append(DrawingText(text: text, position: knee + Vec2(right ? 1 : -1, 1), height: 3.5,
                                          anchor: right ? .left : .right, group: id))
            page.dimensions.append(PlacedDimension(id: id, text: text, segments: [(tip, knee), (knee, end)],
                                                   textCenter: (knee + end) / 2 + Vec2(0, 2.5), normal: Vec2(0, 1), along: Vec2(1, 0), isCustom: false))
        }
    }

    /// Angle dimension for a slope: arc between the inclined edge and the horizontal or vertical
    /// reference at its lower/left end, value in whole degrees (ISO 129-1).
    private func addAngleDimensions(_ page: inout DrawingPage, _ v: ViewData, viewId: String, map: (Vec2) -> Vec2,
                                    hidden: Set<String>, offsets: [String: DimensionOffset]) {
        for (k, seg) in v.slopes.enumerated() {
            let d0 = seg.1 - seg.0
            let flat = abs(d0.y) <= abs(d0.x)                       // reference: horizontal if the slope is flatter than 45°
            // Vertex: the end nearer to the reference edge's start (left for horizontal, bottom for vertical).
            let (va, vb) = flat ? (seg.0.x <= seg.1.x ? (seg.0, seg.1) : (seg.1, seg.0))
                                : (seg.0.y <= seg.1.y ? (seg.0, seg.1) : (seg.1, seg.0))
            let vertex = map(va), other = map(vb)
            let us = simd_normalize(other - vertex)
            let ur = flat ? Vec2(us.x >= 0 ? 1 : -1, 0) : Vec2(0, us.y >= 0 ? 1 : -1)
            let degrees = Int((acos(max(-1, min(1, simd_dot(us, ur)))) * 180 / .pi).rounded())
            guard degrees > 0 && degrees < 90 else { continue }
            let id = "\(viewId).angle.\(degrees).\(k)"
            guard !hidden.contains(id) else { continue }
            let off = offsets[id] ?? DimensionOffset()
            let a0 = atan2(ur.y, ur.x), a1 = atan2(us.y, us.x)
            var sweep = a1 - a0
            if sweep > .pi { sweep -= 2 * .pi }
            if sweep < -.pi { sweep += 2 * .pi }
            // Small angles need a large radius so the arc is long enough for both arrows (≈ 14 mm).
            let length = simd_distance(vertex, other)
            let r = max(12, min(14 / max(abs(sweep), 1e-3), length * 0.85)) + off.distance
            let arc = (0...24).map { i -> Vec2 in
                let t = a0 + sweep * Double(i) / 24
                return vertex + r * Vec2(cos(t), sin(t))
            }
            // Extension along the reference (the slope itself is the other leg).
            page.lines.append(DrawingLine(points: [vertex + ur * 1.5, vertex + ur * (r + 2)], style: .thin, group: id))
            page.lines.append(DrawingLine(points: arc, style: .thin, group: id))
            let tangent0 = simd_normalize(arc[1] - arc[0]), tangent1 = simd_normalize(arc[24] - arc[23])
            page.arrows.append(DrawingArrow(tip: arc[0], direction: -tangent0, group: id))
            page.arrows.append(DrawingArrow(tip: arc[24], direction: tangent1, group: id))
            let mid = a0 + sweep / 2
            let textPos = vertex + (r + 4) * Vec2(cos(mid), sin(mid)) + Vec2(off.along, 0) - Vec2(0, 1.75)
            page.texts.append(DrawingText(text: "\(degrees)°", position: textPos, height: 3.5, anchor: .center, group: id))
            page.dimensions.append(PlacedDimension(id: id, text: "\(degrees)°", segments: (0..<24).map { (arc[$0], arc[$0 + 1]) },
                                                   textCenter: textPos + Vec2(0, 1.75), normal: Vec2(cos(mid), sin(mid)),
                                                   along: Vec2(1, 0), isCustom: false))
        }
    }

    /// Radius callouts (ISO 129-1): leader from outside with the arrow on the arc, "R5" or "4× R5".
    /// Each radius is given once per view set, in the first view where it appears in true shape.
    private func addRadiusLabels(_ page: inout DrawingPage, _ v: ViewData, viewId: String, map: (Vec2) -> Vec2, s: Double,
                                 hidden: Set<String>, offsets: [String: DimensionOffset], done: inout Set<Int>) {
        let groups = Dictionary(grouping: v.arcs) { Int(($0.radius * 10).rounded()) }
        for (r10, arcs) in groups.sorted(by: { $0.key < $1.key }) where !done.contains(r10) {
            done.insert(r10)
            let id = "\(viewId).radius.\(r10)"
            // Representative arc: the one furthest up-right, so the leader points away from the part.
            guard !hidden.contains(id),
                  let a = arcs.max(by: { $0.mid.x + $0.mid.y < $1.mid.x + $1.mid.y }) else { continue }
            let tip = map(a.mid), c = map(a.center)
            var u = tip - c
            u = simd_length(u) > 1e-9 ? simd_normalize(u) : Vec2(1, 1) / 2.squareRoot()
            let shift = offsets[id].map { Vec2($0.along, $0.distance) } ?? .zero
            let text = (arcs.count > 1 ? "\(arcs.count)× " : "") + "R" + Self.mmText(Double(r10) / 10)
            let shelf = Double(text.count) * 2.2 + 2
            let knee = Self.leaderKnee(&page, tip: tip, u: u, shift: shift, width: shelf)!
            let right = knee.x >= tip.x - 1e-9
            let end = knee + Vec2(right ? shelf : -shelf, 0)
            let dir = simd_normalize(knee - tip)
            page.lines.append(DrawingLine(points: [tip, knee, end], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: tip, direction: -dir, group: id))
            page.texts.append(DrawingText(text: text, position: knee + Vec2(right ? 1 : -1, 1), height: 3.5,
                                          anchor: right ? .left : .right, group: id))
            page.dimensions.append(PlacedDimension(id: id, text: text, segments: [(tip, knee), (knee, end)],
                                                   textCenter: (knee + end) / 2 + Vec2(0, 2.5), normal: Vec2(0, 1), along: Vec2(1, 0), isCustom: false))
        }
    }

    /// Rows (0 = nearest, 7 mm apart) for a stack of baseline dimensions. Dimensions the user moved
    /// snap to the nearest row and are placed first; the others keep their row or move outwards,
    /// so values never overlap.
    static func assignRows(_ features: [(Feature, String)], _ offsets: [String: DimensionOffset]) -> [Int] {
        var rows = [Int](repeating: -1, count: features.count)
        var used = Set<Int>()
        func take(_ i: Int, _ wanted: Int) {
            var r = max(0, wanted)
            while used.contains(r) { r += 1 }
            rows[i] = r
            used.insert(r)
        }
        for (i, (_, id)) in features.enumerated() {
            if let d = offsets[id]?.distance, d != 0 { take(i, Int(((7 * Double(i) + d) / 7).rounded())) }
        }
        for i in features.indices where rows[i] < 0 { take(i, i) }
        return rows
    }

    private func horizontalBaseline(_ page: inout DrawingPage, _ features: [(Feature, String)], base: Double,
                                    map: (Vec2) -> Vec2, view: ViewData, offsets: [String: DimensionOffset]) {
        let x0 = map(Vec2(base, view.minP.y)).x
        let edgeY = map(view.minP).y
        var lowest = edgeY
        let rows = Self.assignRows(features, offsets)
        for (i, (f, id)) in features.enumerated() {
            let off = offsets[id] ?? DimensionOffset()
            let lineY = edgeY - 10 - 7 * Double(rows[i])
            lowest = min(lowest, lineY)
            let x1 = map(Vec2(f.position, 0)).x
            let featureLow = map(Vec2(0, f.low)).y
            page.lines.append(DrawingLine(points: [Vec2(x1, featureLow - 1.5), Vec2(x1, lineY - 2)], style: .thin, group: id))
            dimensionLine(&page, id: id, from: Vec2(x0, lineY), to: Vec2(x1, lineY), value: abs(f.position - base),
                          away: Vec2(0, -1), along: off.along)
        }
        // One extension line at the reference edge, reaching the outermost dimension line.
        if !features.isEmpty {
            page.lines.append(DrawingLine(points: [Vec2(x0, edgeY - 1.5), Vec2(x0, lowest - 2)], style: .thin))
        }
    }

    private func verticalBaseline(_ page: inout DrawingPage, _ features: [(Feature, String)], base: Double,
                                  map: (Vec2) -> Vec2, view: ViewData, leftSide: Bool, offsets: [String: DimensionOffset]) {
        let y0 = map(Vec2(view.minP.x, base)).y
        let edgeX = leftSide ? map(view.minP).x : map(view.maxP).x
        let sign: Double = leftSide ? -1 : 1
        var outer = edgeX
        let rows = Self.assignRows(features, offsets)
        for (i, (f, id)) in features.enumerated() {
            let off = offsets[id] ?? DimensionOffset()
            let lineX = edgeX + sign * (10 + 7 * Double(rows[i]))
            outer = leftSide ? min(outer, lineX) : max(outer, lineX)
            let y1 = map(Vec2(0, f.position)).y
            let featureEdge = leftSide ? map(Vec2(f.low, 0)).x : map(Vec2(f.high, 0)).x
            page.lines.append(DrawingLine(points: [Vec2(featureEdge + sign * 1.5, y1), Vec2(lineX + sign * 2, y1)], style: .thin, group: id))
            dimensionLine(&page, id: id, from: Vec2(lineX, y0), to: Vec2(lineX, y1), value: abs(f.position - base),
                          away: Vec2(sign, 0), along: off.along)
        }
        if !features.isEmpty {
            page.lines.append(DrawingLine(points: [Vec2(edgeX + sign * 1.5, y0), Vec2(outer + sign * 2, y0)], style: .thin))
        }
    }

    /// User dimension between two view points; endpoints re-snap to the nearest current vertex,
    /// so the dimension follows small model changes.
    private func addCustomDimension(_ page: inout DrawingPage, _ c: CustomDimension) {
        guard let pv = page.views.first(where: { $0.id == c.view }) else { return }
        let snaps = page.snapPoints.filter { $0.view == c.view }
        func resnap(_ p: Vec2) -> Vec2 {
            guard let best = snaps.min(by: { simd_distance($0.model, p) < simd_distance($1.model, p) }),
                  simd_distance(best.model, p) < 1.0 else { return p }
            return best.model
        }
        let a = resnap(c.a), b = resnap(c.b)
        let pa = pv.toPaper(a), pb = pv.toPaper(b)
        let n: Vec2
        let da: Vec2, db: Vec2
        let value: Double
        switch c.orientation {
        case .horizontal:
            n = Vec2(0, 1)
            da = Vec2(pa.x, pa.y + c.offset); db = Vec2(pb.x, pa.y + c.offset)
            value = abs(b.x - a.x)
        case .vertical:
            n = Vec2(1, 0)
            da = Vec2(pa.x + c.offset, pa.y); db = Vec2(pa.x + c.offset, pb.y)
            value = abs(b.y - a.y)
        case .aligned:
            let d = pb - pa
            let u = simd_length(d) > 1e-9 ? simd_normalize(d) : Vec2(1, 0)
            n = Vec2(-u.y, u.x)
            da = pa + n * c.offset; db = pb + n * c.offset
            value = simd_distance(a, b)
        }
        let sgn: Double = c.offset >= 0 ? 1 : -1
        for (p, q) in [(pa, da), (pb, db)] where simd_distance(p, q) > 0.5 {
            let dir = simd_normalize(q - p)
            page.lines.append(DrawingLine(points: [p + dir * 1.5, q + dir * 2], style: .thin, group: c.key))
        }
        dimensionLine(&page, id: c.key, from: da, to: db, value: value, away: n * sgn, along: 0, isCustom: true)
    }

    /// Dimension line with filled arrows and the value in whole millimetres (ISO 129-1).
    /// The value reads from the bottom or the right; `along` shifts it along the line.
    private func dimensionLine(_ page: inout DrawingPage, id: String, from a: Vec2, to b: Vec2, value: Double,
                               away: Vec2, along shift: Double, isCustom: Bool = false) {
        let text = "\(Int(value.rounded()))"
        let d = b - a
        let len = simd_length(d)
        guard len > 1e-6 else { return }
        let u = d / len
        // Reading direction: left-to-right, or bottom-to-top for vertical lines.
        let r = (u.x > 1e-9 || (abs(u.x) <= 1e-9 && u.y > 0)) ? u : -u
        let angle = atan2(r.y, r.x)
        let n = Vec2(-r.y, r.x)                      // "above" the line when reading
        let textWidth = Double(text.count) * Self.textHeight * 0.62
        let mid = (a + b) / 2
        var segments = [(a, b)]
        let textPos: Vec2
        if len >= textWidth + 8 {
            page.lines.append(DrawingLine(points: [a, b], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: a, direction: -u, group: id))
            page.arrows.append(DrawingArrow(tip: b, direction: u, group: id))
            textPos = mid + r * shift + n * 1.0
        } else {
            // Too short: arrows from outside, value placed beyond the end.
            let tail = b + u * (6 + textWidth)
            page.lines.append(DrawingLine(points: [a - u * 5, tail], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: a, direction: u, group: id))
            page.arrows.append(DrawingArrow(tip: b, direction: -u, group: id))
            segments = [(a - u * 5, tail)]
            textPos = b + u * (4 + textWidth / 2) + r * shift + n * 1.0
        }
        page.texts.append(DrawingText(text: text, position: textPos, height: Self.textHeight, angle: angle, anchor: .center, group: id))
        page.dimensions.append(PlacedDimension(id: id, text: text, segments: segments, textCenter: textPos + n * (Self.textHeight / 2),
                                               normal: simd_normalize(away), along: r, isCustom: isCustom))
    }

    // MARK: - Sheet, frame, title block (ISO 5457 / ISO 7200)

    static let titleWidth = 180.0
    static let titleHeight = 36.0

    /// Usable drawing area inside the frame, above the title block band.
    static func drawingArea(_ sheet: Sheet) -> (origin: Vec2, size: Vec2) {
        let origin = Vec2(20 + 4, 10 + titleHeight + 4)
        return (origin, Vec2(sheet.width - 20 - 10 - 8, sheet.height - 20 - titleHeight - 8))
    }

    private func sheetFor(_ c: DrawingSettings.SheetChoice) -> Sheet? {
        switch c {
        case .a4: return .a4
        case .a3: return .a3
        case .a2: return .a2
        case .auto: return nil
        }
    }

    private func addFrameAndTitle(_ page: inout DrawingPage, _ input: Input, sheet number: Int, of total: Int) {
        let w = page.sheet.width, h = page.sheet.height
        let fx0 = 20.0, fy0 = 10.0, fx1 = w - 10, fy1 = h - 10
        page.lines.append(DrawingLine(points: [Vec2(fx0, fy0), Vec2(fx1, fy0), Vec2(fx1, fy1), Vec2(fx0, fy1), Vec2(fx0, fy0)], style: .frame))
        // Centering marks.
        for p in [(Vec2(w / 2, 0), Vec2(w / 2, fy0)), (Vec2(w / 2, fy1), Vec2(w / 2, h)), (Vec2(0, h / 2), Vec2(fx0, h / 2)), (Vec2(fx1, h / 2), Vec2(w, h / 2))] {
            page.lines.append(DrawingLine(points: [p.0, p.1], style: .visible))
        }

        // Title block, bottom right.
        let tw = Self.titleWidth, th = Self.titleHeight
        let x0 = fx1 - tw, y0 = fy0
        let split = x0 + 130
        let r1 = y0 + 10, r2 = y0 + 20
        func rect(_ a: Vec2, _ b: Vec2, _ style: LineStyle) {
            page.lines.append(DrawingLine(points: [a, Vec2(b.x, a.y), b, Vec2(a.x, b.y), a], style: style))
        }
        rect(Vec2(x0, y0), Vec2(fx1, y0 + th), .frame)
        page.lines.append(DrawingLine(points: [Vec2(x0, r2), Vec2(fx1, r2)], style: .thin))
        page.lines.append(DrawingLine(points: [Vec2(x0, r1), Vec2(fx1, r1)], style: .thin))
        page.lines.append(DrawingLine(points: [Vec2(split, y0), Vec2(split, y0 + th)], style: .thin))
        let c1 = x0 + 45, c2 = x0 + 90
        page.lines.append(DrawingLine(points: [Vec2(c1, y0), Vec2(c1, r2)], style: .thin))
        page.lines.append(DrawingLine(points: [Vec2(c2, y0), Vec2(c2, r2)], style: .thin))

        let s = input.settings
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        // Label small at the top of the cell, value at the bottom.
        func field(_ label: String, _ value: String, at p: Vec2, rowHeight: Double = 10, size: Double = 3.5, bold: Bool = false) {
            page.texts.append(DrawingText(text: label, position: p + Vec2(1.5, rowHeight - 3.2), height: 1.8, anchor: .left))
            page.texts.append(DrawingText(text: value, position: p + Vec2(1.5, 1.8), height: size, anchor: .left, bold: bold))
        }
        let base = s.title.isEmpty ? input.fallbackTitle : s.title
        let title = page.name == String(localized: "Gesamtansicht") ? base : "\(base) – \(page.name)"
        page.texts.append(DrawingText(text: String(localized: "Benennung"), position: Vec2(x0 + 1.5, y0 + th - 3.4), height: 1.8, anchor: .left))
        page.texts.append(DrawingText(text: title, position: Vec2(x0 + 3, r2 + 4.5), height: 5, anchor: .left, bold: true))
        field(String(localized: "Zeichnungsnummer"), s.drawingNumber, at: Vec2(x0, r1))
        field(String(localized: "Material"), s.material, at: Vec2(c1, r1))
        field(String(localized: "Datum"), df.string(from: input.date), at: Vec2(c2, r1))
        field(String(localized: "Erstellt von"), s.author, at: Vec2(x0, y0))
        field(String(localized: "Software"), "6axis", at: Vec2(c1, y0))
        field(String(localized: "Einheit"), "mm", at: Vec2(c2, y0))
        let scaleText = page.scaleText ?? page.scale.label
        field(String(localized: "Maßstab"), scaleText, at: Vec2(split, r2), rowHeight: th - 20, size: scaleText.count > 6 ? 3.5 : 5, bold: true)
        field(String(localized: "Blatt"), "\(number) / \(total)", at: Vec2(split, r1))
        page.texts.append(DrawingText(text: page.sheet.name, position: Vec2(fx1 - 2, r1 + 1.8), height: 3.5, anchor: .right))
        page.texts.append(DrawingText(text: String(localized: "Projektionsmethode 1"), position: Vec2(split + 1.5, y0 + 6.8), height: 1.8, anchor: .left))
        projectionSymbol(&page, at: Vec2(split + 24, y0 + 1.4))
    }

    /// ISO 5456-2 projection method 1 symbol: truncated cone (front) left, end view (circles) right.
    private func projectionSymbol(_ page: inout DrawingPage, at p: Vec2) {
        let h = 4.0, d = 4.0 / 0.6
        let left = p + Vec2(-11, 0)
        page.lines.append(DrawingLine(points: [left + Vec2(0, h / 4), left + Vec2(6, 0), left + Vec2(6, h), left + Vec2(0, h * 3 / 4), left + Vec2(0, h / 4)], style: .thin))
        page.lines.append(DrawingLine(points: [left + Vec2(-1.5, h / 2), left + Vec2(7.5, h / 2)], style: .center))
        let c = p + Vec2(3.5, h / 2)
        func circle(_ r: Double) -> [Vec2] { (0...32).map { c + r * Vec2(cos(Double($0) / 32 * 2 * .pi), sin(Double($0) / 32 * 2 * .pi)) } }
        page.lines.append(DrawingLine(points: circle(d / 2 * 0.6), style: .thin))
        page.lines.append(DrawingLine(points: circle(h / 4), style: .thin))
    }
}
