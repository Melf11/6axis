import Foundation
import simd

extension SketchEdit {
    // MARK: - Curve parametrisation

    /// Parameter of a point on a curve: lines 0…1 from start to end, arcs/circles the angle in radians
    /// counter-clockwise from the start (circles: from the +x axis).
    static func parameter(_ sk: Sketch, _ c: SketchCurve, _ p: Vec2) -> Double? {
        switch c.geometry {
        case let .line(a, b):
            guard let pa = sk.point(a), let pb = sk.point(b) else { return nil }
            let d = pb - pa
            return simd_dot(p - pa, d) / max(simd_length_squared(d), 1e-18)
        case let .arc(ci, s, _):
            guard let pc = sk.point(ci), let ps = sk.point(s) else { return nil }
            return normalizedAngle(atan2(p.y - pc.y, p.x - pc.x) - atan2(ps.y - pc.y, ps.x - pc.x))
        case let .circle(ci, _):
            guard let pc = sk.point(ci) else { return nil }
            return normalizedAngle(atan2(p.y - pc.y, p.x - pc.x))
        case .spline:
            return nil
        }
    }

    /// Parameter range of a curve (arcs: 0…sweep).
    static func range(_ sk: Sketch, _ c: SketchCurve) -> ClosedRange<Double>? {
        switch c.geometry {
        case .line: return 0...1
        case let .arc(ci, s, e):
            guard let pc = sk.point(ci), let ps = sk.point(s), let pe = sk.point(e) else { return nil }
            var sweep = normalizedAngle(atan2(pe.y - pc.y, pe.x - pc.x) - atan2(ps.y - pc.y, ps.x - pc.x))
            if sweep < 1e-12 { sweep = 2 * .pi }
            return 0...sweep
        case .circle: return 0...(2 * .pi)
        case .spline: return nil
        }
    }

    // MARK: - Intersections

    /// Intersection points of two curves (splines via their polyline).
    static func intersections(_ sk: Sketch, _ c1: SketchCurve, _ c2: SketchCurve) -> [Vec2] {
        // Represent each curve as a list of primitive pieces: segments or circles (with arc filter).
        enum Prim { case seg(Vec2, Vec2), circ(Vec2, Double) }
        func prims(_ c: SketchCurve) -> [Prim] {
            switch c.geometry {
            case let .line(a, b):
                guard let pa = sk.point(a), let pb = sk.point(b) else { return [] }
                return [.seg(pa, pb)]
            case .arc, .circle:
                guard let pc = sk.center(of: c) else { return [] }
                return [.circ(pc, sk.radius(of: c))]
            case .spline:
                let poly = sk.polyline(c, segments: 160)
                return zip(poly, poly.dropFirst()).map { .seg($0, $1) }
            }
        }
        func onCurve(_ c: SketchCurve, _ p: Vec2) -> Bool {
            guard case .arc = c.geometry, let t = parameter(sk, c, p), let r = range(sk, c) else { return true }
            return t <= r.upperBound + 1e-9 || t >= 2 * .pi - 1e-9
        }
        var out: [Vec2] = []
        for a in prims(c1) {
            for b in prims(c2) {
                switch (a, b) {
                case let (.seg(p, q), .seg(r, s)): if let x = segSeg(p, q, r, s) { out.append(x) }
                case let (.seg(p, q), .circ(c, rad)), let (.circ(c, rad), .seg(p, q)): out += segCircle(p, q, c, rad)
                case let (.circ(c, r1), .circ(d, r2)): out += circleCircle(c, r1, d, r2)
                }
            }
        }
        out = out.filter { onCurve(c1, $0) && onCurve(c2, $0) }
        // De-duplicate (polyline pieces meet at shared vertices).
        var unique: [Vec2] = []
        for p in out where !unique.contains(where: { simd_distance($0, p) < 1e-7 }) { unique.append(p) }
        return unique
    }

    static func segSeg(_ p: Vec2, _ q: Vec2, _ r: Vec2, _ s: Vec2) -> Vec2? {
        let d1 = q - p, d2 = s - r
        let den = d1.x * d2.y - d1.y * d2.x
        guard abs(den) > 1e-12 else { return nil }
        let t = ((r.x - p.x) * d2.y - (r.y - p.y) * d2.x) / den
        let u = ((r.x - p.x) * d1.y - (r.y - p.y) * d1.x) / den
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return p + t * d1
    }

    static func segCircle(_ p: Vec2, _ q: Vec2, _ c: Vec2, _ r: Double) -> [Vec2] {
        let d = q - p, f = p - c
        let a = simd_dot(d, d), b = 2 * simd_dot(f, d), cc = simd_dot(f, f) - r * r
        let disc = b * b - 4 * a * cc
        guard a > 1e-18, disc >= -1e-12 else { return [] }
        let sq = sqrt(max(0, disc))
        return [(-b - sq) / (2 * a), (-b + sq) / (2 * a)].filter { $0 >= -1e-9 && $0 <= 1 + 1e-9 }.map { p + $0 * d }
    }

