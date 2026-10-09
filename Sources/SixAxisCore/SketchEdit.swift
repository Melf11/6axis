import Foundation
import simd

/// Editing operations on sketches (fillet, chamfer, trim, offset, mirror, pattern …).
/// They work on the model only, so they are testable without UI; the editor wraps them in undo steps.
public enum SketchEdit {
    /// The two lines meeting at a corner point and their far endpoints.
    struct Corner {
        let point: Int
        let lines: (Int, Int)
        let far: (Int, Int)
    }

    static func corner(_ sk: Sketch, at p: Int) -> Corner? {
        let lines = sk.curves.filter { !$0.construction }.filter { c in
            if case let .line(a, b) = c.geometry { return a == p || b == p }
            return false
        }
        // Exactly two lines, nothing else (arcs, splines) attached.
        guard lines.count == 2, sk.curves.filter({ !$0.construction && $0.geometry.pointIds.contains(p) }).count == 2 else { return nil }
        func other(_ c: SketchCurve) -> Int? {
            guard case let .line(a, b) = c.geometry else { return nil }
            return a == p ? b : a
        }
        guard let fa = other(lines[0]), let fb = other(lines[1]) else { return nil }
        return Corner(point: p, lines: (lines[0].id, lines[1].id), far: (fa, fb))
    }

    /// Replaces the corner endpoint of a line with `newPoint`.
    static func replaceEndpoint(_ sk: inout Sketch, line: Int, old: Int, new: Int) {
        guard let i = sk.curveIndex(line), case let .line(a, b) = sk.curves[i].geometry else { return }
        sk.curves[i].geometry = .line(start: a == old ? new : a, end: b == old ? new : b)
    }

    /// Keeps the sharp corner as a "virtual corner": construction lines to the new endpoints, the corner
    /// stays on both line extensions, and length dimensions of the trimmed lines are re-attached to it –
    /// so a 600 mm side stays 600 mm when its corner is rounded.
    @discardableResult
    static func keepVirtualCorner(_ sk: inout Sketch, _ c: Corner, ends: (Int, Int)) -> (Int, Int) {
        let k1 = sk.addLine(c.point, ends.0, construction: true)
        let k2 = sk.addLine(c.point, ends.1, construction: true)
        sk.addConstraint(.pointOnCurve(point: c.point, curve: c.lines.0))
        sk.addConstraint(.pointOnCurve(point: c.point, curve: c.lines.1))
        for i in sk.constraints.indices {
            if case let .length(l, v) = sk.constraints[i].kind {
                if l == c.lines.0 { sk.constraints[i].kind = .distance(c.far.0, c.point, value: v) }
                if l == c.lines.1 { sk.constraints[i].kind = .distance(c.far.1, c.point, value: v) }
            }
        }
        return (k1, k2)
    }

    /// Rounds the corner between two lines with a tangent arc. `radiusText` becomes the driving radius
    /// dimension (an expression like "20 mm" or "eckradius"). Returns the arc and the dimension ids.
    @discardableResult
    public static func fillet(_ sk: inout Sketch, corner p: Int, radius r: Double, radiusText: String) -> (arc: Int, dimension: Int)? {
        guard r > 0, let c = corner(sk, at: p), let P = sk.point(p), let A = sk.point(c.far.0), let B = sk.point(c.far.1) else { return nil }
        let la = simd_distance(A, P), lb = simd_distance(B, P)
        guard la > 1e-9, lb > 1e-9 else { return nil }
        let u = (A - P) / la, v = (B - P) / lb
        let theta = acos(max(-1, min(1, simd_dot(u, v))))
        guard theta > 1e-3, theta < .pi - 1e-3 else { return nil }   // collinear lines have no corner
        let t = r / tan(theta / 2)
        guard t < la - 1e-9, t < lb - 1e-9 else { return nil }      // radius too large for the lines
        let center = P + simd_normalize(u + v) * (r / sin(theta / 2))
        let t1 = sk.addPoint(P + u * t), t2 = sk.addPoint(P + v * t)
        let ci = sk.addPoint(center)
        replaceEndpoint(&sk, line: c.lines.0, old: p, new: t1)
        replaceEndpoint(&sk, line: c.lines.1, old: p, new: t2)
        // Counter-clockwise from the start: cross(T1 - C, T2 - C) > 0 means T1 → T2 is CCW.
        let d1 = P + u * t - center, d2 = P + v * t - center
        let arc = d1.x * d2.y - d1.y * d2.x > 0 ? sk.addArc(center: ci, start: t1, end: t2) : sk.addArc(center: ci, start: t2, end: t1)
        sk.addConstraint(.tangent(c.lines.0, arc))
        sk.addConstraint(.tangent(c.lines.1, arc))
        keepVirtualCorner(&sk, c, ends: (t1, t2))
        let dim = sk.addConstraint(.radius(curve: arc, value: radiusText), labelOffset: simd_normalize(center - P) * r * 1.6)
        return (arc, dim)
    }

    /// Cuts the corner with a straight line at `distance` from the corner on both lines.
    @discardableResult
    public static func chamfer(_ sk: inout Sketch, corner p: Int, distance d: Double, distanceText: String) -> (line: Int, dimension: Int)? {
        guard d > 0, let c = corner(sk, at: p), let P = sk.point(p), let A = sk.point(c.far.0), let B = sk.point(c.far.1) else { return nil }
        let la = simd_distance(A, P), lb = simd_distance(B, P)
        guard d < la - 1e-9, d < lb - 1e-9 else { return nil }
        let u = (A - P) / la, v = (B - P) / lb
        guard abs(u.x * v.y - u.y * v.x) > 1e-6 else { return nil }
        let t1 = sk.addPoint(P + u * d), t2 = sk.addPoint(P + v * d)
        replaceEndpoint(&sk, line: c.lines.0, old: p, new: t1)
        replaceEndpoint(&sk, line: c.lines.1, old: p, new: t2)
        let edge = sk.addLine(t1, t2)
        let (k1, k2) = keepVirtualCorner(&sk, c, ends: (t1, t2))
        let dim = sk.addConstraint(.length(line: k1, value: distanceText), labelOffset: simd_normalize(u + v) * -d)
        sk.addConstraint(.equal(k1, k2))
        return (edge, dim)
    }
}
