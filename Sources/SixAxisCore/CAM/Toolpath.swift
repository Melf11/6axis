import Foundation
import simd

/// One move of the cutter (world coordinates).
public struct ToolpathMove: Sendable, Equatable {
    public enum Kind: Sendable { case rapid, feed, plunge }
    public var kind: Kind
    public var to: Vec3
}

public struct OperationPath: Sendable {
    public var operation: UUID
    public var name: String
    public var tool: CAMTool
    public var moves: [ToolpathMove]
}

/// Toolpaths for a whole setup, with the stock and the work origin.
public struct CAMResult: Sendable {
    public var paths: [OperationPath] = []
    public var stockMin = Vec3.zero
    public var stockMax = Vec3.zero
    /// Program zero (world coordinates).
    public var origin = Vec3.zero
    public var safeZ = 0.0
    public var warnings: [String] = []

    /// Machining time estimate in seconds (rapids at `rapid` mm/min).
    public func time(rapid: Double = 3000) -> Double {
        var t = 0.0
        for p in paths {
            var last: Vec3?
            for m in p.moves {
                defer { last = m.to }
                guard let a = last else { continue }
                let rate: Double
                switch m.kind {
                case .rapid: rate = rapid
                case .feed: rate = p.tool.feed
                case .plunge: rate = p.tool.plunge
                }
                t += simd_distance(a, m.to) / max(rate, 1) * 60
            }
        }
        return t
    }

    /// Cutting length (feed moves) in mm.
    public var cutLength: Double {
        var l = 0.0
        for p in paths {
            for (a, b) in zip(p.moves, p.moves.dropFirst()) where b.kind != .rapid { l += simd_distance(a.to, b.to) }
        }
        return l
    }
}

/// Builds toolpaths from a setup. Coordinates stay in world space; the post processor shifts them to the origin.
public enum CAMPlanner {
    public static func plan(_ setup: CAMSetup, state: ModelState, evaluator: Evaluator, bodies visible: [UUID]) -> CAMResult {
        var r = CAMResult()
        var ev = evaluator
        func value(_ s: String) -> Double { (try? ev.evaluate(s)) ?? 0 }
        let bodies = (setup.bodies.isEmpty ? visible : setup.bodies).compactMap { state.bodies[$0] }
        var lo = Vec3(repeating: .greatestFiniteMagnitude), hi = -lo
        for b in bodies { if let bb = b.shape.exactBoundingBox { lo = simd_min(lo, bb.min); hi = simd_max(hi, bb.max) } }
        guard lo.x <= hi.x else {
            r.warnings.append(String(localized: "Keine Körper zum Fräsen"))
            return r
        }
        let m = value(setup.margin)
        r.stockMin = lo - Vec3(m, m, 0)
        r.stockMax = hi + Vec3(m, m, value(setup.topExtra))
        let top = r.stockMax.z
        switch setup.origin {
        case .frontLeftTop: r.origin = Vec3(r.stockMin.x, r.stockMin.y, top)
        case .backLeftTop: r.origin = Vec3(r.stockMin.x, r.stockMax.y, top)
        case .centerTop: r.origin = Vec3((r.stockMin.x + r.stockMax.x) / 2, (r.stockMin.y + r.stockMax.y) / 2, top)
        case .frontLeftBottom: r.origin = r.stockMin
        }
        r.safeZ = top + max(value(setup.safeZ), 1)

        for op in setup.operations where op.enabled {
            guard let tool = setup.tools.first(where: { $0.id == op.tool }) else {
                r.warnings.append(String(localized: "„\(op.name)“: kein Werkzeug gewählt"))
                continue
            }
            var b = PathBuilder(tool: tool, safeZ: r.safeZ, clearance: top + 1)
            var warnings: [String] = []
            switch op.kind {
            case .contour: contour(op, &b, state: state, top: top, value: value, warnings: &warnings)
            case .pocket: pocket(op, &b, state: state, top: top, warnings: &warnings)
            case .drill: drill(op, &b, state: state, warnings: &warnings)
            }
            if b.deepest < top - tool.fluteLength - 1e-6 {
                warnings.append(String(localized: "Schnitttiefe \(formatValue(top - b.deepest)) ist größer als die Schneidenlänge von \(tool.name)"))
            }
            r.warnings += warnings.map { "„\(op.name)“: \($0)" }
            if b.moves.count > 1 { r.paths.append(OperationPath(operation: op.id, name: op.name, tool: tool, moves: b.finish())) }
        }
        return r
    }

    // MARK: Geometry