    static func circleCircle(_ c1: Vec2, _ r1: Double, _ c2: Vec2, _ r2: Double) -> [Vec2] {
        let d = simd_distance(c1, c2)
        guard d > 1e-12, d <= r1 + r2 + 1e-9, d >= abs(r1 - r2) - 1e-9 else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = sqrt(max(0, r1 * r1 - a * a))
        let m = c1 + a * (c2 - c1) / d
        let n = Vec2(-(c2.y - c1.y), c2.x - c1.x) / d
        return h < 1e-9 ? [m] : [m + h * n, m - h * n]
    }

    // MARK: - Trim

    public enum TrimResult: Equatable { case deleted, shortened, split, opened }

    /// Removes the part of `curveId` around `click` up to the nearest intersections with other curves
    /// (or its ends). New endpoints stay attached to the cutting curves.
    @discardableResult
    public static func trim(_ sk: inout Sketch, curve curveId: Int, at click: Vec2) -> TrimResult? {
        guard let c = sk.curve(curveId), let span = range(sk, c), let tc = parameter(sk, c, click) else { return nil }
        // Cut parameters with the curve that makes each cut (for attaching the new endpoint).
        var cuts: [(t: Double, p: Vec2, by: Int)] = []
        for other in sk.curves where other.id != curveId && !other.construction {
            for x in intersections(sk, c, other) {
                guard let t = parameter(sk, c, x) else { continue }
                cuts.append((t, x, other.id))
            }
        }
        let isCircle: Bool = { if case .circle = c.geometry { return true }; return false }()
        if isCircle {
            // A circle needs two cuts; remove the piece between the neighbours of the click.
            let sorted = cuts.sorted { $0.t < $1.t }
            guard sorted.count >= 2 else { return nil }
            let after = sorted.first { $0.t > tc } ?? sorted[0]
            let before = sorted.last { $0.t < tc } ?? sorted[sorted.count - 1]
            guard case let .circle(ci, rad) = c.geometry, let i = sk.curveIndex(curveId) else { return nil }
            let s = attachedPoint(&sk, after.p, by: after.by), e = attachedPoint(&sk, before.p, by: before.by)
            // Keep the arc from "after" counter-clockwise to "before" (the clicked piece is outside it).
            sk.curves[i].geometry = .arc(center: ci, start: s, end: e)
            for k in sk.constraints.indices {
                if case let .diameter(cid, v) = sk.constraints[k].kind, cid == curveId {
                    sk.constraints[k].kind = .radius(curve: curveId, value: "(\(v)) / 2")
                }
            }
            _ = rad
            return .opened
        }
        let inner = cuts.filter { $0.t > span.lowerBound + 1e-9 && $0.t < span.upperBound - 1e-9 }
        let lo = inner.filter { $0.t < tc }.max { $0.t < $1.t }
        let hi = inner.filter { $0.t > tc }.min { $0.t < $1.t }
        guard let i = sk.curveIndex(curveId) else { return nil }
        switch (lo, hi) {
        case (nil, nil):
            sk.delete(curveIds: [curveId])
            return .deleted
        case let (lo?, nil):
            moveEnd(&sk, i, end: true, to: attachedPoint(&sk, lo.p, by: lo.by))
            dropLengthDimensions(&sk, curveId)
            return .shortened
        case let (nil, hi?):
            moveEnd(&sk, i, end: false, to: attachedPoint(&sk, hi.p, by: hi.by))
            dropLengthDimensions(&sk, curveId)
            return .shortened
        case let (lo?, hi?):
            // Split: original keeps start…lo, a copy gets hi…end.
            let g = sk.curves[i].geometry
            let pLo = attachedPoint(&sk, lo.p, by: lo.by), pHi = attachedPoint(&sk, hi.p, by: hi.by)
            let newId: Int
            switch g {
            case let .line(_, b): newId = sk.addLine(pHi, b, construction: c.construction)
            case let .arc(ci, _, e): newId = sk.addArc(center: ci, start: pHi, end: e, construction: c.construction)
            default: return nil
            }
            moveEnd(&sk, sk.curveIndex(curveId)!, end: true, to: pLo)
            // Orientation constraints carry over to the new piece.
            for con in sk.constraints {
                switch con.kind {
                case .horizontal(let l) where l == curveId: sk.addConstraint(.horizontal(line: newId))
                case .vertical(let l) where l == curveId: sk.addConstraint(.vertical(line: newId))
                default: break
                }
            }
            if case .line = g { sk.addConstraint(.collinear(curveId, newId)) }
            if case .arc = g { sk.addConstraint(.concentric(curveId, newId)) }
            dropLengthDimensions(&sk, curveId)
            return .split
        }
    }

