import Foundation
import simd

extension SketchEdit {
    /// Adds projected reference geometry (body edges flattened onto the sketch plane). Each polyline becomes
    /// the simplest matching curve – line, circle, arc or spline – with fixed points; endpoints shared by
    /// several polylines (or already in the sketch) are merged so projected faces form closed profiles.
    @discardableResult
    public static func project(_ sk: inout Sketch, polylines: [[Vec2]], tolerance: Double = 1e-4) -> [Int] {
        func pointId(_ p: Vec2) -> Int {
            if let e = sk.points.first(where: { simd_distance($0.position, p) < tolerance * 10 }) { return e.id }
            let id = sk.addPoint(p)
            sk.points[sk.pointIndex(id)!].fixed = true
            return id
        }
        var out: [Int] = []
        for raw in polylines {
            var poly: [Vec2] = []
            for p in raw where poly.last.map({ simd_distance($0, p) > tolerance }) ?? true { poly.append(p) }
            guard poly.count >= 2 else { continue }
            let closed = poly.count > 3 && simd_distance(poly[0], poly[poly.count - 1]) < tolerance * 10
            if closed { poly.removeLast() }
            // Straight?
            let a = poly[0], b = poly[poly.count - 1]
            let dir = b - a
            let straight = !closed && simd_length(dir) > tolerance && poly.allSatisfy { p in
                abs((p - a).x * dir.y - (p - a).y * dir.x) / simd_length(dir) < tolerance * 10
            }
            if straight {
                out.append(sk.addLine(pointId(a), pointId(b)))
                continue
            }
            // Circular?
            if poly.count >= 3, let (c, r) = circleThrough(poly[0], poly[poly.count / 2], poly[closed ? poly.count * 3 / 4 : poly.count - 1]),
               poly.allSatisfy({ abs(simd_distance($0, c) - r) < max(tolerance * 10, r * 1e-4) }) {
                let center = sk.addPoint(c)
                sk.points[sk.pointIndex(center)!].fixed = true
                if closed {
                    out.append(sk.addCircle(center: center, radius: r))
                } else {
                    // Orientation: counter-clockwise from a to b if the middle lies on that side.
                    let mid = poly[poly.count / 2]
                    func ang(_ p: Vec2) -> Double { atan2(p.y - c.y, p.x - c.x) }
                    let ccw = normalizedAngle(ang(mid) - ang(a)) < normalizedAngle(ang(b) - ang(a))
                    out.append(ccw ? sk.addArc(center: center, start: pointId(a), end: pointId(b))
                                   : sk.addArc(center: center, start: pointId(b), end: pointId(a)))
                }
                continue
            }
            // Free-form: spline through evenly spaced samples.
            let n = min(12, max(3, poly.count / 4))
            var lengths: [Double] = [0]
            for i in 1..<poly.count { lengths.append(lengths[i - 1] + simd_distance(poly[i - 1], poly[i])) }
            let total = lengths.last! + (closed ? simd_distance(poly[poly.count - 1], poly[0]) : 0)
            var fit: [Vec2] = []
            for k in 0..<(closed ? n : n + 1) {
                let target = total * Double(k) / Double(n)
                if let j = lengths.firstIndex(where: { $0 >= target }) { fit.append(poly[min(j, poly.count - 1)]) } else { fit.append(poly[poly.count - 1]) }
            }
            let ids = fit.enumerated().map { (i, p) -> Int in
                if i == 0 || (!closed && i == fit.count - 1) { return pointId(p) }
                let id = sk.addPoint(p)
                sk.points[sk.pointIndex(id)!].fixed = true
                return id
            }
            out.append(sk.addSpline(ids, closed: closed))
        }
        return out
    }

    /// Joins unordered segments (as delivered by meshing) into polylines.
    public static func polylines(from segments: [(Vec2, Vec2)], tolerance: Double = 1e-6) -> [[Vec2]] {
        var rest = segments
        var out: [[Vec2]] = []
        while let first = rest.first {
            rest.removeFirst()
            var line = [first.0, first.1]
            var grew = true
            while grew {
                grew = false
                for (i, s) in rest.enumerated() {
                    if simd_distance(s.0, line[line.count - 1]) < tolerance { line.append(s.1) }
                    else if simd_distance(s.1, line[line.count - 1]) < tolerance { line.append(s.0) }
                    else if simd_distance(s.1, line[0]) < tolerance { line.insert(s.0, at: 0) }
                    else if simd_distance(s.0, line[0]) < tolerance { line.insert(s.1, at: 0) }
                    else { continue }
                    rest.remove(at: i)
                    grew = true
                    break
                }
            }
            out.append(line)
        }
        return out
    }

    /// 3D polylines of one edge of a body (from its display tessellation).
    static func edgePolylines(_ mesh: TriangleMesh, edge: Int) -> [[Vec3]] {
        var pieces: [(Vec3, Vec3)] = []
        for (k, s) in mesh.edgeSegments.enumerated() where Int(mesh.edgeIds[k]) == edge {
            pieces.append((Vec3(Double(s.0.x), Double(s.0.y), Double(s.0.z)), Vec3(Double(s.1.x), Double(s.1.y), Double(s.1.z))))
        }
        return join3D(pieces)
    }

    static func join3D(_ segments: [(Vec3, Vec3)], tolerance: Double = 1e-5) -> [[Vec3]] {
        var rest = segments
        var out: [[Vec3]] = []
        while let first = rest.first {
            rest.removeFirst()
            var line = [first.0, first.1]
            var grew = true
            while grew {
                grew = false
                for (i, s) in rest.enumerated() {
                    if simd_distance(s.0, line[line.count - 1]) < tolerance { line.append(s.1) }
                    else if simd_distance(s.1, line[line.count - 1]) < tolerance { line.append(s.0) }
                    else if simd_distance(s.1, line[0]) < tolerance { line.insert(s.0, at: 0) }
                    else if simd_distance(s.0, line[0]) < tolerance { line.insert(s.1, at: 0) }
                    else { continue }
                    rest.remove(at: i)
                    grew = true
                    break
                }
            }
            out.append(line)
        }
        return out
    }

    /// Projects one body edge onto the sketch plane.
    @discardableResult
    public static func projectEdge(_ sk: inout Sketch, body: BuiltBody, edge: Int, plane: Plane) -> [Int] {
        guard let mesh = body.mesh else { return [] }
        let polys = edgePolylines(mesh, edge: edge).map { $0.map { plane.project($0) } }
        return project(&sk, polylines: polys)
    }

    /// Projects all edges of a body face (outer boundary and holes) onto the sketch plane.
    @discardableResult
    public static func projectFace(_ sk: inout Sketch, body: BuiltBody, face: Int, plane: Plane) -> [Int] {
        guard let f = try? body.shape.face(face), let mesh = try? f.mesh(linearDeflection: 0.02, angularDeflection: 0.2) else { return [] }
        let edges = Set(mesh.edgeIds.map { Int($0) })
        let polys = edges.sorted().flatMap { e in edgePolylines(mesh, edge: e).map { $0.map { plane.project($0) } } }
        return project(&sk, polylines: polys)
    }
}

