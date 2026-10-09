import Foundation
import simd

public struct SolveResult: Sendable {
    public var converged: Bool
    public var maxResidual: Double
    /// Constraints that are not satisfied after solving (conflicts) or whose value failed to evaluate.
    public var failedConstraints: Set<Int>
    /// Remaining degrees of freedom.
    public var degreesOfFreedom: Int
    /// Points and curves whose position is fully determined (drawn black, like Fusion).
    public var fullyConstrainedPoints: Set<Int>
    public var fullyConstrainedCurves: Set<Int>

    public var isFullyConstrained: Bool { degreesOfFreedom == 0 && converged }
}

/// Geometric constraint solver: damped least squares (Levenberg) over point coordinates and circle radii.
/// Small sketches (a few hundred variables) solve in well under a millisecond per iteration.
public struct SketchSolver {
    public var evaluator: Evaluator
    public var tolerance = 1e-7

    public init(evaluator: Evaluator = Evaluator()) {
        self.evaluator = evaluator
    }

    /// A residual block: a few residuals depending on a few variables.
    struct Block {
        var constraintId: Int?
        var weight: Double
        var vars: [Int]
        var eval: (_ x: UnsafeBufferPointer<Double>, _ out: inout [Double]) -> Void
        var count: Int
    }

    struct Layout {
        var pointVar: [Int: Int] = [:]     // point id → index of x (y = x + 1)
        var radiusVar: [Int: Int] = [:]    // circle curve id → index
        var fixedPoints: [Int: Vec2] = [:]
        var count = 0
    }

    // MARK: Public API

    /// Solves the sketch in place.
    @discardableResult
    public func solve(_ sketch: inout Sketch) -> SolveResult {
        solve(&sketch, pinned: [:], pinnedRadii: [:])
    }

    /// Solves while moving the given points towards targets (interactive dragging).
    /// First tries to pin the dragged geometry exactly; if that conflicts, falls back to a soft pull.
    @discardableResult
    public func drag(_ sketch: inout Sketch, points: [Int: Vec2], radii: [Int: Double] = [:]) -> SolveResult {
        var trial = sketch
        for (id, p) in points { trial.setPoint(id, p) }
        let pinned = solve(&trial, pinned: points, pinnedRadii: radii)
        if pinned.converged {
            sketch = trial
            return solve(&sketch, pinned: [:], pinnedRadii: [:])
        }
        var soft = sketch
        _ = solve(&soft, pinned: [:], pinnedRadii: [:], soft: points, softRadii: radii)
        sketch = soft
        return solve(&sketch, pinned: [:], pinnedRadii: [:])
    }

    // MARK: Core