    /// Point at `p` attached to curve `by`: an existing endpoint/point there is reused, else a new point with
    /// a point-on-curve constraint.
    static func attachedPoint(_ sk: inout Sketch, _ p: Vec2, by: Int) -> Int {
        if let existing = sk.points.first(where: { simd_distance($0.position, p) < 1e-6 }) { return existing.id }
        let id = sk.addPoint(p)
        sk.addConstraint(.pointOnCurve(point: id, curve: by))
        return id
    }

    static func moveEnd(_ sk: inout Sketch, _ i: Int, end: Bool, to p: Int) {
        switch sk.curves[i].geometry {
        case let .line(a, b): sk.curves[i].geometry = end ? .line(start: a, end: p) : .line(start: p, end: b)
        case let .arc(c, s, e): sk.curves[i].geometry = end ? .arc(center: c, start: s, end: p) : .arc(center: c, start: p, end: e)
        default: break
        }
        // Points no curve uses anymore disappear (with their constraints).
        sk.delete(curveIds: [])
    }

    /// A length dimension of a trimmed curve would now drive the wrong length – remove it.
    static func dropLengthDimensions(_ sk: inout Sketch, _ curveId: Int) {
        sk.constraints.removeAll { if case let .length(l, _) = $0.kind { return l == curveId }; return false }
    }

    // MARK: - Extend

    /// Extends the line end nearest to `click` to the closest intersection of its ray with another curve.
    @discardableResult
    public static func extend(_ sk: inout Sketch, line lineId: Int, near click: Vec2) -> Bool {
        guard let c = sk.curve(lineId), case let .line(a, b) = c.geometry, let pa = sk.point(a), let pb = sk.point(b) else { return false }
        let atEnd = simd_distance(click, pb) <= simd_distance(click, pa)
        let from = atEnd ? pb : pa, dir = simd_normalize(atEnd ? pb - pa : pa - pb)
        let far = from + dir * 1e6
        var best: (Double, Vec2, Int)?
        for other in sk.curves where other.id != lineId && !other.construction {
            var probe = sk
            let tmpA = probe.addPoint(from + dir * 1e-7), tmpB = probe.addPoint(far)
            let ray = SketchCurve(id: -1, geometry: .line(start: tmpA, end: tmpB))
            for x in intersections(probe, ray, other) {
                let d = simd_dot(x - from, dir)
                if d > 1e-7, best == nil || d < best!.0 { best = (d, x, other.id) }
            }
        }
        guard let (_, x, by) = best, let i = sk.curveIndex(lineId) else { return false }
        let p = attachedPoint(&sk, x, by: by)
        moveEnd(&sk, i, end: atEnd, to: p)
        dropLengthDimensions(&sk, lineId)
        return true
    }

    // MARK: - Preview

    /// Polyline of the piece `trim` would remove (for highlighting under the cursor).
    public static func trimPreview(_ sk: Sketch, curve curveId: Int, at click: Vec2) -> [Vec2]? {
        guard let c = sk.curve(curveId), let span = range(sk, c), let tc = parameter(sk, c, click) else { return nil }
        var ts: [Double] = []
        for other in sk.curves where other.id != curveId && !other.construction {
            for x in intersections(sk, c, other) { if let t = parameter(sk, c, x) { ts.append(t) } }
        }
        var lo = span.lowerBound, hi = span.upperBound
        if case .circle = c.geometry {
            let sorted = ts.sorted()
            guard sorted.count >= 2 else { return nil }
            lo = sorted.last { $0 < tc } ?? sorted[sorted.count - 1] - 2 * .pi
            hi = sorted.first { $0 > tc } ?? sorted[0] + 2 * .pi
        } else {
            let inner = ts.filter { $0 > span.lowerBound + 1e-9 && $0 < span.upperBound - 1e-9 }
            lo = inner.filter { $0 < tc }.max() ?? lo
            hi = inner.filter { $0 > tc }.min() ?? hi
        }
        let n = 32
        return (0...n).compactMap { i in point(sk, c, lo + (hi - lo) * Double(i) / Double(n)) }
    }

    /// Point at parameter `t` (see `parameter`).
    static func point(_ sk: Sketch, _ c: SketchCurve, _ t: Double) -> Vec2? {
        switch c.geometry {
        case let .line(a, b):
            guard let pa = sk.point(a), let pb = sk.point(b) else { return nil }
            return pa + t * (pb - pa)
        case let .arc(ci, s, _):
            guard let pc = sk.point(ci), let ps = sk.point(s) else { return nil }
            let a0 = atan2(ps.y - pc.y, ps.x - pc.x), r = simd_distance(pc, ps)
            return pc + r * Vec2(cos(a0 + t), sin(a0 + t))
        case let .circle(ci, r):
            guard let pc = sk.point(ci) else { return nil }
            return pc + r * Vec2(cos(t), sin(t))
        case .spline:
            return nil
        }
    }
}

