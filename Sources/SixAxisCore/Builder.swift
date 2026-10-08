import Foundation
import simd

/// A solid body produced by the timeline. Tessellation and topology info are computed lazily and cached.
public final class BuiltBody: @unchecked Sendable {
    public let id: UUID
    public let shape: Shape
    /// Feature that last modified this body.
    public let sourceFeature: UUID

    public init(id: UUID, shape: Shape, sourceFeature: UUID) {
        self.id = id
        self.shape = shape
        self.sourceFeature = sourceFeature
    }

    public private(set) lazy var mesh: TriangleMesh? = {
        guard let bb = shape.boundingBox else { return nil }
        let size = simd_length(bb.max - bb.min)
        return try? shape.mesh(linearDeflection: max(0.005, size * 0.0008), angularDeflection: 0.25)
    }()

    public private(set) lazy var faceInfos: [FaceInfo?] = (0..<shape.faceCount).map { shape.faceInfo($0) }
    public private(set) lazy var edgeInfos: [EdgeInfo?] = (0..<shape.edgeCount).map { shape.edgeInfo($0) }

    public func faceRef(_ index: Int) -> FaceRef? {
        guard index < faceInfos.count, let f = faceInfos[index] else { return nil }
        var ref = FaceRef(index: index, centroid: f.centroid, normal: f.normal)
        ref.count = faceInfos.count
        return ref
    }

    public func edgeRef(_ index: Int) -> EdgeRef? {
        guard index < edgeInfos.count, let e = edgeInfos[index] else { return nil }
        var ref = EdgeRef(index: index, midpoint: e.midpoint)
        ref.count = edgeInfos.count
        ref.kind = e.kind.rawValue
        ref.direction = Self.direction(e)
        return ref
    }

    static func direction(_ e: EdgeInfo) -> Vec3? {
        guard e.kind == .line, simd_distance(e.start, e.end) > 1e-9 else { return nil }
        return simd_normalize(e.end - e.start)
    }

    static func sameDirection(_ a: Vec3?, _ b: Vec3?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(simd_dot(a, b)) > 0.999
    }

    public func resolve(_ ref: FaceRef) -> Int? {
        let infos = faceInfos
        if ref.index >= 0, ref.index < infos.count, let f = infos[ref.index],
           simd_distance(f.centroid, ref.centroid) < 1e-6, simd_dot(f.normal, ref.normal) > 0.999 {
            return ref.index
        }
        // Same topology (parameters changed sizes only): the index still names the same face.
        if ref.count == infos.count, ref.index >= 0, ref.index < infos.count, let f = infos[ref.index],
           simd_dot(f.normal, ref.normal) > 0.999 {
            return ref.index
        }
        var best: (Int, Double)?
        for case let f? in infos {
            let align = simd_dot(f.normal, ref.normal)
            // Prefer faces with the same orientation; penalize others heavily.
            let score = simd_distance(f.centroid, ref.centroid) + (align > 0.99 ? 0 : 1e6 * (2 - align))
            if best == nil || score < best!.1 { best = (f.index, score) }
        }
        return best?.0
    }

    public func resolve(_ ref: EdgeRef) -> Int? {
        let infos = edgeInfos
        if ref.index >= 0, ref.index < infos.count, let e = infos[ref.index], simd_distance(e.midpoint, ref.midpoint) < 1e-6 {
            return ref.index
        }
        if ref.count == infos.count, ref.index >= 0, ref.index < infos.count, let e = infos[ref.index],
           ref.kind == e.kind.rawValue, Self.sameDirection(ref.direction, Self.direction(e)) {
            return ref.index
        }
        var best: (Int, Double)?
        for case let e? in infos {
            let d = simd_distance(e.midpoint, ref.midpoint)
            if best == nil || d < best!.1 { best = (e.index, d) }
        }
        return best?.0
    }
}

/// A closed region of a sketch, usable as extrude/revolve profile.
public final class SketchRegion: @unchecked Sendable {
    public let index: Int
    public let face: Shape
    /// Point inside the region (sketch coordinates); used as a stable reference.
    public let sample: Vec2
    public let mesh: TriangleMesh?
    public let area: Double
    /// Visual center for handles and labels (sketch coordinates).
    public let center: Vec2