    func solve(_ sketch: inout Sketch, pinned: [Int: Vec2], pinnedRadii: [Int: Double],
               soft: [Int: Vec2] = [:], softRadii: [Int: Double] = [:]) -> SolveResult {
        var layout = Layout()
        for p in sketch.points {
            if p.fixed {
                layout.fixedPoints[p.id] = p.position
            } else if let pin = pinned[p.id] {
                layout.fixedPoints[p.id] = pin
            } else {
                layout.pointVar[p.id] = layout.count
                layout.count += 2
            }
        }
        var x = [Double](repeating: 0, count: 0)
        for p in sketch.points where layout.pointVar[p.id] != nil {
            x.append(p.position.x); x.append(p.position.y)
        }
        var fixedRadius: [Int: Double] = [:]
        for c in sketch.curves {
            if case let .circle(_, r) = c.geometry {
                if let pr = pinnedRadii[c.id] {
                    fixedRadius[c.id] = pr
                } else {
                    layout.radiusVar[c.id] = layout.count
                    layout.count += 1
                    x.append(r)
                }
            }
        }

        var failed = Set<Int>()
        var blocks = makeBlocks(sketch, layout: layout, fixedRadius: fixedRadius, x: x, failed: &failed)
        for (id, target) in soft {
            guard let i = layout.pointVar[id] else { continue }
            blocks.append(Block(constraintId: nil, weight: 0.1, vars: [i, i + 1], eval: { x, out in
                out[0] = x[i] - target.x
                out[1] = x[i + 1] - target.y
            }, count: 2))
        }
        for (id, target) in softRadii {
            guard let i = layout.radiusVar[id] else { continue }
            blocks.append(Block(constraintId: nil, weight: 0.1, vars: [i], eval: { x, out in out[0] = x[i] - target }, count: 1))
        }

        let converged = levenberg(&x, blocks: blocks)

        // Write back.
        for (id, i) in layout.pointVar { sketch.setPoint(id, Vec2(x[i], x[i + 1])) }
        for (id, p) in layout.fixedPoints where pinned[id] != nil { sketch.setPoint(id, p) }
        for i in sketch.curves.indices {
            if case let .circle(c, r) = sketch.curves[i].geometry {
                let nr = layout.radiusVar[sketch.curves[i].id].map { x[$0] } ?? fixedRadius[sketch.curves[i].id] ?? r
                sketch.curves[i].geometry = .circle(center: c, radius: abs(nr))
            }
        }

        // Diagnostics on hard constraints only.
        let hard = blocks.filter { $0.constraintId != nil || $0.weight == 1 }
        var maxRes = 0.0
        x.withUnsafeBufferPointer { xp in
            for b in hard {
                var out = [Double](repeating: 0, count: b.count)
                b.eval(xp, &out)
                let m = out.map(abs).max() ?? 0
                maxRes = max(maxRes, m)
                if m > tolerance * 100, let cid = b.constraintId { failed.insert(cid) }
            }
        }
        let (dof, determined) = analyzeFreedom(x: x, blocks: hard, varCount: layout.count)

        var fullPoints = Set(layout.fixedPoints.keys)
        for (id, i) in layout.pointVar where determined[i] && determined[i + 1] { fullPoints.insert(id) }
        var fullCurves = Set<Int>()
        for c in sketch.curves {
            let pointsOk = c.geometry.pointIds.allSatisfy { fullPoints.contains($0) }
            let radiusOk = layout.radiusVar[c.id].map { determined[$0] } ?? true
            if pointsOk && radiusOk { fullCurves.insert(c.id) }
        }

        return SolveResult(
            converged: converged && maxRes < tolerance * 100,
            maxResidual: maxRes,
            failedConstraints: failed,
            degreesOfFreedom: dof,
            fullyConstrainedPoints: fullPoints,
            fullyConstrainedCurves: fullCurves)
    }

    // MARK: Residuals

