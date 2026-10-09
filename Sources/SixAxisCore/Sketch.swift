import Foundation
import simd

public struct SketchPoint: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var position: Vec2
    /// Fixed points are not moved by the solver (origin, "Fixieren" constraint).
    public var fixed: Bool

    public init(id: Int, position: Vec2, fixed: Bool = false) {
        self.id = id
        self.position = position
        self.fixed = fixed
    }
}

public enum CurveGeometry: Codable, Hashable, Sendable {
    case line(start: Int, end: Int)
    case circle(center: Int, radius: Double)
    /// Counter-clockwise from `start` to `end`. Radius is |start - center|.
    case arc(center: Int, start: Int, end: Int)
    /// Smooth curve through the given points (fit points), optionally closed.
    case spline(points: [Int], closed: Bool)

    public var pointIds: [Int] {
        switch self {
        case let .line(a, b): return [a, b]
        case let .circle(c, _): return [c]
        case let .arc(c, a, b): return [c, a, b]
        case let .spline(pts, _): return pts
        }
    }
}

public struct SketchCurve: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var geometry: CurveGeometry
    public var construction: Bool

    public init(id: Int, geometry: CurveGeometry, construction: Bool = false) {
        self.id = id
        self.geometry = geometry
        self.construction = construction
    }

    public var isLine: Bool { if case .line = geometry { return true } else { return false } }
    public var isSpline: Bool { if case .spline = geometry { return true } else { return false } }
    /// Circles and arcs.
    public var isRound: Bool { !isLine && !isSpline }
}

public enum ConstraintKind: Codable, Hashable, Sendable {
    // Geometric
    case coincident(Int, Int)                 // point, point
    case horizontal(line: Int)
    case vertical(line: Int)
    case horizontalPoints(Int, Int)
    case verticalPoints(Int, Int)
    case parallel(Int, Int)                   // line, line
    case perpendicular(Int, Int)              // line, line
    case equal(Int, Int)                      // line/line or round/round
    case tangent(Int, Int)                    // line/round or round/round
    case pointOnCurve(point: Int, curve: Int)
    case midpoint(point: Int, line: Int)
    case concentric(Int, Int)                 // round, round
    case collinear(Int, Int)                  // line, line
    case symmetric(Int, Int, line: Int)       // point, point, axis line
    // Dimensional (value is an expression)
    case distance(Int, Int, value: String)            // aligned point-point
    case horizontalDistance(Int, Int, value: String)
    case verticalDistance(Int, Int, value: String)
    case pointLineDistance(point: Int, line: Int, value: String)
    case length(line: Int, value: String)
    case radius(curve: Int, value: String)
    case diameter(curve: Int, value: String)
    case angle(Int, Int, value: String)               // line, line (degrees)

    public var isDimension: Bool { dimensionValue != nil }

    public var dimensionValue: String? {
        switch self {
        case let .distance(_, _, v), let .horizontalDistance(_, _, v), let .verticalDistance(_, _, v),
             let .pointLineDistance(_, _, v), let .length(_, v), let .radius(_, v), let .diameter(_, v),
             let .angle(_, _, v):
            return v
        default:
            return nil
        }
    }

    public var valueKind: ValueKind {
        if case .angle = self { return .angle }
        return .length
    }

    public func withValue(_ v: String) -> ConstraintKind {
        switch self {
        case let .distance(a, b, _): return .distance(a, b, value: v)
        case let .horizontalDistance(a, b, _): return .horizontalDistance(a, b, value: v)
        case let .verticalDistance(a, b, _): return .verticalDistance(a, b, value: v)
        case let .pointLineDistance(p, l, _): return .pointLineDistance(point: p, line: l, value: v)
        case let .length(l, _): return .length(line: l, value: v)
        case let .radius(c, _): return .radius(curve: c, value: v)
        case let .diameter(c, _): return .diameter(curve: c, value: v)
        case let .angle(a, b, _): return .angle(a, b, value: v)
        default: return self
        }
    }

    /// Point ids referenced directly.
    public var pointRefs: [Int] {
        switch self {
        case let .coincident(a, b), let .horizontalPoints(a, b), let .verticalPoints(a, b),
             let .distance(a, b, _), let .horizontalDistance(a, b, _), let .verticalDistance(a, b, _):
            return [a, b]
        case let .pointOnCurve(p, _), let .midpoint(p, _), let .pointLineDistance(p, _, _): return [p]
        case let .symmetric(a, b, _): return [a, b]
        default: return []
        }
    }