    init(index: Int, face: Shape, plane: Plane) {
        self.index = index
        self.face = face
        self.area = face.area
        let mesh = try? face.mesh(linearDeflection: 0.02, angularDeflection: 0.2)
        self.mesh = mesh
        var best = Vec2.zero
        var bestArea = -1.0
        if let m = mesh {
            for t in stride(from: 0, to: m.indices.count, by: 3) {
                let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
                let ar = Double(simd_length(simd_cross(b - a, c - a)))
                if ar > bestArea {
                    bestArea = ar
                    let centroid = (a + b + c) / 3
                    best = plane.project(Vec3(Double(centroid.x), Double(centroid.y), Double(centroid.z)))
                }
            }
        }
        self.sample = best
        // Prefer the true centroid as display anchor when it lies inside the region (not for rings).
        if let c = face.faceInfo(0)?.centroid, face.contains(c) {
            self.center = plane.project(c)
        } else {
            self.center = best
        }
    }
}

public struct SketchBuild: @unchecked Sendable {
    public var featureId: UUID
    public var plane: Plane
    public var sketch: Sketch
    public var solve: SolveResult
    public var regions: [SketchRegion]

    /// The region a profile reference names: the anchored point first (follows parameter changes),
    /// then the stored sample.
    public func resolve(_ ref: ProfileRef) -> SketchRegion? {
        if let a = ref.anchor?.position(in: sketch), let r = region(containing: a) { return r }
        return region(containing: ref.sample)
    }

    /// Reference to a region, anchored to the sketch points around it.
    public func profileRef(_ region: SketchRegion) -> ProfileRef {
        // Prefer the visual center when it is inside (more robust than the largest-triangle sample).
        let sample = self.region(containing: region.center) === region ? region.center : region.sample
        return ProfileRef(sketch: featureId, sample: sample, anchor: ProfileAnchor.make(for: sample, in: sketch))
    }

    public func region(containing p: Vec2) -> SketchRegion? {
        // Smallest region containing the point (nested profiles).
        regions.filter { $0.face.contains(plane.point(p)) }.min { $0.area < $1.area }
    }
}

/// The model state after applying a prefix of the timeline.
public struct ModelState: @unchecked Sendable {
    public var bodyOrder: [UUID] = []
    public var bodies: [UUID: BuiltBody] = [:]
    public var sketches: [UUID: SketchBuild] = [:]
    public var errors: [UUID: String] = [:]

    public init() {}

    public var orderedBodies: [BuiltBody] { bodyOrder.compactMap { bodies[$0] } }

    mutating func setBody(_ b: BuiltBody) {
        if bodies[b.id] == nil { bodyOrder.append(b.id) }
        bodies[b.id] = b
    }

    mutating func removeBody(_ id: UUID) {
        bodies[id] = nil
        bodyOrder.removeAll { $0 == id }
    }
}

/// Replays the feature timeline into geometry. Each prefix of the timeline is cached by content hash,
/// so editing the last feature (live preview) only recomputes that feature.
public final class ModelBuilder: @unchecked Sendable {
    private var cache: [Int: ModelState] = [:]
    private let lock = NSLock()

    public init() {}

    public func build(_ doc: CADDocument, upTo count: Int? = nil) -> ModelState {
        let n = min(count ?? doc.activeCount, doc.features.count)
        var evaluator = Evaluator(parameters: doc.parameters)
        var key: Int = {
            var h = Hasher()
            h.combine(doc.parameters)
            return h.finalize()
        }()
        var state = ModelState()
        var liveKeys: Set<Int> = []
        for i in 0..<n {
            let f = doc.features[i]
            var h = Hasher()
            h.combine(key)
            h.combine(f)
            key = h.finalize()
            liveKeys.insert(key)
            lock.lock()
            let cached = cache[key]
            lock.unlock()
            if let cached {
                state = cached
                continue
            }
            if !f.suppressed {
                apply(f, to: &state, evaluator: &evaluator)
            }
            lock.lock()
            cache[key] = state
            lock.unlock()
        }
        lock.lock()
        if cache.count > 400 { cache = cache.filter { liveKeys.contains($0.key) } }
        lock.unlock()
        return state
    }

    // MARK: Feature application