    static func faceShape(_ ref: BodyFaceRef, _ state: ModelState) -> (Shape, FaceInfo, BuiltBody)? {
        guard let body = state.bodies[ref.body], let i = body.resolve(ref.face), let info = body.faceInfos[i],
              let shape = try? body.shape.face(i) else { return nil }
        return (shape, info, body)
    }

    static func signedArea(_ loop: [Vec3]) -> Double {
        var a = 0.0
        for (p, q) in zip(loop, loop.dropFirst()) { a += p.x * q.y - q.x * p.y }
        return a / 2
    }

    /// Orients a closed loop: counter-clockwise seen from above when `ccw`.
    static func oriented(_ loop: [Vec3], ccw: Bool) -> [Vec3] {
        (signedArea(loop) > 0) == ccw ? loop : loop.reversed()
    }

    static func levels(from top: Double, to bottom: Double, step: Double) -> [Double] {
        guard bottom < top - 1e-9 else { return [] }
        let n = max(1, Int(ceil((top - bottom) / max(step, 0.05) - 1e-9)))
        return (1...n).map { top - (top - bottom) * Double($0) / Double(n) }
    }

    // MARK: Contour

    static func contour(_ op: CAMOperation, _ b: inout PathBuilder, state: ModelState, top: Double, value: (String) -> Double,
                        warnings: inout [String]) {
        guard !op.faces.isEmpty else { warnings.append(String(localized: "keine Fläche gewählt")); return }
        let r = b.tool.diameter / 2
        for ref in op.faces {
            guard let (face, info, body) = faceShape(ref, state) else { warnings.append(String(localized: "Fläche nicht mehr gefunden")); continue }
            guard info.isPlanar, info.normal.z > 0.999 else { warnings.append(String(localized: "Teil liegt nicht flach (Oberseite muss nach oben zeigen)")); continue }
            let bottom = (body.shape.exactBoundingBox?.min.z ?? info.origin.z) - value(op.overcut)
            var loops = face.faceLoops(offset: op.side == .on ? 0 : r, deflection: 0.01)
            guard !loops.isEmpty else { continue }
            let outerIndex = loops.indices.max { abs(signedArea(loops[$0])) < abs(signedArea(loops[$1])) }!
            switch op.side {
            case .outside: loops = [loops[outerIndex]]
            case .inside:
                loops.remove(at: outerIndex)
                if loops.isEmpty { warnings.append(String(localized: "keine Innenkontur (Aussparung) in dieser Fläche")) }
            case .on: break
            }
            let tabTop = bottom + value(op.overcut) + value(op.tabHeight)
            for (i, loop) in loops.enumerated() {
                // Climb milling with a clockwise spindle: around the outside clockwise, inside counter-clockwise.
                let isOuter = op.side == .outside || (op.side == .on && i == outerIndex)
                let path = oriented(loop, ccw: isOuter != op.climb)
                let tabs = op.tabs > 0 ? tabIntervals(path, count: op.tabs, width: value(op.tabWidth) + b.tool.diameter) : []
                b.cutLoop(path, levels: levels(from: top, to: bottom, step: b.tool.stepdown), tabs: tabs, tabTop: tabTop)
            }
        }
    }