    /// Curve ids referenced directly.
    public var curveRefs: [Int] {
        switch self {
        case let .horizontal(l), let .vertical(l), let .length(l, _), let .radius(l, _), let .diameter(l, _):
            return [l]
        case let .parallel(a, b), let .perpendicular(a, b), let .equal(a, b), let .tangent(a, b),
             let .concentric(a, b), let .collinear(a, b), let .angle(a, b, _):
            return [a, b]
        case let .pointOnCurve(_, c), let .midpoint(_, c), let .pointLineDistance(_, c, _), let .symmetric(_, _, c):
            return [c]
        default: return []
        }
    }

    public var displayName: String {
        switch self {
        case .coincident: return String(localized: "Deckungsgleich")
        case .horizontal, .horizontalPoints: return String(localized: "Horizontal")
        case .vertical, .verticalPoints: return String(localized: "Vertikal")
        case .parallel: return String(localized: "Parallel")
        case .perpendicular: return String(localized: "Senkrecht")
        case .equal: return String(localized: "Gleich")
        case .tangent: return String(localized: "Tangential")
        case .pointOnCurve: return String(localized: "Punkt auf Kurve")
        case .midpoint: return String(localized: "Mittelpunkt")
        case .concentric: return String(localized: "Konzentrisch")
        case .collinear: return String(localized: "Kollinear")
        case .symmetric: return String(localized: "Symmetrisch")
        case .distance, .horizontalDistance, .verticalDistance, .pointLineDistance: return String(localized: "Abstand")
        case .length: return String(localized: "Länge")
        case .radius: return String(localized: "Radius")
        case .diameter: return String(localized: "Durchmesser")
        case .angle: return String(localized: "Winkel")
        }
    }
}

public struct SketchConstraint: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var kind: ConstraintKind
    /// Offset of the dimension label from its anchor, in sketch units.
    public var labelOffset: Vec2

    public init(id: Int, kind: ConstraintKind, labelOffset: Vec2 = .zero) {
        self.id = id
        self.kind = kind
        self.labelOffset = labelOffset
    }
}

/// A 2D sketch: points, curves referencing points, and constraints.
/// Point 0 is always the fixed sketch origin.
public struct Sketch: Codable, Hashable, Sendable {
    public var plane: PlaneRef
    public var points: [SketchPoint]
    public var curves: [SketchCurve]
    public var constraints: [SketchConstraint]
    public var nextId: Int

    public static let originId = 0

    public init(plane: PlaneRef) {
        self.plane = plane
        self.points = [SketchPoint(id: Self.originId, position: .zero, fixed: true)]
        self.curves = []
        self.constraints = []
        self.nextId = 1
    }

    public mutating func newId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    public func pointIndex(_ id: Int) -> Int? { points.firstIndex { $0.id == id } }
    public func curveIndex(_ id: Int) -> Int? { curves.firstIndex { $0.id == id } }

    public func point(_ id: Int) -> Vec2? { points.first { $0.id == id }?.position }
    public func curve(_ id: Int) -> SketchCurve? { curves.first { $0.id == id } }

    public mutating func setPoint(_ id: Int, _ p: Vec2) {
        if let i = pointIndex(id) { points[i].position = p }
    }

    @discardableResult
    public mutating func addPoint(_ p: Vec2) -> Int {
        let id = newId()
        points.append(SketchPoint(id: id, position: p))
        return id
    }

    @discardableResult
    public mutating func addLine(_ a: Int, _ b: Int, construction: Bool = false) -> Int {
        let id = newId()
        curves.append(SketchCurve(id: id, geometry: .line(start: a, end: b), construction: construction))
        return id
    }

    @discardableResult
    public mutating func addCircle(center: Int, radius: Double, construction: Bool = false) -> Int {
        let id = newId()
        curves.append(SketchCurve(id: id, geometry: .circle(center: center, radius: radius), construction: construction))
        return id
    }

    @discardableResult
    public mutating func addArc(center: Int, start: Int, end: Int, construction: Bool = false) -> Int {
        let id = newId()
        curves.append(SketchCurve(id: id, geometry: .arc(center: center, start: start, end: end), construction: construction))
        return id
    }

    @discardableResult
    public mutating func addSpline(_ points: [Int], closed: Bool = false, construction: Bool = false) -> Int {
        let id = newId()
        curves.append(SketchCurve(id: id, geometry: .spline(points: points, closed: closed), construction: construction))
        return id
    }

    @discardableResult
    public mutating func addConstraint(_ kind: ConstraintKind, labelOffset: Vec2 = .zero) -> Int {
        let id = newId()
        constraints.append(SketchConstraint(id: id, kind: kind, labelOffset: labelOffset))
        return id
    }

