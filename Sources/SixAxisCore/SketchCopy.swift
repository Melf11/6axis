import Foundation
import simd

extension SketchEdit {
    // MARK: - Chains

    /// The curves connected to `start` through shared endpoints, in order, with their traversal direction
    /// (`reversed`: walked from end to start). Circles form a closed chain of their own.
    public static func chain(_ sk: Sketch, from start: Int) -> (curves: [(id: Int, reversed: Bool)], closed: Bool) {
        func ends(_ c: SketchCurve) -> (Int, Int)? {
            switch c.geometry {
            case let .line(a, b): return (a, b)
            case let .arc(_, s, e): return (s, e)
            case let .spline(pts, false): return pts.count >= 2 ? (pts[0], pts[pts.count - 1]) : nil
            default: return nil
            }
        }
        guard let first = sk.curve(start) else { return ([], false) }
        guard let (a0, b0) = ends(first) else { return ([(start, false)], true) }
        let candidates = sk.curves.filter { !$0.construction && ends($0) != nil }
        func next(at p: Int, excluding used: Set<Int>) -> (Int, Bool)? {
            let touching = candidates.filter { !used.contains($0.id) && (ends($0)!.0 == p || ends($0)!.1 == p) }
            guard touching.count == 1, let c = touching.first else { return nil }   // stop at branches
            return (c.id, ends(c)!.1 == p)
        }
        var forward: [(Int, Bool)] = [(start, false)]
        var used: Set<Int> = [start]
        var tip = b0
        while let (id, rev) = next(at: tip, excluding: used) {
            forward.append((id, rev)); used.insert(id)
            let e = ends(sk.curve(id)!)!
            tip = rev ? e.0 : e.1
            if tip == a0 { return (forward, true) }
        }
        var backward: [(Int, Bool)] = []
        tip = a0
        while let (id, rev) = next(at: tip, excluding: used) {
            // Walking backwards: the curve is traversed towards `tip`.
            backward.insert((id, !rev), at: 0); used.insert(id)
            let e = ends(sk.curve(id)!)!
            tip = rev ? e.1 : e.0
        }
        return (backward + forward, false)
    }

    // MARK: - Offset

