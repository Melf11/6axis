import Foundation
import simd

/// Tool geometry a feature adds or removes (reapplied by patterns).
public struct FeatureTool: @unchecked Sendable {
    public var shapes: [Shape]
    public var operation: BodyOperation
    public var targets: [UUID]
}

/// A thread that is only marked (no geometry): shown as a callout in drawings.
public struct ThreadMark: Sendable {
    public var body: UUID
    public var axis: Axis3
    /// Nominal (major) radius.
    public var radius: Double
    /// Range along the axis (from `axis.origin`).
    public var range: ClosedRange<Double>
    public var name: String
    /// Hole thread: the drilled (visible) radius is the tap drill, the thin line sits at the nominal size.
    public var isInternal: Bool = false
    /// Minor radius (external) or tap-drill radius (internal).
    public var innerRadius: Double = 0
    /// Feature that made the thread (patterns repeat its marks).
    public var feature: UUID? = nil

    /// The circle you see looking along the axis (bolt: nominal Ø; hole: tap drill).
    public var visibleRadius: Double { isInternal ? innerRadius : radius }
    /// The thin line of the ISO 6410 representation (bolt: minor Ø; hole: nominal Ø).
    public var thinRadius: Double { isInternal ? radius : innerRadius }
}

/// A rigid motion or mirror applied by patterns.
enum Placement {
    case rigid(simd_double3x3, Vec3)
    case mirror(origin: Vec3, normal: Vec3)

    func apply(_ s: Shape) throws -> Shape {
        switch self {
        case let .rigid(r, t): return try s.transformed(rotation: r, translation: t)
        case let .mirror(o, n): return try s.mirrored(origin: o, normal: n)
        }
    }

    func point(_ p: Vec3) -> Vec3 {
        switch self {
        case let .rigid(r, t): return r * p + t
        case let .mirror(o, n): return p - 2 * simd_dot(p - o, n) * simd_normalize(n)
        }
    }

    func direction(_ d: Vec3) -> Vec3 {
        switch self {
        case let .rigid(r, _): return r * d
        case let .mirror(_, n): return d - 2 * simd_dot(d, simd_normalize(n)) * simd_normalize(n)
        }
    }
}

extension ModelBuilder {
    // MARK: Construction geometry

    func constructionPlane(_ p: ConstructionPlaneFeature, _ state: ModelState, _ ev: inout Evaluator) throws -> Plane {
        guard let ref = p.plane else { throw KernelError("Keine Bezugsebene gewählt") }
        let base = try plane(for: ref, in: state)
        switch p.mode {
        case .offset:
            let d = try ev.evaluate(p.distance)
            return Plane(origin: base.origin + base.normal * d, xDir: base.xDir, normal: base.normal)
        case .angle:
            guard let axisRef = p.axis else { throw KernelError("Keine Drehachse gewählt") }
            let (o, dir) = try axis(axisRef, state)
            let r = rotationMatrix(axis: dir, angle: try ev.evaluate(p.angle, kind: .angle) * .pi / 180)
            // Through the axis, turned from the reference plane's orientation.
            return Plane(origin: o, xDir: r * base.xDir, normal: r * base.normal)
        case .midplane:
            guard let ref2 = p.plane2 else { throw KernelError("Zweite Ebene fehlt") }
            let other = try plane(for: ref2, in: state)
            if abs(simd_dot(base.normal, other.normal)) > 0.9999 {
                let gap = simd_dot(other.origin - base.origin, base.normal)
                return Plane(origin: base.origin + base.normal * (gap / 2), xDir: base.xDir, normal: base.normal)
            }
            // Bisector through the line where the planes meet.
            let line = try intersection(base, other)
            let n = simd_normalize(base.normal - other.normal)
            return Plane(origin: line.origin, xDir: line.direction, normal: n)
        }
    }

    func constructionAxis(_ a: ConstructionAxisFeature, _ state: ModelState) throws -> Axis3 {
        switch a.mode {
        case .reference:
            guard let ref = a.axis else { throw KernelError("Keine Kante oder Zylinderfläche gewählt") }
            let (o, d) = try axis(ref, state)
            return Axis3(origin: o, direction: d)
        case .twoPlanes:
            guard let r1 = a.plane, let r2 = a.plane2 else { throw KernelError("Zwei Ebenen wählen") }
            return try intersection(try plane(for: r1, in: state), try plane(for: r2, in: state))
        }
    }