    /// Path length intervals (tool centre) where tabs stay, evenly spaced.
    static func tabIntervals(_ loop: [Vec3], count: Int, width: Double) -> [ClosedRange<Double>] {
        let length = zip(loop, loop.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        guard count > 0, length > Double(count) * width * 1.5 else { return [] }
        return (0..<count).map { k in
            let c = length * (Double(k) + 0.5) / Double(count)
            return (c - width / 2)...(c + width / 2)
        }
    }

    // MARK: Pocket

    static func pocket(_ op: CAMOperation, _ b: inout PathBuilder, state: ModelState, top: Double, warnings: inout [String]) {
        guard !op.faces.isEmpty else { warnings.append(String(localized: "keine Fläche gewählt")); return }
        let r = b.tool.diameter / 2, step = max(b.tool.stepover, 0.05) * b.tool.diameter
        for ref in op.faces {
            guard let (face, info, _) = faceShape(ref, state) else { warnings.append(String(localized: "Fläche nicht mehr gefunden")); continue }
            guard info.isPlanar, info.normal.z > 0.999 else { warnings.append(String(localized: "Taschenboden muss waagerecht nach oben zeigen")); continue }
            // Rings from the finishing pass (offset r) inwards until the area is used up; cut innermost first.
            var rings: [[[Vec3]]] = []
            var k = 0
            while k < 2000 {
                let loops = face.faceLoops(offset: -(r + Double(k) * step), deflection: 0.01).filter { $0.count > 3 }
                if loops.isEmpty { break }
                rings.append(loops)
                k += 1
            }
            if rings.isEmpty { warnings.append(String(localized: "Werkzeug ist zu groß für die Tasche")); continue }
            let bottom = info.origin.z
            for z in levels(from: top, to: bottom, step: b.tool.stepdown) {
                for ring in rings.reversed() {
                    for loop in ring { b.cutLoop(oriented(loop, ccw: op.climb), levels: [z], tabs: [], tabTop: z, singleLevel: true) }
                }
            }
        }
    }

    // MARK: Drilling

    static func drill(_ op: CAMOperation, _ b: inout PathBuilder, state: ModelState, warnings: inout [String]) {
        guard !op.faces.isEmpty else { warnings.append(String(localized: "keine Fläche gewählt")); return }
        var holes: [(center: Vec3, top: Double, bottom: Double, radius: Double)] = []
        for ref in op.faces {
            guard let body = state.bodies[ref.body], let i = body.resolve(ref.face), let picked = body.faceInfos[i] else { continue }
            // A hole picked directly, or all vertical holes of the part when its top face was picked.
            let candidates = picked.surface == .cylinder ? [picked] : body.faceInfos.compactMap { $0 }.filter { $0.surface == .cylinder }
            for c in candidates where abs(c.axisDir.z) > 0.999 {
                let along = c.origin - c.axisOrigin
                let radial = along - simd_dot(along, c.axisDir) * c.axisDir
                guard simd_dot(c.normal, radial) < 0 else { continue }   // holes only, not bolts
                let z0 = c.axisOrigin.z + c.axisDir.z * c.axisRange.lowerBound, z1 = c.axisOrigin.z + c.axisDir.z * c.axisRange.upperBound
                let center = Vec3(c.axisOrigin.x, c.axisOrigin.y, 0)
                if !holes.contains(where: { simd_distance($0.center, center) < 1e-3 }) {
                    holes.append((center, max(z0, z1), min(z0, z1), c.radius))
                }
            }
        }
        guard !holes.isEmpty else { warnings.append(String(localized: "keine senkrechten Bohrungen gefunden")); return }
        // Shortest walk: nearest neighbour from the front left.
        var rest = holes, ordered: [(center: Vec3, top: Double, bottom: Double, radius: Double)] = []
        var at = Vec3(-1e9, -1e9, 0)
        while !rest.isEmpty {
            let i = rest.indices.min { simd_distance(rest[$0].center, at) < simd_distance(rest[$1].center, at) }!
            at = rest[i].center
            ordered.append(rest.remove(at: i))
        }
        let toolR = b.tool.diameter / 2
        for h in ordered {
            if h.radius < toolR - 0.05 {
                warnings.append(String(localized: "Bohrung Ø\(formatValue(2 * h.radius)) ist kleiner als das Werkzeug"))
                continue
            }
            if b.tool.kind != .drill && h.radius > toolR + 0.05 {
                // Circular interpolation with an end mill (one circle per step, then the finishing circle).
                let rr = h.radius - toolR
                let circle = (0...72).map { i -> Vec3 in
                    let a = Double(i) / 72 * 2 * .pi
                    return Vec3(h.center.x + rr * cos(a), h.center.y + rr * sin(a), 0)
                }
                b.cutLoop(circle, levels: levels(from: h.top, to: h.bottom, step: b.tool.stepdown), tabs: [], tabTop: h.bottom)
            } else {
                if abs(h.radius - toolR) > 0.05 {
                    warnings.append(String(localized: "Bohrung Ø\(formatValue(2 * h.radius)) mit \(b.tool.name)"))
                }
                b.peck(at: h.center, top: h.top, bottom: h.bottom)
            }
        }
    }
}

/// Accumulates moves with safe linking between cuts.
struct PathBuilder {
    let tool: CAMTool
    let safeZ: Double
    /// Rapid down to here before plunging (just above the stock).
    let clearance: Double
    var moves: [ToolpathMove] = []
    var deepest = Double.greatestFiniteMagnitude

    init(tool: CAMTool, safeZ: Double, clearance: Double) {
        self.tool = tool
        self.safeZ = safeZ
        self.clearance = clearance
    }

    var position: Vec3? { moves.last?.to }

    mutating func add(_ kind: ToolpathMove.Kind, _ p: Vec3) {
        if let last = position, simd_distance(last, p) < 1e-9 { return }
        moves.append(ToolpathMove(kind: kind, to: p))
        deepest = min(deepest, p.z)
    }

