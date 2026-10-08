import Foundation
import simd

/// Builds a standards-based three-view drawing (projection method 1, ISO 5456-2) with automatic
/// baseline dimensioning from the reference ("Anschlag") edges, in whole millimetres.
/// Pure model code: no UI, safe to run on a background queue.
public final class DrawingGenerator: @unchecked Sendable {
    public struct Input: Sendable {
        public var shapes: [Shape]
        public var settings: DrawingSettings
        public var fallbackTitle: String
        public var date: Date

        public init(shapes: [Shape], settings: DrawingSettings, fallbackTitle: String, date: Date = Date()) {
            self.shapes = shapes
            self.settings = settings
            self.fallbackTitle = fallbackTitle
            self.date = date
        }
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

    // MARK: - Generate

    public func generate(_ input: Input) -> DrawingPage {
        let settings = input.settings
        let shapes = input.shapes
        let front = shapes.isEmpty ? nil : projection(shapes, .front).flatMap(Self.analyze)
        let top = shapes.isEmpty ? nil : projection(shapes, .top).flatMap(Self.analyze)
        let side = shapes.isEmpty ? nil : projection(shapes, .left).flatMap(Self.analyze)

        guard let front, let top, let side else {
            var page = DrawingPage(sheet: sheetFor(settings.sheet) ?? .a4, scale: DrawingScale.named("1:1")!)
            addFrameAndTitle(&page, input)
            page.texts.append(DrawingText(text: "Keine sichtbaren Körper", position: Vec2(page.sheet.width / 2, page.sheet.height / 2 + 10), height: 5))
            return page
        }

        // Dimension sets in model units (computed once, independent of scale).
        func holeX(_ v: ViewData) -> [Feature] { v.holes.map { Feature(position: $0.center.x, low: $0.center.y - $0.radius, high: $0.center.y + $0.radius, isHole: true) } }
        func holeY(_ v: ViewData) -> [Feature] { v.holes.map { Feature(position: $0.center.y, low: $0.center.x - $0.radius, high: $0.center.x + $0.radius, isHole: true) } }
        let frontXAll = Self.baseline(front.xs + holeX(front), from: front.minP.x)
        let frontZAll = Self.baseline(front.ys + holeY(front), from: front.minP.y)
        let sideYAll = Self.baseline(side.xs + holeX(side), from: side.minP.x)
        // Heights are dimensioned in the front view; the side view only adds heights of side holes.
        let frontZValues = Set(frontZAll.map { Int(($0.position - front.minP.y).rounded()) })
        let sideZAll = Self.baseline(holeY(side), from: side.minP.y).filter { !frontZValues.contains(Int(($0.position - side.minP.y).rounded())) }
        // Top view: only hole positions, X values not already given in the front view.
        let frontXValues = Set(frontXAll.map { Int(($0.position - front.minP.x).rounded()) })
        let topXAll = Self.baseline(holeX(top), from: top.minP.x).filter { !frontXValues.contains(Int(($0.position - top.minP.x).rounded())) }
        let topYAll = Self.baseline(holeY(top), from: top.minP.y)

        // Stable ids ("front.x.481") let manual edits survive model changes; hidden ones close up their row.
        let dims = settings.showDimensions
        func visible(_ f: [Feature], _ view: String, _ axis: String, _ base: Double) -> [(Feature, String)] {
            guard dims else { return [] }
            return f.map { ($0, Self.dimensionId(view, axis, $0.position - base)) }.filter { !settings.hiddenDimensions.contains($0.1) }
        }
        let frontX = visible(frontXAll, "front", "x", front.minP.x)
        let frontZ = visible(frontZAll, "front", "y", front.minP.y)
        let sideY = visible(sideYAll, "left", "x", side.minP.x)
        let sideZ = visible(sideZAll, "left", "y", side.minP.y)
        let topX = visible(topXAll, "top", "x", top.minP.x)
        let topY = visible(topYAll, "top", "y", top.minP.y)
        func depth(_ f: [(Feature, String)]) -> Int { f.isEmpty ? 0 : (Self.assignRows(f, settings.dimensionOffsets).max() ?? 0) + 1 }
        let rows = (frontBelow: max(depth(frontX), depth(sideY)), frontLeft: depth(frontZ),
                    sideRight: depth(sideZ), topBelow: depth(topX), topLeft: depth(topY))

        func band(_ n: Int) -> Double { n == 0 ? 6 : 10 + 7 * Double(n - 1) + 6 }

        // Paper space needed at scale s.
        func layoutSize(_ s: Double) -> (w: Double, h: Double, gapV: Double, gapH: Double, left: Double) {
            let left = max(band(rows.frontLeft), band(rows.topLeft))
            let gapV = band(rows.frontBelow) + 8
            let gapH = 22.0
            let w = left + front.size.x * s + gapH + side.size.x * s + band(rows.sideRight)
            let h = front.size.y * s + gapV + top.size.y * s + band(rows.topBelow) + 4
            return (w, h, gapV, gapH, left)
        }

        // Sheet and scale.
        let sheets: [Sheet] = settings.sheet == .auto ? [.a4, .a3, .a2] : [sheetFor(settings.sheet)!]
        func bestScale(_ sheet: Sheet) -> DrawingScale? {
            let area = Self.drawingArea(sheet)
            return DrawingScale.all.first { sc in
                let l = layoutSize(sc.factor)
                return l.w <= area.size.x && l.h <= area.size.y
            }
        }
        var sheet = sheets[0]
        var scale = DrawingScale.all.last!
        if let fixed = settings.scale.flatMap(DrawingScale.named) {
            scale = fixed
            sheet = sheets.first { s in
                let a = Self.drawingArea(s), l = layoutSize(fixed.factor)
                return l.w <= a.size.x && l.h <= a.size.y
            } ?? sheets.last!
        } else {
            var chosen: (Sheet, DrawingScale)?
            for s in sheets {
                guard let sc = bestScale(s) else { continue }
                if chosen == nil { chosen = (s, sc) }
                // Go to a larger sheet only if the smaller one forces a very small scale.
                if let c = chosen, c.1.factor < 0.1, sc.factor > c.1.factor { chosen = (s, sc) }
            }
            if let chosen { (sheet, scale) = chosen } else { sheet = sheets.last!; scale = DrawingScale.all.last! }
        }

        var page = DrawingPage(sheet: sheet, scale: scale)
        page.isEmpty = false
        addFrameAndTitle(&page, input)

        // Placement: front top-left, left-side view to the right, top view below (method 1).
        // Manual offsets keep the projection alignment: the front view moves everything,
        // the top view only vertically, the side view only horizontally.
        let s = scale.factor
        let L = layoutSize(s)
        let area = Self.drawingArea(sheet)
        let all = settings.viewOffsets["front"] ?? .zero
        let originX = area.origin.x + (area.size.x - L.w) / 2 + L.left
        let frontTop = area.origin.y + area.size.y - (area.size.y - L.h) / 2 - 2
        let frontOrigin = Vec2(originX, frontTop - front.size.y * s) + all
        let sideOrigin = Vec2(frontOrigin.x + front.size.x * s + L.gapH + (settings.viewOffsets["left"]?.x ?? 0), frontOrigin.y)
        let topOrigin = Vec2(frontOrigin.x, frontOrigin.y - L.gapV - top.size.y * s + (settings.viewOffsets["top"]?.y ?? 0))

        func place(_ id: String, _ title: String, _ v: ViewData, _ origin: Vec2, _ c: PlacedView.Constraint, _ k: Double) -> PlacedView {
            PlacedView(id: id, title: title, min: origin, max: origin + v.size * k, origin: origin, modelMin: v.minP, scale: k, constraint: c)
        }
        let pf = place("front", "Vorderansicht", front, frontOrigin, .all, s)
        let pl = place("left", "Seitenansicht von links", side, sideOrigin, .horizontal, s)
        let pt = place("top", "Draufsicht", top, topOrigin, .vertical, s)
        page.views = [pf, pl, pt]

        addView(&page, front, pf.toPaper, showHidden: settings.showHidden)
        addView(&page, side, pl.toPaper, showHidden: settings.showHidden)
        addView(&page, top, pt.toPaper, showHidden: settings.showHidden)
        for (v, pv) in [(front, pf), (side, pl), (top, pt)] {
            addCenterLines(&page, v, map: pv.toPaper, s: s)
            addSnapPoints(&page, v, pv)
        }

        let o = settings.dimensionOffsets
        if dims {
            // Front: X from the left edge (below), Z from the bottom edge (left).
            horizontalBaseline(&page, frontX, base: front.minP.x, map: pf.toPaper, view: front, offsets: o)
            verticalBaseline(&page, frontZ, base: front.minP.y, map: pf.toPaper, view: front, leftSide: true, offsets: o)
            horizontalBaseline(&page, sideY, base: side.minP.x, map: pl.toPaper, view: side, offsets: o)
            verticalBaseline(&page, sideZ, base: side.minP.y, map: pl.toPaper, view: side, leftSide: false, offsets: o)
            horizontalBaseline(&page, topX, base: top.minP.x, map: pt.toPaper, view: top, offsets: o)
            verticalBaseline(&page, topY, base: top.minP.y, map: pt.toPaper, view: top, leftSide: true, offsets: o)
            for (v, pv) in [(front, pf), (side, pl), (top, pt)] {
                addHoleLabels(&page, v, viewId: pv.id, map: pv.toPaper, s: s, hidden: settings.hiddenDimensions, offsets: o)
            }
        }
        for c in settings.customDimensions where !settings.hiddenDimensions.contains(c.key) {
            addCustomDimension(&page, c)
        }

        // Pictorial view in the free quadrant (right of the top view, above the title block); freely movable.
        if settings.showIso, let iso = projection(shapes, .iso).flatMap(Self.analyze) {
            let regionMin = Vec2(sideOrigin.x, area.origin.y + 2)
            let regionMax = Vec2(area.origin.x + area.size.x - 4, sideOrigin.y - band(rows.frontBelow) - 2)
            let region = regionMax - regionMin
            if region.x > 35 && region.y > 30 {
                let fit = min(region.x / max(iso.size.x, 1e-6), region.y / max(iso.size.y, 1e-6)) * 0.9
                let k = min(fit, s)
                let center = (regionMin + regionMax) / 2 + (settings.viewOffsets["iso"] ?? .zero)
                let pi = place("iso", "Isometrie", iso, center - iso.size * k / 2, .free, k)
                page.views.append(pi)
                for line in iso.projection.polylines where !line.hidden && !line.smooth {
                    page.lines.append(DrawingLine(points: line.points.map(pi.toPaper), style: .iso))
                }
            }
        }
        return page
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
        let groups = Dictionary(grouping: v.holes) { Int((2 * $0.radius).rounded()) }
        for (d, holes) in groups.sorted(by: { $0.key < $1.key }) {
            let id = "\(viewId).hole.\(d)"
            guard !hidden.contains(id),
                  let h = holes.max(by: { $0.center.x + $0.center.y < $1.center.x + $1.center.y }) else { continue }
            let c = map(h.center)
            let shift = offsets[id].map { Vec2($0.along, $0.distance) } ?? .zero
            let knee0 = c + simd_normalize(Vec2(1, 1)) * (h.radius * s + 7) + shift
            let u = simd_normalize(knee0 - c)
            let rim = c + u * h.radius * s
            let text = (holes.count > 1 ? "\(holes.count)× " : "") + "Ø\(d)"
            let shelf = Double(text.count) * 2.2 + 2
            page.lines.append(DrawingLine(points: [rim, knee0, knee0 + Vec2(shelf, 0)], style: .thin, group: id))
            page.arrows.append(DrawingArrow(tip: rim, direction: -u, group: id))
            page.texts.append(DrawingText(text: text, position: knee0 + Vec2(1, 1), height: 3.5, anchor: .left, group: id))
            page.dimensions.append(PlacedDimension(id: id, text: text, segments: [(rim, knee0), (knee0, knee0 + Vec2(shelf, 0))],
                                                   textCenter: knee0 + Vec2(shelf / 2, 2.5), normal: Vec2(0, 1), along: Vec2(1, 0), isCustom: false))
        }
    }