    func makeBlocks(_ sk: Sketch, layout: Layout, fixedRadius: [Int: Double], x x0: [Double], failed: inout Set<Int>) -> [Block] {
        var blocks: [Block] = []
        var ev = evaluator

        // Accessors producing closures over the variable vector.
        typealias PointFn = (UnsafeBufferPointer<Double>) -> Vec2
        func P(_ id: Int) -> (PointFn, [Int])? {
            if let i = layout.pointVar[id] { return ({ Vec2($0[i], $0[i + 1]) }, [i, i + 1]) }
            if let f = layout.fixedPoints[id] { return ({ _ in f }, []) }
            return nil
        }
        func curve(_ id: Int) -> SketchCurve? { sk.curve(id) }
        func lineEnds(_ id: Int) -> (PointFn, PointFn, [Int])? {
            guard let c = curve(id), case let .line(a, b) = c.geometry, let pa = P(a), let pb = P(b) else { return nil }
            return (pa.0, pb.0, pa.1 + pb.1)
        }
        /// Center and radius accessors for circles/arcs.
        func round(_ id: Int) -> (PointFn, (UnsafeBufferPointer<Double>) -> Double, [Int])? {
            guard let c = curve(id) else { return nil }
            switch c.geometry {
            case let .circle(ci, r):
                guard let pc = P(ci) else { return nil }
                if let ri = layout.radiusVar[id] { return (pc.0, { $0[ri] }, pc.1 + [ri]) }
                let fr = fixedRadius[id] ?? r
                return (pc.0, { _ in fr }, pc.1)
            case let .arc(ci, s, _):
                guard let pc = P(ci), let ps = P(s) else { return nil }
                return (pc.0, { x in simd_distance(pc.0(x), ps.0(x)) }, pc.1 + ps.1)
            case .line, .spline:
                return nil
            }
        }
        /// Fit points of a spline (positions from the variable vector).
        func splinePoints(_ id: Int) -> ((UnsafeBufferPointer<Double>) -> [Vec2], Bool, [Int])? {
            guard let c = curve(id), case let .spline(ids, closed) = c.geometry else { return nil }
            let ps = ids.compactMap { P($0) }
            guard ps.count == ids.count, ps.count >= 2 else { return nil }
            return ({ x in ps.map { $0.0(x) } }, closed, ps.flatMap { $0.1 })
        }
        let xInit = x0
        func initial<T>(_ f: (UnsafeBufferPointer<Double>) -> T) -> T { xInit.withUnsafeBufferPointer { f($0) } }
        func add(_ cid: Int?, _ vars: [Int], _ count: Int, _ eval: @escaping (UnsafeBufferPointer<Double>, inout [Double]) -> Void) {
            blocks.append(Block(constraintId: cid, weight: 1, vars: Array(Set(vars)).sorted(), eval: eval, count: count))
        }
        func crossN(_ d: Vec2, _ v: Vec2) -> Double {
            let l = max(simd_length(d), 1e-12)
            return (d.x * v.y - d.y * v.x) / l
        }
        func sgn(_ v: Double) -> Double { v < 0 ? -1 : 1 }

        // Implicit: arc endpoints share the radius.
        for c in sk.curves {
            if case let .arc(ci, s, e) = c.geometry, let pc = P(ci), let ps = P(s), let pe = P(e) {
                add(nil, pc.1 + ps.1 + pe.1, 1) { x, o in
                    o[0] = simd_distance(ps.0(x), pc.0(x)) - simd_distance(pe.0(x), pc.0(x))
                }
            }
        }

        for con in sk.constraints {
            let cid = con.id
            var value = 0.0
            if let expr = con.kind.dimensionValue {
                guard let v = try? ev.evaluate(expr, kind: con.kind.valueKind) else { failed.insert(cid); continue }
                value = v
            }
            switch con.kind {
            case let .coincident(a, b):
                guard let pa = P(a), let pb = P(b) else { failed.insert(cid); continue }
                add(cid, pa.1 + pb.1, 2) { x, o in
                    let d = pa.0(x) - pb.0(x)
                    o[0] = d.x; o[1] = d.y
                }
            case let .horizontal(l):
                guard let (a, b, v) = lineEnds(l) else { failed.insert(cid); continue }
                add(cid, v, 1) { x, o in o[0] = a(x).y - b(x).y }
            case let .vertical(l):
                guard let (a, b, v) = lineEnds(l) else { failed.insert(cid); continue }
                add(cid, v, 1) { x, o in o[0] = a(x).x - b(x).x }
            case let .horizontalPoints(p1, p2):
                guard let a = P(p1), let b = P(p2) else { failed.insert(cid); continue }
                add(cid, a.1 + b.1, 1) { x, o in o[0] = a.0(x).y - b.0(x).y }
            case let .verticalPoints(p1, p2):
                guard let a = P(p1), let b = P(p2) else { failed.insert(cid); continue }
                add(cid, a.1 + b.1, 1) { x, o in o[0] = a.0(x).x - b.0(x).x }
            case let .parallel(l1, l2):
                guard let (a1, b1, v1) = lineEnds(l1), let (a2, b2, v2) = lineEnds(l2) else { failed.insert(cid); continue }
                add(cid, v1 + v2, 1) { x, o in
                    let d1 = simd_normalize(b1(x) - a1(x)), d2 = b2(x) - a2(x)
                    o[0] = crossN(d2, d1)
                }
            case let .perpendicular(l1, l2):
                guard let (a1, b1, v1) = lineEnds(l1), let (a2, b2, v2) = lineEnds(l2) else { failed.insert(cid); continue }
                add(cid, v1 + v2, 1) { x, o in
                    let d1 = b1(x) - a1(x), d2 = b2(x) - a2(x)
                    o[0] = simd_dot(d1, d2) / max(simd_length(d1) * simd_length(d2), 1e-12)
                }
            case let .collinear(l1, l2):
                guard let (a1, b1, v1) = lineEnds(l1), let (a2, b2, v2) = lineEnds(l2) else { failed.insert(cid); continue }
                add(cid, v1 + v2, 2) { x, o in
                    let d = b1(x) - a1(x)
                    o[0] = crossN(d, a2(x) - a1(x))
                    o[1] = crossN(d, b2(x) - a1(x))
                }
            case let .equal(c1, c2):
                if let (a1, b1, v1) = lineEnds(c1), let (a2, b2, v2) = lineEnds(c2) {
                    add(cid, v1 + v2, 1) { x, o in o[0] = simd_distance(a1(x), b1(x)) - simd_distance(a2(x), b2(x)) }
                } else if let r1 = round(c1), let r2 = round(c2) {
                    add(cid, r1.2 + r2.2, 1) { x, o in o[0] = r1.1(x) - r2.1(x) }
                } else {
                    failed.insert(cid)
                }
            case let .tangent(c1, c2):
                if let lineId = [c1, c2].first(where: { lineEnds($0) != nil }), let arcId = [c1, c2].first(where: { $0 != lineId }),
                   let line = curve(lineId), let arc = curve(arcId), case let .line(la, lb) = line.geometry,
                   case let .arc(ci, s, e) = arc.geometry, let shared = [s, e].first(where: { $0 == la || $0 == lb }),
                   let pc = P(ci), let pt = P(shared), let (a, b, vl) = lineEnds(lineId) {
                    // Arc and line meet at a common endpoint: the radius there is perpendicular to the line.
                    // Equivalent to "distance = radius", but well-conditioned (that form has zero slope along
                    // the line at the touching point, which made the point look free).
                    add(cid, vl + pc.1 + pt.1, 1) { x, o in
                        let d = b(x) - a(x)
                        o[0] = simd_dot(pt.0(x) - pc.0(x), d) / max(simd_length(d), 1e-12)
                    }
                } else if let (a, b, vl) = lineEnds(c1) ?? lineEnds(c2), let r = (lineEnds(c1) != nil ? round(c2) : round(c1)) {
                    let side = initial { x in sgn(crossN(b(x) - a(x), r.0(x) - a(x))) }
                    add(cid, vl + r.2, 1) { x, o in o[0] = side * crossN(b(x) - a(x), r.0(x) - a(x)) - r.1(x) }
                } else if let r1 = round(c1), let r2 = round(c2) {
                    let (isInternal, bigger) = initial { x -> (Bool, Double) in
                        let d = simd_distance(r1.0(x), r2.0(x))
                        let ext = abs(d - (r1.1(x) + r2.1(x))), int = abs(d - abs(r1.1(x) - r2.1(x)))
                        return (int < ext, sgn(r1.1(x) - r2.1(x)))
                    }
                    add(cid, r1.2 + r2.2, 1) { x, o in
                        let d = simd_distance(r1.0(x), r2.0(x))
                        o[0] = isInternal ? d - bigger * (r1.1(x) - r2.1(x)) : d - (r1.1(x) + r2.1(x))
                    }
                } else {
                    failed.insert(cid)
                }
            case let .pointOnCurve(p, c):
                guard let pp = P(p) else { failed.insert(cid); continue }
                if let (a, b, v) = lineEnds(c) {
                    add(cid, pp.1 + v, 1) { x, o in o[0] = crossN(b(x) - a(x), pp.0(x) - a(x)) }
                } else if let r = round(c) {
                    add(cid, pp.1 + r.2, 1) { x, o in o[0] = simd_distance(pp.0(x), r.0(x)) - r.1(x) }
                } else if let (fit, closed, v) = splinePoints(c) {
                    // Signed distance to the nearest piece of the sampled spline.
                    add(cid, pp.1 + v, 1) { x, o in
                        let poly = Spline.polyline(fit(x), closed: closed, perSegment: 16)
                        let p = pp.0(x)
                        var best = Double.infinity, signed = 0.0
                        for k in 0..<(poly.count - 1) {
                            let a = poly[k], d = poly[k + 1] - a
                            let t = max(0, min(1, simd_dot(p - a, d) / max(simd_length_squared(d), 1e-18)))
                            let dist = simd_distance(p, a + t * d)
                            if dist < best { best = dist; signed = crossN(d, p - a) }
                        }
                        o[0] = signed
                    }
                } else {
                    failed.insert(cid)
                }
            case let .midpoint(p, l):
                guard let pp = P(p), let (a, b, v) = lineEnds(l) else { failed.insert(cid); continue }
                add(cid, pp.1 + v, 2) { x, o in
                    let d = pp.0(x) - (a(x) + b(x)) / 2
                    o[0] = d.x; o[1] = d.y
                }
            case let .concentric(c1, c2):
                guard let r1 = round(c1), let r2 = round(c2) else { failed.insert(cid); continue }
                add(cid, r1.2 + r2.2, 2) { x, o in
                    let d = r1.0(x) - r2.0(x)
                    o[0] = d.x; o[1] = d.y
                }
            case let .symmetric(p1, p2, l):
                guard let a = P(p1), let b = P(p2), let (la, lb, v) = lineEnds(l) else { failed.insert(cid); continue }
                add(cid, a.1 + b.1 + v, 2) { x, o in
                    let d = lb(x) - la(x)
                    let m = (a.0(x) + b.0(x)) / 2
                    o[0] = crossN(d, m - la(x))
                    o[1] = simd_dot(b.0(x) - a.0(x), d) / max(simd_length(d), 1e-12)
                }
            case let .distance(p1, p2, _):
                guard let a = P(p1), let b = P(p2) else { failed.insert(cid); continue }
                add(cid, a.1 + b.1, 1) { x, o in o[0] = simd_distance(a.0(x), b.0(x)) - value }
            case let .horizontalDistance(p1, p2, _):
                guard let a = P(p1), let b = P(p2) else { failed.insert(cid); continue }
                let s = initial { x in sgn(b.0(x).x - a.0(x).x) }
                add(cid, a.1 + b.1, 1) { x, o in o[0] = s * (b.0(x).x - a.0(x).x) - value }
            case let .verticalDistance(p1, p2, _):
                guard let a = P(p1), let b = P(p2) else { failed.insert(cid); continue }
                let s = initial { x in sgn(b.0(x).y - a.0(x).y) }
                add(cid, a.1 + b.1, 1) { x, o in o[0] = s * (b.0(x).y - a.0(x).y) - value }
            case let .pointLineDistance(p, l, _):
                guard let pp = P(p), let (a, b, v) = lineEnds(l) else { failed.insert(cid); continue }
                let s = initial { x in sgn(crossN(b(x) - a(x), pp.0(x) - a(x))) }
                add(cid, pp.1 + v, 1) { x, o in o[0] = s * crossN(b(x) - a(x), pp.0(x) - a(x)) - value }
            case let .length(l, _):
                guard let (a, b, v) = lineEnds(l) else { failed.insert(cid); continue }
                add(cid, v, 1) { x, o in o[0] = simd_distance(a(x), b(x)) - value }
            case let .radius(c, _):
                guard let r = round(c) else { failed.insert(cid); continue }
                add(cid, r.2, 1) { x, o in o[0] = r.1(x) - value }
            case let .diameter(c, _):
                guard let r = round(c) else { failed.insert(cid); continue }
                add(cid, r.2, 1) { x, o in o[0] = 2 * r.1(x) - value }
            case let .angle(l1, l2, _):
                guard let (a1, b1, v1) = lineEnds(l1), let (a2, b2, v2) = lineEnds(l2) else { failed.insert(cid); continue }
                let target = value * .pi / 180
                let s = initial { x -> Double in
                    let d1 = b1(x) - a1(x), d2 = b2(x) - a2(x)
                    return sgn(d1.x * d2.y - d1.y * d2.x)
                }
                add(cid, v1 + v2, 1) { x, o in
                    let d1 = b1(x) - a1(x), d2 = b2(x) - a2(x)
                    let th = atan2(d1.x * d2.y - d1.y * d2.x, simd_dot(d1, d2))
                    let diff = th - s * target
                    o[0] = atan2(sin(diff), cos(diff))
                }
            }
        }
        return blocks
    }