    /// Offsets a chain of lines and arcs (or a circle) by `distance` to the `side` (+1: left of the chain's
    /// direction, −1: right). Copies are tied to the originals by `.offset` constraints sharing one group;
    /// returns the leader constraint (the dimension to edit).
    @discardableResult
    public static func offset(_ sk: inout Sketch, chainFrom start: Int, distance d: Double, side s: Double, text: String) -> Int? {
        let (items, closed) = chain(sk, from: start)
        guard !items.isEmpty, d > 0 else { return nil }
        // Circle alone.
        if items.count == 1, let c = sk.curve(items[0].id), case let .circle(ci, r) = c.geometry {
            let nr = r + s * d
            guard nr > 1e-9 else { return nil }
            let copy = sk.addCircle(center: ci, radius: nr)
            let g = sk.newId()
            return sk.addConstraint(.offset(curve: copy, source: c.id, value: text), labelOffset: Vec2(r + d, 0), group: g, factor: 1)
        }
        // Offset primitive per item, in traversal direction.
        enum Prim { case line(Vec2, Vec2), arc(center: Vec2, radius: Double, ccw: Bool) }
        var prims: [Prim] = []
        var starts: [Vec2] = []   // original start point of each item in traversal order
        for it in items {
            guard let c = sk.curve(it.id) else { return nil }
            switch c.geometry {
            case let .line(a, b):
                guard var p = sk.point(a), var q = sk.point(b) else { return nil }
                if it.reversed { swap(&p, &q) }
                let dir = simd_normalize(q - p), n = Vec2(-dir.y, dir.x) * s * d
                prims.append(.line(p + n, q + n)); starts.append(p)
            case let .arc(ci, st, en):
                guard let pc = sk.point(ci), let ps = sk.point(st), let pe = sk.point(en) else { return nil }
                let ccw = !it.reversed
                // Left of a counter-clockwise arc is its centre.
                let r = simd_distance(pc, ps) + (ccw ? -1 : 1) * s * d
                guard r > 1e-9 else { return nil }
                prims.append(.arc(center: pc, radius: r, ccw: ccw)); starts.append(it.reversed ? pe : ps)
            default:
                return nil   // splines aren't offset yet
            }
        }
        func startPoint(_ p: Prim, near o: Vec2) -> Vec2 {
            switch p {
            case let .line(a, _): return a
            case let .arc(c, r, _): return c + simd_normalize(o - c) * r
            }
        }
        func endPoint(_ p: Prim, near o: Vec2) -> Vec2 {
            switch p {
            case let .line(_, b): return b
            case let .arc(c, r, _): return c + simd_normalize(o - c) * r
            }
        }
        // Corner i joins prim i-1 and prim i at original point starts[i].
        func corner(_ i: Int) -> Vec2 {
            let o = starts[i]
            let prev = prims[(i - 1 + prims.count) % prims.count], cur = prims[i]
            let e = endPoint(prev, near: o), b = startPoint(cur, near: o)
            if simd_distance(e, b) < 1e-9 { return b }   // tangent joint
            if case let .line(p1, q1) = prev, case let .line(p2, q2) = cur {
                let d1 = q1 - p1, d2 = q2 - p2
                let den = d1.x * d2.y - d1.y * d2.x
                if abs(den) > 1e-12 {
                    let t = ((p2.x - p1.x) * d2.y - (p2.y - p1.y) * d2.x) / den
                    return p1 + t * d1
                }
            }
            return (e + b) / 2
        }
        let n = items.count
        var cornerIds: [Int] = []
        for i in 0..<n {
            if !closed && i == 0 { cornerIds.append(sk.addPoint(startPoint(prims[0], near: starts[0]))); continue }
            cornerIds.append(sk.addPoint(corner(i)))
        }
        let lastEnd: Int = closed ? cornerIds[0] : {
            guard let c = sk.curve(items[n - 1].id) else { return cornerIds[0] }
            let o: Vec2 = {
                switch c.geometry {
                case let .line(a, b): return sk.point(items[n - 1].reversed ? a : b) ?? .zero
                case let .arc(_, st, en): return sk.point(items[n - 1].reversed ? st : en) ?? .zero
                default: return .zero
                }
            }()
            return sk.addPoint(endPoint(prims[n - 1], near: o))
        }()
        let group = sk.newId()
        var leader: Int?
        for i in 0..<n {
            let a = cornerIds[i], b = i + 1 < n ? cornerIds[i + 1] : lastEnd
            let copy: Int
            switch prims[i] {
            case .line:
                copy = sk.addLine(a, b)
            case let .arc(c, _, ccw):
                let ci = sk.addPoint(c)
                copy = ccw ? sk.addArc(center: ci, start: a, end: b) : sk.addArc(center: ci, start: b, end: a)
            }
            let mid = ((sk.point(a) ?? .zero) + (sk.point(b) ?? .zero)) / 2
            let id = sk.addConstraint(.offset(curve: copy, source: items[i].id, value: text),
                                      labelOffset: i == 0 ? simd_normalize(mid - (starts[i])) * d : .zero,
                                      group: group, factor: 1)
            if i == 0 { leader = id }
        }
        return leader
    }

    // MARK: - Copies (mirror, patterns)

    /// Duplicates curves with a point mapping; returns new curve ids and the old→new point map.
    static func duplicate(_ sk: inout Sketch, _ curveIds: [Int], position: (Vec2) -> Vec2, keep: (Int) -> Bool = { _ in false },
                          flipArcs: Bool = false, group: Int? = nil) -> (curves: [(old: Int, new: Int)], points: [Int: Int]) {
        var map: [Int: Int] = [:]
        func mapped(_ p: Int) -> Int {
            if keep(p) { return p }
            if let m = map[p] { return m }
            let id = sk.addPoint(position(sk.point(p) ?? .zero))
            map[p] = id
            return id
        }
        var out: [(Int, Int)] = []
        for cid in curveIds {
            guard let c = sk.curve(cid) else { continue }
            let new: Int
            switch c.geometry {
            case let .line(a, b): new = sk.addLine(mapped(a), mapped(b), construction: c.construction)
            case let .circle(ci, r): new = sk.addCircle(center: mapped(ci), radius: r, construction: c.construction)
            case let .arc(ci, s, e):
                new = flipArcs ? sk.addArc(center: mapped(ci), start: mapped(e), end: mapped(s), construction: c.construction)
                               : sk.addArc(center: mapped(ci), start: mapped(s), end: mapped(e), construction: c.construction)
            case let .spline(pts, closed): new = sk.addSpline(pts.map(mapped), closed: closed, construction: c.construction)
            case let .text(a, t, h, f): new = sk.addText(t, at: mapped(a), height: h, font: f, construction: c.construction)
            }
            out.append((cid, new))
            if c.geometry.isCircle { sk.addConstraint(.equal(cid, new), group: group, factor: 1) }
        }
        return (out, map)
    }