    func intersection(_ a: Plane, _ b: Plane) throws -> Axis3 {
        let dir = simd_cross(a.normal, b.normal)
        guard simd_length(dir) > 1e-9 else { throw KernelError("Die Ebenen sind parallel") }
        // Point on both planes closest to the origin.
        let d1 = simd_dot(a.normal, a.origin), d2 = simd_dot(b.normal, b.origin)
        let n1 = a.normal, n2 = b.normal
        let p = (simd_cross(n2, dir) * d1 + simd_cross(dir, n1) * d2) / simd_length_squared(dir)
        return Axis3(origin: p, direction: dir)
    }

    // MARK: Holes

    /// Start point and drilling direction (into the material) of each hole position.
    func holePositions(_ h: HoleFeature, _ state: ModelState, _ ev: inout Evaluator) throws -> [(Vec3, Vec3)] {
        guard !h.points.isEmpty else { throw KernelError("Keine Position gewählt") }
        var positions: [(Vec3, Vec3)] = []
        var grid: (nx: Int, sx: Double, ny: Int, sy: Double)?
        if let g = h.grid {
            let nx = Int(try ev.evaluate(g.countX).rounded()), ny = Int(try ev.evaluate(g.countY).rounded())
            guard nx >= 1, ny >= 1 else { throw KernelError("Anzahl muss mindestens 1 sein") }
            guard nx * ny * h.points.count <= HoleGrid.maxHoles else { throw KernelError("Zu viele Bohrungen (höchstens \(HoleGrid.maxHoles))") }
            grid = (nx, nx > 1 ? try ev.evaluate(g.spacingX) : 0, ny, ny > 1 ? try ev.evaluate(g.spacingY) : 0)
        }
        for pt in h.points {
            var origin: Vec3, normal: Vec3
            /// In-plane X/Y of the position (the face's frame, or the sketch's axes).
            var plane: Plane
            switch pt {
            case let .sketchPoint(sid, pid):
                guard let sb = state.sketches[sid], let p = sb.sketch.point(pid) else { throw KernelError("Skizzenpunkt nicht mehr gefunden") }
                origin = sb.plane.point(p)
                normal = sb.plane.normal
                plane = sb.plane
            case let .face(bf, position):
                guard let body = state.bodies[bf.body], let idx = body.resolve(bf.face), let info = body.faceInfos[idx], info.isPlanar else {
                    throw KernelError("Fläche nicht mehr gefunden")
                }
                normal = info.normal
                origin = position - simd_dot(position - info.origin, normal) * normal
                plane = Plane.forFace(point: info.origin, normal: normal)
            case let .faceOffset(bf, x, y):
                guard let body = state.bodies[bf.body], let idx = body.resolve(bf.face), let frame = FaceFrame.of(body, face: idx) else {
                    throw KernelError("Fläche nicht mehr gefunden")
                }
                normal = frame.plane.normal
                origin = frame.point(try ev.evaluate(x), try ev.evaluate(y))
                plane = frame.plane
            }
            let dir = h.flip ? normal : -normal
            guard let grid else { positions.append((origin, dir)); continue }
            let ex = plane.point(Vec2(1, 0)) - plane.point(.zero), ey = plane.point(Vec2(0, 1)) - plane.point(.zero)
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    positions.append((origin + ex * (Double(i) * grid.sx) + ey * (Double(j) * grid.sy), dir))
                }
            }
        }
        return positions
    }

    func applyHole(_ f: Feature, _ h: HoleFeature, _ state: inout ModelState, _ ev: inout Evaluator) throws {
        let thread = h.thread.flatMap(MetricThread.named)
        let r = try (thread?.tapDrill ?? ev.evaluate(h.diameter)) / 2
        guard r > 0 else { throw KernelError("Durchmesser muss größer als 0 sein") }
        let through = h.extent == .through
        let depth = through ? modelSize(state) * 2 + 10 : try ev.evaluate(h.depth)
        guard depth > 0 else { throw KernelError("Tiefe muss größer als 0 sein") }
        let eps = max(0.05, r * 0.05)   // start slightly outside so the cut opens the surface cleanly
        // Profile (radius, depth) of half the hole, revolved around the drilling axis.
        var profile: [Vec2] = [Vec2(0, -eps)]
        switch h.type {
        case .simple:
            profile += [Vec2(r, -eps), Vec2(r, depth)]
        case .counterbore:
            let R = try ev.evaluate(h.headDiameter) / 2, hd = try ev.evaluate(h.headDepth)
            guard R > r, hd > 0, hd < depth else { throw KernelError("Senkung muss größer als die Bohrung und weniger tief sein") }
            profile += [Vec2(R, -eps), Vec2(R, hd), Vec2(r, hd), Vec2(r, depth)]
        case .countersink:
            let R = try ev.evaluate(h.headDiameter) / 2
            let half = try ev.evaluate(h.countersinkAngle, kind: .angle) / 2 * .pi / 180
            guard R > r, half > 0.05, half < 1.5 else { throw KernelError("Senkung muss größer als die Bohrung sein") }
            let coneDepth = (R - r) / tan(half)
            guard coneDepth < depth else { throw KernelError("Bohrung ist kürzer als die Senkung") }
            profile += [Vec2(R + eps * tan(half), -eps), Vec2(r, coneDepth), Vec2(r, depth)]
        }
        profile.append(Vec2(0, depth))

        var tools: [Shape] = []
        let positions = try holePositions(h, state, &ev)
        for (o, d) in positions {
            let u = simd_normalize(abs(d.x) < 0.9 ? simd_cross(d, Vec3(1, 0, 0)) : simd_cross(d, Vec3(0, 1, 0)))
            let pl = Plane(origin: o, xDir: u, normal: simd_cross(u, d))
            let segs = (0..<profile.count).map { Segment2D.line(profile[$0], profile[($0 + 1) % profile.count]) }
            guard let face = try Shape.sketchRegions(plane: pl, segments: segs).faces.first else { throw KernelError("Bohrung fehlgeschlagen") }
            tools.append(try face.revolved(origin: o, axis: d, angle: 2 * .pi))
        }
        state.tools[f.id] = FeatureTool(shapes: tools, operation: .cut, targets: [])
        try combine(tools, op: .cut, targets: [], feature: f.id, &state)

        guard let thread else { return }
        let threadDepth = depth
        for (o, d) in positions {
            let axis = Axis3(origin: o, direction: d)
            if h.threadModeled && !markThreads {
                let groove = try threadGroove(thread, axis: axis, radius: r, range: 0...threadDepth, isInternal: true)
                state.tools[f.id]?.shapes.append(groove)
                try combine([groove], op: .cut, targets: [], feature: f.id, &state)
            } else if let body = state.bodyOrder.first(where: { touches(state.bodies[$0]!, o) }) {
                state.threadMarks.append(ThreadMark(body: body, axis: axis, radius: thread.major / 2, range: 0...threadDepth, name: thread.name,
                                                    isInternal: true, innerRadius: r, feature: f.id))
            }
        }
    }

    private func touches(_ body: BuiltBody, _ p: Vec3) -> Bool {
        guard let bb = body.shape.boundingBox else { return false }
        return p.x >= bb.min.x - 1e-3 && p.x <= bb.max.x + 1e-3 && p.y >= bb.min.y - 1e-3 && p.y <= bb.max.y + 1e-3
            && p.z >= bb.min.z - 1e-3 && p.z <= bb.max.z + 1e-3
    }

    func modelSize(_ state: ModelState) -> Double {
        var lo = Vec3(repeating: .greatestFiniteMagnitude), hi = -lo
        for b in state.bodies.values {
            if let bb = b.shape.boundingBox { lo = simd_min(lo, bb.min); hi = simd_max(hi, bb.max) }
        }
        return lo.x <= hi.x ? simd_length(hi - lo) + simd_length(simd_max(simd_abs(lo), simd_abs(hi))) : 1000
    }

    // MARK: Threads

    /// V-groove along `range` (axis coordinates) of a cylinder with radius `radius`.
    func threadGroove(_ t: MetricThread, axis: Axis3, radius r: Double, range: ClosedRange<Double>, isInternal: Bool) throws -> Shape {
        let p = t.pitch
        // External: from just outside the surface down to the minor diameter (ISO h3 = 0.6134 P).
        // Internal: from just inside the hole out to the nominal diameter.
        let base = isInternal ? r - 0.05 * p : r + 0.05 * p
        let apex = isInternal ? max(t.major / 2, r + 0.3 * p) + 0.05 * p : r - 0.6134 * p
        let width = min(2 * abs(apex - base) * tan(.pi / 6), 0.9 * p)
        // Keep the groove clear of the end faces: touching them makes the boolean cut unreliable.
        let margin = 0.15 * p
        let length = range.upperBound - range.lowerBound - width - 2 * margin
        guard length > p else { throw KernelError("Gewinde ist zu kurz") }
        return try Shape.threadGroove(axisOrigin: axis.origin, axisDir: axis.direction, start: range.lowerBound + width / 2 + margin,
                                      length: length, pitch: p, apexRadius: apex, baseRadius: base, width: width)
    }

    func applyThread(_ f: Feature, _ t: ThreadFeature, _ state: inout ModelState) throws {
        guard !t.faces.isEmpty else { throw KernelError("Keine Zylinderfläche gewählt") }
        var tools: [Shape] = []
        for bf in t.faces {
            guard let body = state.bodies[bf.body], let idx = body.resolve(bf.face), let info = body.faceInfos[idx] else {
                throw KernelError("Fläche nicht mehr gefunden")
            }
            guard info.surface == .cylinder else { throw KernelError("Gewinde braucht eine zylindrische Fläche") }
            let axis = Axis3(origin: info.axisOrigin, direction: info.axisDir)
            // A point on the surface (the centroid of a full cylinder lies on its axis).
            let along = info.origin - axis.origin
            let radial = along - simd_dot(along, axis.direction) * axis.direction
            let isInternal = simd_dot(info.normal, radial) < 0
            guard let size = t.size.flatMap(MetricThread.named) ?? MetricThread.matching(diameter: 2 * info.radius, isInternal: isInternal) else {
                throw KernelError("Keine passende Gewindegröße")
            }
            if t.modeled && !markThreads {
                let groove = try threadGroove(size, axis: axis, radius: info.radius, range: info.axisRange, isInternal: isInternal)
                tools.append(groove)
                let cut = try body.shape.boolean(.cut, groove)
                state.setBody(BuiltBody(id: bf.body, shape: cut, sourceFeature: f.id))
            } else {
                state.threadMarks.append(ThreadMark(body: bf.body, axis: axis, radius: isInternal ? size.major / 2 : info.radius,
                                                    range: info.axisRange, name: size.name, isInternal: isInternal,
                                                    innerRadius: isInternal ? info.radius : info.radius - 0.6134 * size.pitch, feature: f.id))
            }
        }
        state.tools[f.id] = FeatureTool(shapes: tools, operation: .cut, targets: t.faces.map(\.body))
    }

    // MARK: Patterns

    func placements(_ p: PatternFeature, _ state: ModelState, _ ev: inout Evaluator) throws -> [Placement] {
        switch p.kind {
        case .rectangular:
            guard let d1 = p.direction else { throw KernelError("Keine Richtung gewählt") }
            let v1 = try axis(d1, state).1 * (try ev.evaluate(p.spacing))
            let n1 = try count(p.count, &ev)
            var v2 = Vec3.zero, n2 = 1
            if let d2 = p.direction2 {
                v2 = try axis(d2, state).1 * (try ev.evaluate(p.spacing2))
                n2 = try count(p.count2, &ev)
            }
            var out: [Placement] = []
            for j in 0..<n2 { for i in 0..<n1 where i > 0 || j > 0 {
                out.append(.rigid(matrix_identity_double3x3, v1 * Double(i) + v2 * Double(j)))
            } }
            return out
        case .circular:
            guard let a = p.axis else { throw KernelError("Keine Achse gewählt") }
            let (o, dir) = try axis(a, state)
            let n = try count(p.circularCount, &ev)
            let total = try ev.evaluate(p.angle, kind: .angle)
            let step = (abs(total - 360) < 1e-6 ? 360 / Double(n) : total / Double(max(n - 1, 1))) * .pi / 180
            return (1..<n).map { k in
                let r = rotationMatrix(axis: dir, angle: step * Double(k))
                return .rigid(r, o - r * o)
            }
        case .mirror:
            guard let ref = p.plane else { throw KernelError("Keine Spiegelebene gewählt") }
            let pl = try plane(for: ref, in: state)
            return [.mirror(origin: pl.origin, normal: pl.normal)]
        }
    }

    private func count(_ text: String, _ ev: inout Evaluator) throws -> Int {
        let n = Int((try ev.evaluate(text, kind: .scalar)).rounded())
        guard n >= 1, n <= 1000 else { throw KernelError("Anzahl muss zwischen 1 und 1000 liegen") }
        return n
    }

    func applyPattern(_ f: Feature, _ p: PatternFeature, _ state: inout ModelState, _ ev: inout Evaluator) throws {
        guard !p.bodies.isEmpty || !p.features.isEmpty else { throw KernelError("Keine Körper oder Elemente gewählt") }
        let places = try placements(p, state, &ev)
        var n = 0
        for id in p.bodies {
            guard let body = state.bodies[id] else { throw KernelError("Körper nicht mehr vorhanden") }
            for (pi, place) in places.enumerated() {
                n += 1
                let copy = f.id.derived(n)
                state.setBody(BuiltBody(id: copy, shape: try place.apply(body.shape), sourceFeature: f.id))
                state.copyOf[copy] = id
                // Each placement is one instance: copies of several bodies at the same place belong together.
                state.copiedBy[copy] = f.id.derived(100_000 + pi)
            }
        }
        var all: [Shape] = []
        for fid in p.features {
            let marks = state.threadMarks.filter { $0.feature == fid }
            for place in places {
                for var m in marks {
                    m.axis = Axis3(origin: place.point(m.axis.origin), direction: place.direction(m.axis.direction))
                    m.feature = f.id
                    state.threadMarks.append(m)
                }
            }
            // Threads only marked (drawings) leave no tool; their marks were repeated above.
            guard let tool = state.tools[fid], !tool.shapes.isEmpty else {
                if !marks.isEmpty { continue }
                throw KernelError("Element kann nicht wiederholt werden")
            }
            for place in places {
                n += 1
                let shapes = try tool.shapes.map { try place.apply($0) }
                all += shapes
                try combine(shapes, op: tool.operation, targets: tool.targets, feature: f.id.derived(n), &state)
            }
        }
        if !all.isEmpty { state.tools[f.id] = FeatureTool(shapes: all, operation: .cut, targets: []) }
    }

    // MARK: Moving and combining bodies

    func applyMove(_ f: Feature, _ m: MoveFeature, _ state: inout ModelState, _ ev: inout Evaluator) throws {
        guard !m.bodies.isEmpty else { throw KernelError("Keine Körper gewählt") }
        let t = Vec3(try ev.evaluate(m.dx), try ev.evaluate(m.dy), try ev.evaluate(m.dz))
        let angle = try ev.evaluate(m.angle, kind: .angle) * .pi / 180
        var r = matrix_identity_double3x3, o = Vec3.zero
        if abs(angle) > 1e-12, let a = m.axis {
            let (ao, dir) = try axis(a, state)
            r = rotationMatrix(axis: dir, angle: angle)
            o = m.turnsAboutCenter ? (state.center(of: m.bodies) ?? ao) : ao
        }
        // Turn around the axis, then shift.
        let translation = o - r * o + t
        for (i, id) in m.bodies.enumerated() {
            guard let body = state.bodies[id] else { throw KernelError("Körper nicht mehr vorhanden") }
            let moved = try body.shape.transformed(rotation: r, translation: translation)
            let target = m.copy ? f.id.derived(i + 1) : id
            state.setBody(BuiltBody(id: target, shape: moved, sourceFeature: f.id))
            if m.copy {
                state.copyOf[target] = id
                state.copiedBy[target] = f.id
            }
        }
    }

    func applyCombine(_ f: Feature, _ c: CombineFeature, _ state: inout ModelState) throws {
        guard let targetId = c.target, let target = state.bodies[targetId] else { throw KernelError("Kein Zielkörper gewählt") }
        let tools = c.tools.filter { $0 != targetId }.compactMap { state.bodies[$0] }
        guard !tools.isEmpty else { throw KernelError("Keine Werkzeugkörper gewählt") }
        let tool = tools.count == 1 ? tools[0].shape : try Shape.fuseAll(tools.map(\.shape))
        let op: Shape.BooleanOp
        switch c.operation {
        case .join, .newBody: op = .fuse
        case .cut: op = .cut
        case .intersect: op = .common
        }
        let result = try target.shape.boolean(op, tool)
        guard result.solidCount > 0 else { throw KernelError("Ergebnis ist leer") }
        state.setBody(BuiltBody(id: targetId, shape: result, sourceFeature: f.id))
        if !c.keepTools { for b in tools { state.removeBody(b.id) } }
    }
}