    // MARK: Numerics

    func residuals(_ x: [Double], _ blocks: [Block]) -> [Double] {
        var r: [Double] = []
        x.withUnsafeBufferPointer { xp in
            for b in blocks {
                var out = [Double](repeating: 0, count: b.count)
                b.eval(xp, &out)
                r.append(contentsOf: out.map { $0 * b.weight })
            }
        }
        return r
    }

    /// Dense Jacobian by central differences, exploiting block sparsity.
    func jacobian(_ x: inout [Double], _ blocks: [Block], rows: Int) -> [[Double]] {
        let n = x.count
        var J = [[Double]](repeating: [Double](repeating: 0, count: n), count: rows)
        var row = 0
        for b in blocks {
            var plus = [Double](repeating: 0, count: b.count), minus = plus
            for j in b.vars {
                let h = 1e-7 * max(1, abs(x[j]))
                let orig = x[j]
                x[j] = orig + h
                x.withUnsafeBufferPointer { b.eval($0, &plus) }
                x[j] = orig - h
                x.withUnsafeBufferPointer { b.eval($0, &minus) }
                x[j] = orig
                for k in 0..<b.count { J[row + k][j] = b.weight * (plus[k] - minus[k]) / (2 * h) }
            }
            row += b.count
        }
        return J
    }