    func apply(_ f: Feature, to state: inout ModelState, evaluator: inout Evaluator) {
        do {
            switch f.kind {
            case let .sketch(sk):
                state.sketches[f.id] = try buildSketch(f.id, sk, state: state, evaluator: evaluator)
                if let sb = state.sketches[f.id], !sb.solve.converged {
                    state.errors[f.id] = "Skizze ist überbestimmt oder widersprüchlich"
                }
            case let .extrude(e):
                try applyExtrude(f, e, &state, &evaluator)
            case let .revolve(r):
                try applyRevolve(f, r, &state, &evaluator)
            case let .fillet(fi):
                let r = try evaluator.evaluate(fi.radius)
                try modifyEdges(fi.edges, &state, f.id) { try $0.filleted(edges: $1, radius: r) }
            case let .chamfer(c):
                let d = try evaluator.evaluate(c.distance)
                try modifyEdges(c.edges, &state, f.id) { try $0.chamfered(edges: $1, distance: d) }
            case let .shell(s):
                try applyShell(f, s, &state, &evaluator)
            case let .importStep(imp):
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("6axis-import-\(f.id).step")
                try imp.stepText.write(to: url, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: url) }
                let shape = try Shape.readSTEP(from: url)
                state.setBody(BuiltBody(id: f.id, shape: shape, sourceFeature: f.id))
            }
        } catch {
            state.errors[f.id] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    public func plane(for ref: PlaneRef, in state: ModelState) throws -> Plane {
        switch ref {
        case .xy: return .xy
        case .xz: return .xz
        case .yz: return .yz
        case let .face(bf):
            guard let body = state.bodies[bf.body], let idx = body.resolve(bf.face), let info = body.faceInfos[idx] else {
                throw KernelError("Skizzenebene nicht gefunden")
            }
            guard info.isPlanar else { throw KernelError("Skizzenebene ist nicht eben") }
            return Plane.forFace(point: info.origin, normal: info.normal)
        }
    }

    func buildSketch(_ id: UUID, _ sk: Sketch, state: ModelState, evaluator: Evaluator) throws -> SketchBuild {
        let plane = try self.plane(for: sk.plane, in: state)
        var solved = sk
        let result = SketchSolver(evaluator: evaluator).solve(&solved)
        let segments = solved.segments()
        var regions: [SketchRegion] = []
        if !segments.isEmpty {
            let compound = try Shape.sketchRegions(plane: plane, segments: segments)
            regions = compound.faces.enumerated().map { SketchRegion(index: $0.offset, face: $0.element, plane: plane) }
        }
        return SketchBuild(featureId: id, plane: plane, sketch: solved, solve: result, regions: regions)
    }

    /// Profile faces with their extrusion normal.
    func profileFaces(_ profiles: [ProfileRef], _ faces: [BodyFaceRef], _ state: ModelState) throws -> [(Shape, Vec3)] {
        var out: [(Shape, Vec3)] = []
        for p in profiles {
            guard let sb = state.sketches[p.sketch] else { throw KernelError("Skizze für Profil fehlt") }
            guard let region = sb.resolve(p) else { throw KernelError("Profil nicht mehr gefunden") }
            out.append((region.face, sb.plane.normal))
        }
        for fr in faces {
            guard let body = state.bodies[fr.body], let idx = body.resolve(fr.face), let info = body.faceInfos[idx] else {
                throw KernelError("Fläche nicht mehr gefunden")
            }
            guard info.isPlanar else { throw KernelError("Nur ebene Flächen können extrudiert werden") }
            out.append((try body.shape.face(idx), info.normal))
        }
        if out.isEmpty { throw KernelError("Kein Profil ausgewählt") }
        return out
    }

    func applyExtrude(_ f: Feature, _ e: ExtrudeFeature, _ state: inout ModelState, _ ev: inout Evaluator) throws {
        let d1 = try ev.evaluate(e.distance)
        let d2 = e.extent == .twoSides ? try ev.evaluate(e.distance2) : 0
        var tools: [Shape] = []
        for (face, n) in try profileFaces(e.profiles, e.faces, state) {
            switch e.extent {
            case .oneSide:
                tools.append(try face.extruded(n * d1))
            case .symmetric:
                tools.append(try face.translated(-n * d1 / 2).extruded(n * d1))
            case .twoSides:
                tools.append(try face.translated(-n * d2).extruded(n * (d1 + d2)))
            }
        }
        try combine(tools, op: e.operation, targets: e.targets, feature: f.id, &state)
    }

    func applyRevolve(_ f: Feature, _ r: RevolveFeature, _ state: inout ModelState, _ ev: inout Evaluator) throws {
        let angle = try ev.evaluate(r.angle, kind: .angle) * .pi / 180
        guard let axisRef = r.axis else { throw KernelError("Keine Drehachse gewählt") }
        let (o, dir) = try axis(axisRef, state)
        let tools = try profileFaces(r.profiles, [], state).map { try $0.0.revolved(origin: o, axis: dir, angle: angle) }
        try combine(tools, op: r.operation, targets: r.targets, feature: f.id, &state)
    }

    public func axis(_ ref: AxisRef, _ state: ModelState) throws -> (Vec3, Vec3) {
        switch ref {
        case .x: return (.zero, Vec3(1, 0, 0))
        case .y: return (.zero, Vec3(0, 1, 0))
        case .z: return (.zero, Vec3(0, 0, 1))
        case let .sketchLine(sid, cid):
            guard let sb = state.sketches[sid], let c = sb.sketch.curve(cid), case let .line(a, b) = c.geometry,
                  let pa = sb.sketch.point(a), let pb = sb.sketch.point(b), simd_distance(pa, pb) > 1e-9 else {
                throw KernelError("Drehachse nicht gefunden")
            }
            let p0 = sb.plane.point(pa), p1 = sb.plane.point(pb)
            return (p0, simd_normalize(p1 - p0))
        case let .edge(be):
            guard let body = state.bodies[be.body], let idx = body.resolve(be.edge), let info = body.edgeInfos[idx],
                  info.kind == .line else { throw KernelError("Drehachse muss eine gerade Kante sein") }
            return (info.start, simd_normalize(info.end - info.start))
        }
    }

    func combine(_ tools: [Shape], op: BodyOperation, targets: [UUID], feature: UUID, _ state: inout ModelState) throws {
        guard !tools.isEmpty else { throw KernelError("Keine Geometrie erzeugt") }
        var tool = tools[0]
        for t in tools.dropFirst() { tool = try tool.boolean(.fuse, t) }

        func overlapping() -> [UUID] {
            guard let tb = tool.boundingBox else { return [] }
            return state.bodyOrder.filter { id in
                guard let bb = state.bodies[id]?.shape.boundingBox else { return false }
                let eps = 1e-6
                return !(bb.max.x < tb.min.x - eps || bb.min.x > tb.max.x + eps ||
                         bb.max.y < tb.min.y - eps || bb.min.y > tb.max.y + eps ||
                         bb.max.z < tb.min.z - eps || bb.min.z > tb.max.z + eps)
            }
        }
        let chosen = targets.isEmpty ? overlapping() : targets.filter { state.bodies[$0] != nil }

        switch op {
        case .newBody:
            state.setBody(BuiltBody(id: feature, shape: tool, sourceFeature: feature))
        case .join:
            guard let first = chosen.first, let base = state.bodies[first] else {
                state.setBody(BuiltBody(id: feature, shape: tool, sourceFeature: feature))
                return
            }
            var result = try base.shape.boolean(.fuse, tool)
            for other in chosen.dropFirst() {
                if let b = state.bodies[other] {
                    result = try result.boolean(.fuse, b.shape)
                    state.removeBody(other)
                }
            }
            state.setBody(BuiltBody(id: first, shape: result, sourceFeature: feature))
        case .cut:
            guard !chosen.isEmpty else { throw KernelError("Kein Körper zum Ausschneiden getroffen") }
            for id in chosen {
                guard let b = state.bodies[id] else { continue }
                let r = try b.shape.boolean(.cut, tool)
                if r.solidCount == 0 { state.removeBody(id) } else { state.setBody(BuiltBody(id: id, shape: r, sourceFeature: feature)) }
            }
        case .intersect:
            guard !chosen.isEmpty else { throw KernelError("Kein Körper zum Schneiden getroffen") }
            for id in chosen {
                guard let b = state.bodies[id] else { continue }
                let r = try b.shape.boolean(.common, tool)
                if r.solidCount == 0 { state.removeBody(id) } else { state.setBody(BuiltBody(id: id, shape: r, sourceFeature: feature)) }
            }
        }
    }

    func modifyEdges(_ edges: [BodyEdgeRef], _ state: inout ModelState, _ feature: UUID,
                     _ op: (Shape, [Int]) throws -> Shape) throws {
        guard !edges.isEmpty else { throw KernelError("Keine Kanten ausgewählt") }
        let byBody = Dictionary(grouping: edges, by: \.body)
        for (bodyId, refs) in byBody {
            guard let body = state.bodies[bodyId] else { throw KernelError("Körper nicht mehr vorhanden") }
            let idx = Array(Set(refs.compactMap { body.resolve($0.edge) })).sorted()
            guard !idx.isEmpty else { throw KernelError("Kanten nicht mehr gefunden") }
            state.setBody(BuiltBody(id: bodyId, shape: try op(body.shape, idx), sourceFeature: feature))
        }
    }

    func applyShell(_ f: Feature, _ s: ShellFeature, _ state: inout ModelState, _ ev: inout Evaluator) throws {
        let t = try ev.evaluate(s.thickness)
        var byBody = Dictionary(grouping: s.faces, by: \.body).mapValues { $0.map(\.face) }
        if byBody.isEmpty, let b = s.body { byBody[b] = [] }
        guard !byBody.isEmpty else { throw KernelError("Keine Fläche oder kein Körper ausgewählt") }
        for (bodyId, refs) in byBody {
            guard let body = state.bodies[bodyId] else { throw KernelError("Körper nicht mehr vorhanden") }
            let idx = Array(Set(refs.compactMap { body.resolve($0) })).sorted()
            state.setBody(BuiltBody(id: bodyId, shape: try body.shape.shelled(removing: idx, thickness: t), sourceFeature: f.id))
        }
    }
}