    public func radius(of curve: SketchCurve) -> Double {
        switch curve.geometry {
        case let .circle(_, r): return r
        case let .arc(c, s, _): return simd_distance(point(c) ?? .zero, point(s) ?? .zero)
        case .line, .spline: return 0
        }
    }

    public func center(of curve: SketchCurve) -> Vec2? {
        switch curve.geometry {
        case let .circle(c, _), let .arc(c, _, _): return point(c)
        case let .line(a, b): return ((point(a) ?? .zero) + (point(b) ?? .zero)) / 2
        case let .spline(pts, _):
            let ps = pts.compactMap { point($0) }
            return ps.isEmpty ? nil : ps.reduce(.zero, +) / Double(ps.count)
        }
    }

    /// Curves that touch a point (as endpoint/center).
    public func curves(using pointId: Int) -> [SketchCurve] {
        curves.filter { $0.geometry.pointIds.contains(pointId) }
    }

    /// Removes curves and constraints, then any orphan points (except the origin).
    public mutating func delete(curveIds: Set<Int>, pointIds: Set<Int> = [], constraintIds: Set<Int> = []) {
        let deadPoints = pointIds.subtracting([Self.originId])
        curves.removeAll { curveIds.contains($0.id) || !Set($0.geometry.pointIds).isDisjoint(with: deadPoints) }
        // Points only exist as curve endpoints/centers; drop the ones no curve uses anymore.
        let used = Set(curves.flatMap { $0.geometry.pointIds })
        points.removeAll { $0.id != Self.originId && !used.contains($0.id) }
        let curveSet = Set(curves.map(\.id)), pointSet = Set(points.map(\.id))
        constraints.removeAll { c in
            constraintIds.contains(c.id)
                || !Set(c.kind.curveRefs).isSubset(of: curveSet)
                || !Set(c.kind.pointRefs).isSubset(of: pointSet)
        }
    }

    /// Merges point `b` into point `a` (used for snapping/coincidence). References are rewritten.
    public mutating func merge(point b: Int, into a: Int) {
        guard a != b else { return }
        func r(_ id: Int) -> Int { id == b ? a : id }
        for i in curves.indices {
            switch curves[i].geometry {
            case let .line(s, e): curves[i].geometry = .line(start: r(s), end: r(e))
            case let .circle(c, rad): curves[i].geometry = .circle(center: r(c), radius: rad)
            case let .arc(c, s, e): curves[i].geometry = .arc(center: r(c), start: r(s), end: r(e))
            case let .spline(pts, closed):
                var ids = pts.map(r)
                // Merging the last fit point into the first closes the spline.
                var isClosed = closed
                if ids.count > 2, ids.first == ids.last { ids.removeLast(); isClosed = true }
                curves[i].geometry = .spline(points: ids, closed: isClosed)
            }
        }
        for i in constraints.indices {
            let k = constraints[i].kind
            let nk: ConstraintKind
            switch k {
            case let .coincident(x, y): nk = .coincident(r(x), r(y))
            case let .horizontalPoints(x, y): nk = .horizontalPoints(r(x), r(y))
            case let .verticalPoints(x, y): nk = .verticalPoints(r(x), r(y))
            case let .distance(x, y, v): nk = .distance(r(x), r(y), value: v)
            case let .horizontalDistance(x, y, v): nk = .horizontalDistance(r(x), r(y), value: v)
            case let .verticalDistance(x, y, v): nk = .verticalDistance(r(x), r(y), value: v)
            case let .pointOnCurve(p, c): nk = .pointOnCurve(point: r(p), curve: c)
            case let .midpoint(p, l): nk = .midpoint(point: r(p), line: l)
            case let .pointLineDistance(p, l, v): nk = .pointLineDistance(point: r(p), line: l, value: v)
            case let .symmetric(x, y, l): nk = .symmetric(r(x), r(y), line: l)
            default: nk = k
            }
            constraints[i].kind = nk
        }
        if let bi = pointIndex(b), let ai = pointIndex(a), points[bi].fixed { points[ai].fixed = true }
        points.removeAll { $0.id == b }
        // Drop constraints that became trivial (e.g. coincident(a, a)) and lines collapsed to a point.
        constraints.removeAll { c in
            if case let .coincident(x, y) = c.kind { return x == y }
            return false
        }
        curves.removeAll { c in
            if case let .line(s, e) = c.geometry { return s == e }
            if case let .spline(pts, _) = c.geometry { return Set(pts).count < 2 }
            return false
        }
    }