    func levenberg(_ x: inout [Double], blocks: [Block]) -> Bool {
        let n = x.count
        guard n > 0, !blocks.isEmpty else { return true }
        var r = residuals(x, blocks)
        var cost = r.reduce(0) { $0 + $1 * $1 }
        var lambda = 1e-6
        for _ in 0..<150 {
            if (r.map(abs).max() ?? 0) < tolerance * 0.01 { return true }
            let J = jacobian(&x, blocks, rows: r.count)
            var A = [Double](repeating: 0, count: n * n)
            var g = [Double](repeating: 0, count: n)
            for (i, Ji) in J.enumerated() {
                let nz = Ji.indices.filter { Ji[$0] != 0 }
                for a in nz {
                    g[a] += Ji[a] * r[i]
                    for b in nz { A[a * n + b] += Ji[a] * Ji[b] }
                }
            }
            var improved = false
            while lambda < 1e10 {
                var M = A
                for i in 0..<n { M[i * n + i] += lambda * (1 + A[i * n + i]) }
                guard let delta = choleskySolve(M, g.map { -$0 }, n) else { lambda *= 10; continue }
                let xn = zip(x, delta).map { $0 + $1 }
                let rn = residuals(xn, blocks)
                let cn = rn.reduce(0) { $0 + $1 * $1 }
                if cn < cost {
                    let step = delta.map(abs).max() ?? 0
                    x = xn; r = rn; cost = cn
                    lambda = max(lambda / 10, 1e-12)
                    improved = true
                    if step < 1e-13 { return (r.map(abs).max() ?? 0) < tolerance }
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        return (r.map(abs).max() ?? 0) < tolerance
    }

    func choleskySolve(_ A: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = A[i * n + j]
                for k in 0..<j { s -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    guard s > 0 else { return nil }
                    L[i * n + i] = sqrt(s)
                } else {
                    L[i * n + j] = s / L[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for k in 0..<i { s -= L[i * n + k] * y[k] }
            y[i] = s / L[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n { s -= L[k * n + i] * x[k] }
            x[i] = s / L[i * n + i]
        }
        return x
    }

    /// Rank analysis of the constraint Jacobian: returns the remaining degrees of freedom and,
    /// per variable, whether it is determined (zero in every null-space vector).
    func analyzeFreedom(x: [Double], blocks: [Block], varCount n: Int) -> (Int, [Bool]) {
        guard n > 0 else { return (0, []) }
        var xs = x
        let rows = blocks.reduce(0) { $0 + $1.count }
        guard rows > 0 else { return (n, [Bool](repeating: false, count: n)) }
        var M = jacobian(&xs, blocks, rows: rows)
        // Reduced row echelon form.
        var pivotCols: [Int] = []
        var r = 0
        for c in 0..<n where r < rows {
            var best = r
            for i in r..<rows where abs(M[i][c]) > abs(M[best][c]) { best = i }
            guard abs(M[best][c]) > 1e-8 else { continue }
            M.swapAt(r, best)
            let pv = M[r][c]
            for k in 0..<n { M[r][k] /= pv }
            for i in 0..<rows where i != r && M[i][c] != 0 {
                let f = M[i][c]
                for k in 0..<n { M[i][k] -= f * M[r][k] }
            }
            pivotCols.append(c)
            r += 1
        }
        let pivotSet = Set(pivotCols)
        let free = (0..<n).filter { !pivotSet.contains($0) }
        var determined = [Bool](repeating: true, count: n)
        for f in free {
            determined[f] = false
            // Null-space vector: x_f = 1, x_pivot = -M[row][f].
            for (row, pc) in pivotCols.enumerated() where abs(M[row][f]) > 1e-8 { determined[pc] = false }
        }
        return (free.count, determined)
    }
}