    /// Mirrors curves across a line; copies stay symmetric (points on the axis are shared).
    @discardableResult
    public static func mirror(_ sk: inout Sketch, curves: [Int], axis: Int) -> [Int] {
        guard let ac = sk.curve(axis), case let .line(a, b) = ac.geometry, let pa = sk.point(a), let pb = sk.point(b) else { return [] }
        let u = simd_normalize(pb - pa)
        func reflect(_ p: Vec2) -> Vec2 { let v = p - pa; return pa + 2 * simd_dot(v, u) * u - v }
        let snapshot = sk
        // Points on the axis are their own mirror image and are shared.
        let onAxis = Set(snapshot.points.filter { abs(($0.position - pa).x * u.y - ($0.position - pa).y * u.x) < 1e-9 }.map(\.id))
        let g = sk.newId()
        let (pairs, map) = duplicate(&sk, curves.filter { $0 != axis }, position: reflect, keep: { onAxis.contains($0) }, flipArcs: true, group: g)
        for (old, new) in map.sorted(by: { $0.key < $1.key }) { sk.addConstraint(.symmetric(old, new, line: axis), group: g, factor: 1) }
        return pairs.map(\.new)
    }

    /// Rectangular pattern: `count` instances (including the original) along `direction` with `spacing`,
    /// optionally a second direction. Copies follow the original; one dimension per direction drives all.
    @discardableResult
    public static func rectangularPattern(_ sk: inout Sketch, curves: [Int], direction: Vec2, count: Int, spacing: Double, spacingText: String,
                                          direction2: Vec2? = nil, count2: Int = 1, spacing2: Double = 0, spacingText2: String = "") -> [Int] {
        guard count >= 1, count2 >= 1, simd_length(direction) > 1e-12 else { return [] }
        let u = simd_normalize(direction), v = direction2.map { simd_normalize($0) } ?? Vec2(-u.y, u.x)
        let g1 = sk.newId(), g2 = sk.newId()
        var leaders: [Int] = []
        var row: [Int: [Int: Int]] = [:]   // i → (original point → copy in the first row)
        for i in 0..<count {
            for j in 0..<count2 where i > 0 || j > 0 {
                let offset = u * spacing * Double(i) + v * spacing2 * Double(j)
                let (_, map) = duplicate(&sk, curves, position: { $0 + offset }, group: g1)
                if j == 0 { row[i] = map }
                for (old, new) in map.sorted(by: { $0.key < $1.key }) {
                    if j == 0 {
                        let id = sk.addConstraint(.translated(original: old, copy: new, direction: u, value: i == 1 ? spacingText : "\(i) * (\(spacingText))"),
                                                  labelOffset: v * -spacing * 0.3, group: g1, factor: Double(i))
                        if leaders.isEmpty { leaders.append(id) }
                    } else {
                        // Second direction: measured from the instance in the first row.
                        let base = i == 0 ? old : (row[i]?[old] ?? old)
                        let id = sk.addConstraint(.translated(original: base, copy: new, direction: v, value: j == 1 ? spacingText2 : "\(j) * (\(spacingText2))"),
                                                  labelOffset: u * -spacing2 * 0.3, group: g2, factor: Double(j))
                        if leaders.count == 1 && j == 1 && i == 0 { leaders.append(id) }
                    }
                }
            }
        }
        return leaders
    }

    /// Circular pattern: `count` instances spread evenly over `angle` degrees (360: full circle) about `center`.
    @discardableResult
    public static func circularPattern(_ sk: inout Sketch, curves: [Int], center: Int, count: Int, angle: Double = 360) -> Int? {
        guard count >= 2, let c = sk.point(center) else { return nil }
        let step = angle >= 360 - 1e-9 ? 360 / Double(count) : angle / Double(count - 1)
        let g = sk.newId()
        var leader: Int?
        for k in 1..<count {
            let t = step * Double(k) * .pi / 180
            let (cs, sn) = (cos(t), sin(t))
            let (_, map) = duplicate(&sk, curves, position: { p in
                let w = p - c
                return c + Vec2(cs * w.x - sn * w.y, sn * w.x + cs * w.y)
            }, keep: { $0 == center }, group: g)
            let text = Sketch.number((step * 1000).rounded() / 1000) + " deg"
            for (old, new) in map.sorted(by: { $0.key < $1.key }) {
                let id = sk.addConstraint(.rotated(center: center, original: old, copy: new, value: k == 1 ? text : "\(k) * (\(text))"),
                                          group: g, factor: Double(k))
                if leader == nil { leader = id }
            }
        }
        return leader
    }
}

extension CurveGeometry {
    var isCircle: Bool { if case .circle = self { return true }; return false }
}