    /// Segments for profile detection (construction geometry excluded).
    public func segments() -> [Segment2D] {
        curves.compactMap { c -> Segment2D? in
            guard !c.construction else { return nil }
            switch c.geometry {
            case let .line(a, b):
                guard let pa = point(a), let pb = point(b) else { return nil }
                return .line(pa, pb)
            case let .circle(ci, r):
                guard let pc = point(ci) else { return nil }
                return .circle(center: pc, radius: r)
            case let .arc(ci, s, e):
                guard let pc = point(ci), let ps = point(s), let pe = point(e) else { return nil }
                return .arc(center: pc, radius: simd_distance(pc, ps), start: ps, end: pe)
            case .spline:
                return nil   // expanded below
            }
        } + curves.filter { !$0.construction && $0.isSpline }.flatMap { c -> [Segment2D] in
            guard case let .spline(ids, closed) = c.geometry else { return [] }
            return Spline.beziers(ids.compactMap { point($0) }, closed: closed).map { .bezier($0.0, $0.1, $0.2, $0.3) }
        }
    }

    /// Polyline approximation of a curve in sketch coordinates (for drawing/picking).
    public func polyline(_ curve: SketchCurve, segments n: Int = 64) -> [Vec2] {
        switch curve.geometry {
        case let .line(a, b):
            return [point(a) ?? .zero, point(b) ?? .zero]
        case let .circle(c, r):
            let pc = point(c) ?? .zero
            return (0...n).map { i in
                let t = Double(i) / Double(n) * 2 * .pi
                return pc + r * Vec2(cos(t), sin(t))
            }
        case let .spline(ids, closed):
            return Spline.polyline(ids.compactMap { point($0) }, closed: closed, perSegment: max(8, n / 4))
        case let .arc(c, s, e):
            let pc = point(c) ?? .zero, ps = point(s) ?? .zero, pe = point(e) ?? .zero
            let r = simd_distance(pc, ps)
            let a0 = atan2(ps.y - pc.y, ps.x - pc.x)
            var sweep = normalizedAngle(atan2(pe.y - pc.y, pe.x - pc.x) - a0)
            if sweep < 1e-9 { sweep = 2 * .pi }
            let steps = max(4, Int(Double(n) * sweep / (2 * .pi)))
            return (0...steps).map { i in
                let t = a0 + sweep * Double(i) / Double(steps)
                return pc + r * Vec2(cos(t), sin(t))
            }
        }
    }
}

/// Interpolating spline through fit points: piecewise cubic Bézier with tangents from neighbouring chords
/// (Catmull-Rom style, scaled by chord length so uneven spacing doesn't overshoot). The same pieces are
/// drawn on screen and handed to OpenCASCADE, so display and solid always agree.
public enum Spline {
    public typealias Piece = (Vec2, Vec2, Vec2, Vec2)

    public static func beziers(_ pts: [Vec2], closed: Bool) -> [Piece] {
        let n = pts.count
        guard n >= 2 else { return [] }
        if n == 2 && !closed {
            let d = (pts[1] - pts[0]) / 3
            return [(pts[0], pts[0] + d, pts[1] - d, pts[1])]
        }
        func unit(_ v: Vec2) -> Vec2 { let l = simd_length(v); return l > 1e-12 ? v / l : .zero }
        func at(_ i: Int) -> Vec2 { pts[(i % n + n) % n] }
        // Unit tangent at each fit point.
        let tangents: [Vec2] = (0..<n).map { i in
            if !closed && i == 0 { return unit(pts[1] - pts[0]) }
            if !closed && i == n - 1 { return unit(pts[n - 1] - pts[n - 2]) }
            let t = unit(at(i + 1) - at(i)) + unit(at(i) - at(i - 1))
            let l = simd_length(t)
            return l > 1e-12 ? t / l : unit(at(i + 1) - at(i - 1))
        }
        let count = closed ? n : n - 1
        return (0..<count).map { i in
            let a = at(i), b = at(i + 1)
            let h = simd_distance(a, b) / 3
            return (a, a + tangents[i] * h, b - tangents[(i + 1) % n] * h, b)
        }
    }

    public static func point(_ p: Piece, _ t: Double) -> Vec2 {
        let u = 1 - t
        return u * u * u * p.0 + 3 * u * u * t * p.1 + 3 * u * t * t * p.2 + t * t * t * p.3
    }

    public static func polyline(_ pts: [Vec2], closed: Bool, perSegment k: Int = 24) -> [Vec2] {
        let pieces = beziers(pts, closed: closed)
        guard let first = pieces.first else { return pts }
        var out = [first.0]
        for p in pieces { for j in 1...k { out.append(point(p, Double(j) / Double(k))) } }
        return out
    }
}
