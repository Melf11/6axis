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
        var frontX = Self.baseline(front.xs + front.holes.map { Feature(position: $0.center.x, low: $0.center.y - $0.radius, high: $0.center.y + $0.radius, isHole: true) },
                                   from: front.minP.x)
        var frontZ = Self.baseline(front.ys + front.holes.map { Feature(position: $0.center.y, low: $0.center.x - $0.radius, high: $0.center.x + $0.radius, isHole: true) },
                                   from: front.minP.y)
        var sideY = Self.baseline(side.xs + side.holes.map { Feature(position: $0.center.x, low: $0.center.y - $0.radius, high: $0.center.y + $0.radius, isHole: true) },
                                  from: side.minP.x)
        // Heights are dimensioned in the front view; the side view only adds heights of side holes.
        let frontZValues = Set(frontZ.map { Int(($0.position - front.minP.y).rounded()) })
        let sideZ = Self.baseline(side.holes.map { Feature(position: $0.center.y, low: $0.center.x - $0.radius, high: $0.center.x + $0.radius, isHole: true) },
                                  from: side.minP.y).filter { !frontZValues.contains(Int(($0.position - side.minP.y).rounded())) }
        // Top view: only hole positions, X values not already given in the front view.
        let frontXValues = Set(frontX.map { Int(($0.position - front.minP.x).rounded()) })
        let topX = Self.baseline(top.holes.map { Feature(position: $0.center.x, low: $0.center.y - $0.radius, high: $0.center.y + $0.radius, isHole: true) },
                                 from: top.minP.x).filter { !frontXValues.contains(Int(($0.position - top.minP.x).rounded())) }
        let topY = Self.baseline(top.holes.map { Feature(position: $0.center.y, low: $0.center.x - $0.radius, high: $0.center.x + $0.radius, isHole: true) },
                                 from: top.minP.y)
        if !settings.showDimensions { frontX = []; frontZ = []; sideY = [] }
        let dims = settings.showDimensions
        let rows = (frontBelow: max(frontX.count, sideY.count), frontLeft: frontZ.count,
                    sideRight: dims ? sideZ.count : 0, topBelow: dims ? topX.count : 0, topLeft: dims ? topY.count : 0)

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
        let s = scale.factor
        let L = layoutSize(s)
        let area = Self.drawingArea(sheet)
        let originX = area.origin.x + (area.size.x - L.w) / 2 + L.left
        let frontTop = area.origin.y + area.size.y - (area.size.y - L.h) / 2 - 2
        let frontOrigin = Vec2(originX, frontTop - front.size.y * s)
        let sideOrigin = Vec2(frontOrigin.x + front.size.x * s + L.gapH, frontOrigin.y)
        let topOrigin = Vec2(frontOrigin.x, frontOrigin.y - L.gapV - top.size.y * s)

        func mapper(_ v: ViewData, _ origin: Vec2) -> (Vec2) -> Vec2 {
            { p in origin + (p - v.minP) * s }
        }
        let mf = mapper(front, frontOrigin), ms = mapper(side, sideOrigin), mt = mapper(top, topOrigin)

        addView(&page, front, mf, showHidden: settings.showHidden)
        addView(&page, side, ms, showHidden: settings.showHidden)
        addView(&page, top, mt, showHidden: settings.showHidden)

        if dims {
            // Front: X from the left edge (below), Z from the bottom edge (left).
            horizontalBaseline(&page, frontX, base: front.minP.x, map: mf, view: front, below: true, s: s)
            verticalBaseline(&page, frontZ, base: front.minP.y, map: mf, view: front, leftSide: true, s: s)
            horizontalBaseline(&page, sideY, base: side.minP.x, map: ms, view: side, below: true, s: s)
            verticalBaseline(&page, sideZ, base: side.minP.y, map: ms, view: side, leftSide: false, s: s)
            horizontalBaseline(&page, topX, base: top.minP.x, map: mt, view: top, below: true, s: s)
            verticalBaseline(&page, topY, base: top.minP.y, map: mt, view: top, leftSide: true, s: s)
            for (v, m) in [(front, mf), (side, ms), (top, mt)] { addHoleLabels(&page, v, map: m, s: s) }
        }
        for (v, m) in [(front, mf), (side, ms), (top, mt)] { addCenterLines(&page, v, map: m, s: s) }

        // Pictorial view in the free quadrant (right of the top view, above the title block).
        if settings.showIso, let iso = projection(shapes, .iso).flatMap(Self.analyze) {
            let regionMin = Vec2(sideOrigin.x, area.origin.y + 2)
            let regionMax = Vec2(area.origin.x + area.size.x - 4, sideOrigin.y - band(rows.frontBelow) - 2)
            let region = regionMax - regionMin
            if region.x > 35 && region.y > 30 {
                let fit = min(region.x / max(iso.size.x, 1e-6), region.y / max(iso.size.y, 1e-6)) * 0.9
                let k = min(fit, s)
                let center = (regionMin + regionMax) / 2
                let origin = center - iso.size * k / 2
                for line in iso.projection.polylines where !line.hidden && !line.smooth {
                    page.lines.append(DrawingLine(points: line.points.map { origin + ($0 - iso.minP) * k }, style: .iso))
                }
            }
        }
        return page
    }

    // MARK: - Geometry output

    private func addView(_ page: inout DrawingPage, _ v: ViewData, _ map: (Vec2) -> Vec2, showHidden: Bool) {
        for line in v.projection.polylines where !line.smooth {
            if line.hidden && !showHidden { continue }
            page.lines.append(DrawingLine(points: line.points.map(map), style: line.hidden ? .hidden : .visible))
        }
    }

    private func addCenterLines(_ page: inout DrawingPage, _ v: ViewData, map: (Vec2) -> Vec2, s: Double) {
        for h in v.holes {
            let c = map(h.center)
            let r = h.radius * s + 2.5
            page.lines.append(DrawingLine(points: [c - Vec2(r, 0), c + Vec2(r, 0)], style: .center))
            page.lines.append(DrawingLine(points: [c - Vec2(0, r), c + Vec2(0, r)], style: .center))
        }
    }

    /// Ø callouts: one leader per distinct diameter, "n× Ø8" for repeated holes.
    private func addHoleLabels(_ page: inout DrawingPage, _ v: ViewData, map: (Vec2) -> Vec2, s: Double) {
        let groups = Dictionary(grouping: v.holes) { Int((2 * $0.radius).rounded()) }
        for (d, holes) in groups.sorted(by: { $0.key < $1.key }) {
            guard let h = holes.max(by: { $0.center.x + $0.center.y < $1.center.x + $1.center.y }) else { continue }
            let c = map(h.center)
            let u = simd_normalize(Vec2(1, 1))
            let rim = c + u * h.radius * s
            let knee = rim + u * 7
            let text = (holes.count > 1 ? "\(holes.count)× " : "") + "Ø\(d)"
            let shelf = Double(text.count) * 2.2 + 2
            page.lines.append(DrawingLine(points: [rim, knee, knee + Vec2(shelf, 0)], style: .thin))
            page.arrows.append(DrawingArrow(tip: rim, direction: -u))
            page.texts.append(DrawingText(text: text, position: knee + Vec2(1, 1), height: 3.5, anchor: .left))
        }
    }

    static let textHeight = 3.5

    private func horizontalBaseline(_ page: inout DrawingPage, _ features: [Feature], base: Double,
                                    map: (Vec2) -> Vec2, view: ViewData, below: Bool, s: Double) {
        let x0 = map(Vec2(base, view.minP.y)).x
        let edgeY = map(view.minP).y
        for (i, f) in features.enumerated() {
            let lineY = edgeY - 10 - 7 * Double(i)
            let x1 = map(Vec2(f.position, 0)).x
            let featureLow = map(Vec2(0, f.low)).y
            page.lines.append(DrawingLine(points: [Vec2(x1, featureLow - 1.5), Vec2(x1, lineY - 2)], style: .thin))
            dimensionLine(&page, from: Vec2(x0, lineY), to: Vec2(x1, lineY), value: abs(f.position - base))
        }
        // One extension line at the reference edge, reaching the outermost dimension line.
        if !features.isEmpty {
            let lowest = edgeY - 10 - 7 * Double(features.count - 1)
            page.lines.append(DrawingLine(points: [Vec2(x0, edgeY - 1.5), Vec2(x0, lowest - 2)], style: .thin))
        }
    }

    private func verticalBaseline(_ page: inout DrawingPage, _ features: [Feature], base: Double,
                                  map: (Vec2) -> Vec2, view: ViewData, leftSide: Bool, s: Double) {
        let y0 = map(Vec2(view.minP.x, base)).y
        let edgeX = leftSide ? map(view.minP).x : map(view.maxP).x
        let sign: Double = leftSide ? -1 : 1
        for (i, f) in features.enumerated() {
            let lineX = edgeX + sign * (10 + 7 * Double(i))
            let y1 = map(Vec2(0, f.position)).y
            let featureEdge = leftSide ? map(Vec2(f.low, 0)).x : map(Vec2(f.high, 0)).x
            page.lines.append(DrawingLine(points: [Vec2(featureEdge + sign * 1.5, y1), Vec2(lineX + sign * 2, y1)], style: .thin))
            dimensionLine(&page, from: Vec2(lineX, y0), to: Vec2(lineX, y1), value: abs(f.position - base))
        }
        if !features.isEmpty {
            let outer = edgeX + sign * (10 + 7 * Double(features.count - 1))
            page.lines.append(DrawingLine(points: [Vec2(edgeX + sign * 1.5, y0), Vec2(outer + sign * 2, y0)], style: .thin))
        }
    }

    /// Dimension line with filled arrows and the value in whole millimetres (ISO 129-1).
    private func dimensionLine(_ page: inout DrawingPage, from a: Vec2, to b: Vec2, value: Double) {
        let text = "\(Int(value.rounded()))"
        let d = b - a
        let len = simd_length(d)
        guard len > 1e-6 else { return }
        let u = d / len
        let vertical = abs(u.y) > abs(u.x)
        let textWidth = Double(text.count) * Self.textHeight * 0.62
        let n = vertical ? Vec2(-1, 0) : Vec2(0, 1)   // text side: above / left
        let mid = (a + b) / 2
        if len >= textWidth + 8 {
            page.lines.append(DrawingLine(points: [a, b], style: .thin))
            page.arrows.append(DrawingArrow(tip: a, direction: -u))
            page.arrows.append(DrawingArrow(tip: b, direction: u))
            page.texts.append(DrawingText(text: text, position: mid + n * 1.0, height: Self.textHeight,
                                          angle: vertical ? .pi / 2 : 0, anchor: .center))
        } else {
            // Too short: arrows from outside, value placed beyond the end.
            page.lines.append(DrawingLine(points: [a - u * 5, b + u * (6 + textWidth)], style: .thin))
            page.arrows.append(DrawingArrow(tip: a, direction: u))
            page.arrows.append(DrawingArrow(tip: b, direction: -u))
            let pos = b + u * (4 + textWidth / 2) + n * 1.0
            page.texts.append(DrawingText(text: text, position: pos, height: Self.textHeight,
                                          angle: vertical ? .pi / 2 : 0, anchor: .center))
        }
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