    /// Retract, move over `p` and come down to the clearance height.
    mutating func approach(_ p: Vec3) {
        if let last = position {
            if simd_distance(Vec2(last.x, last.y), Vec2(p.x, p.y)) < 1e-6 && last.z <= clearance + 1e-9 { return }
            add(.rapid, Vec3(last.x, last.y, safeZ))
        }
        add(.rapid, Vec3(p.x, p.y, safeZ))
        add(.rapid, Vec3(p.x, p.y, clearance))
    }

    mutating func finish() -> [ToolpathMove] {
        if let last = position { add(.rapid, Vec3(last.x, last.y, safeZ)) }
        return moves
    }

    /// One closed loop at each Z level, entering by a ramp along the loop; tab intervals are lifted to `tabTop`.
    mutating func cutLoop(_ loop: [Vec3], levels: [Double], tabs: [ClosedRange<Double>], tabTop: Double, singleLevel: Bool = false) {
        guard loop.count > 2, !levels.isEmpty else { return }
        approach(loop[0])
        // Contours start their ramp on the surface; pockets come down from the clearance height.
        var currentZ = singleLevel ? clearance : clearance - 1
        if !singleLevel { add(.plunge, Vec3(loop[0].x, loop[0].y, currentZ)) }
        let rampLength = max(tool.diameter * 3, 5)
        for z in levels {
            ramp(loop, from: currentZ, to: z, length: rampLength)
            walk(loop, z: z, tabs: tabs, tabTop: tabTop)
            currentZ = z
        }
    }

    /// Descends from `z0` to `z1` along the start of the loop, then returns to its start at `z1`.
    mutating func ramp(_ loop: [Vec3], from z0: Double, to z1: Double, length: Double) {
        add(.plunge, Vec3(loop[0].x, loop[0].y, max(z0, position?.z ?? z0)))
        var s = 0.0
        var trail: [Vec3] = [Vec3(loop[0].x, loop[0].y, z1)]
        for (a, b) in zip(loop, loop.dropFirst()) {
            let d = simd_distance(a, b)
            if s + d >= length {
                let t = (length - s) / max(d, 1e-12)
                let p = a + (b - a) * t
                add(.plunge, Vec3(p.x, p.y, z1))
                trail.append(Vec3(p.x, p.y, z1))
                break
            }
            s += d
            add(.plunge, Vec3(b.x, b.y, z0 + (z1 - z0) * s / length))
            trail.append(Vec3(b.x, b.y, z1))
        }
        // Back along the ramp at full depth, so the loop starts at its first point.
        for p in trail.reversed().dropFirst() { add(.feed, p) }
    }

    /// Follows the loop at depth z, lifting over tabs.
    mutating func walk(_ loop: [Vec3], z: Double, tabs: [ClosedRange<Double>], tabTop: Double) {
        let lifted = z < tabTop - 1e-9 && !tabs.isEmpty
        func zAt(_ s: Double) -> Double { lifted && tabs.contains { $0.contains(s) } ? tabTop : z }
        var s = 0.0
        for (a, b) in zip(loop, loop.dropFirst()) {
            let d = simd_distance(a, b)
            // Split the segment at tab boundaries.
            var cuts = [0.0, d]
            if lifted {
                for t in tabs {
                    for e in [t.lowerBound, t.upperBound] where e > s && e < s + d { cuts.append(e - s) }
                }
                cuts.sort()
            }
            for (c0, c1) in zip(cuts, cuts.dropFirst()) where c1 - c0 > 1e-9 {
                let mid = s + (c0 + c1) / 2
                let zz = zAt(mid)
                let p0 = a + (b - a) * (c0 / d), p1 = a + (b - a) * (c1 / d)
                if let cur = position, abs(cur.z - zz) > 1e-9 { add(.plunge, Vec3(p0.x, p0.y, zz)) }
                add(.feed, Vec3(p1.x, p1.y, zz))
            }
            s += d
        }
    }

    /// Peck drilling: down by one step, out to clear chips, back down.
    mutating func peck(at c: Vec3, top: Double, bottom: Double) {
        approach(Vec3(c.x, c.y, top))
        var z = top
        while z > bottom + 1e-9 {
            let next = max(bottom, z - tool.stepdown)
            add(.plunge, Vec3(c.x, c.y, next))
            if next > bottom + 1e-9 {
                add(.rapid, Vec3(c.x, c.y, clearance))
                add(.rapid, Vec3(c.x, c.y, next + 0.5))
            }
            z = next
        }
        add(.rapid, Vec3(c.x, c.y, clearance))
    }
}