    static let textHeight = 3.5

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

    private func addFrameAndTitle(_ page: inout DrawingPage, _ input: Input) {
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
        let title = s.title.isEmpty ? input.fallbackTitle : s.title
        page.texts.append(DrawingText(text: "Benennung", position: Vec2(x0 + 1.5, y0 + th - 3.4), height: 1.8, anchor: .left))
        page.texts.append(DrawingText(text: title, position: Vec2(x0 + 3, r2 + 4.5), height: 5, anchor: .left, bold: true))
        field("Zeichnungsnummer", s.drawingNumber, at: Vec2(x0, r1))
        field("Material", s.material, at: Vec2(c1, r1))
        field("Datum", df.string(from: input.date), at: Vec2(c2, r1))
        field("Erstellt von", s.author, at: Vec2(x0, y0))
        field("Software", "6axis", at: Vec2(c1, y0))
        field("Einheit", "mm", at: Vec2(c2, y0))
        field("Maßstab", page.scale.label, at: Vec2(split, r2), rowHeight: th - 20, size: 5, bold: true)
        field("Blatt", "1 / 1", at: Vec2(split, r1))
        page.texts.append(DrawingText(text: page.sheet.name, position: Vec2(fx1 - 2, r1 + 1.8), height: 3.5, anchor: .right))
        page.texts.append(DrawingText(text: "Projektionsmethode 1", position: Vec2(split + 1.5, y0 + 6.8), height: 1.8, anchor: .left))
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
