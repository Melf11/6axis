import AppKit
import Foundation
import simd
import SixAxisCore

extension Editor {
    var commandFeature: Feature? { command?.featureId.flatMap { doc.feature($0) } }

    /// Model state just before the command's feature (cached by the builder, so cheap).
    var stateBeforeCommand: ModelState {
        guard let id = command?.featureId, let idx = doc.index(of: id) else { return state }
        return builder.build(doc, upTo: idx)
    }

    /// Error of the command's feature – not before the user gave the inputs a fresh command needs.
    var commandError: String? {
        guard let cmd = command, let f = commandFeature else { return nil }
        if cmd.isNew && !hasInputs(f) { return nil }
        return state.errors[f.id]
    }

    // MARK: - Begin / end

    func beginCommand(_ kind: CommandKind, editing: UUID? = nil, pendingTool: SketchTool? = nil) {
        if command != nil { commitCommand() }
        // Features are edited on the assembled model.
        if explode > 0 { explode = 0 }
        if sketchId != nil { finishSketch() }
        let snapshot = doc

        if kind == .sketchPlane {
            command = ActiveCommand(kind: kind, featureId: nil, isNew: true, snapshot: snapshot, pendingTool: pendingTool)
            // Pre-selected plane or face: create immediately.
            if let p = selection.first, let ref = planeRef(for: p) {
                selection.removeAll()
                beginSketch(on: ref, tool: pendingTool)
                return
            }
            selection.removeAll()
            sceneVersion &+= 1
            requestRedraw()
            return
        }

        if let editing, let idx = doc.index(of: editing) {
            doc.rollback = idx + 1 == doc.features.count ? nil : idx + 1
            command = ActiveCommand(kind: kind, featureId: editing, isNew: false, snapshot: snapshot)
            selection.removeAll()
            rebuild()
            return
        }

        let featureKind: FeatureKind
        switch kind {
        case .extrude:
            var e = ExtrudeFeature()
            e.profiles = selectedProfiles()
            e.faces = selectedPlanarFaces()
            if e.profiles.isEmpty && e.faces.isEmpty, let auto = singleProfileOfLatestSketch() { e.profiles = [auto] }
            e.operation = state.bodyOrder.isEmpty ? .newBody : (e.faces.isEmpty ? .newBody : .join)
            featureKind = .extrude(e)
        case .revolve:
            var r = RevolveFeature()
            r.profiles = selectedProfiles()
            if r.profiles.isEmpty, let auto = singleProfileOfLatestSketch() { r.profiles = [auto] }
            r.axis = selection.compactMap { axisRef(for: $0) }.first
            r.operation = state.bodyOrder.isEmpty ? .newBody : .join
            featureKind = .revolve(r)
        case .fillet:
            var f = FilletFeature()
            f.edges = selectedEdges()
            featureKind = .fillet(f)
        case .chamfer:
            var c = ChamferFeature()
            c.edges = selectedEdges()
            featureKind = .chamfer(c)
        case .shell:
            var s = ShellFeature()
            s.faces = selection.compactMap { p -> BodyFaceRef? in
                guard case let .face(b, i) = p, let ref = state.bodies[b]?.faceRef(i) else { return nil }
                return BodyFaceRef(body: b, face: ref)
            }
            if s.faces.isEmpty { s.body = selection.compactMap(\.bodyId).first ?? (state.bodyOrder.count == 1 ? state.bodyOrder.first : nil) }
            featureKind = .shell(s)
        case .sketchPlane:
            return
        default:
            guard let k = makeModellingFeature(kind) else { return }
            featureKind = k
        }

        let f = Feature(name: doc.nextName(for: featureKind), kind: featureKind)
        let at = doc.activeCount
        doc.features.insert(f, at: at)
        if let r = doc.rollback { doc.rollback = r + 1 }
        var cmd = ActiveCommand(kind: kind, featureId: f.id, isNew: true, snapshot: snapshot)
        if kind == .revolve, case let .revolve(r) = featureKind, !r.profiles.isEmpty, r.axis == nil { cmd.activeInput = 1 }
        if makeModellingFeature(kind) != nil { cmd.activeInput = firstInput(featureKind) }
        command = cmd
        selection.removeAll()
        rebuild()
    }

    func commitCommand() {
        guard let cmd = command else { return }
        if cmd.kind == .sketchPlane {
            command = nil
            sceneVersion &+= 1
            requestRedraw()
            return
        }
        guard let id = cmd.featureId, let f = doc.feature(id) else { command = nil; return }
        if cmd.isNew && !hasInputs(f) {
            cancelCommand()
            return
        }
        // Restore the timeline marker that was active before editing.
        if !cmd.isNew { doc.rollback = cmd.snapshot.rollback }
        // Like Fusion: consumed sketches are hidden after the feature is created.
        if cmd.isNew {
            switch f.kind {
            case let .extrude(e): for p in e.profiles { doc.hiddenSketches.insert(p.sketch) }
            case let .revolve(r): for p in r.profiles { doc.hiddenSketches.insert(p.sketch) }
            case let .hole(h):
                for case let .sketchPoint(s, _) in h.points { doc.hiddenSketches.insert(s) }
            default: break
            }
        }
        command = nil
        pushUndo(cmd.snapshot)
        rebuild()
        if let err = state.errors[id] { showToast(String(localized: "\(f.name): \(err)")) }
    }

    func cancelCommand() {
        guard let cmd = command else { return }
        doc = cmd.snapshot
        command = nil
        rebuild()
    }

    func hasInputs(_ f: Feature) -> Bool {
        switch f.kind {
        case let .extrude(e): return !e.profiles.isEmpty || !e.faces.isEmpty
        case let .revolve(r): return !r.profiles.isEmpty
        case let .fillet(x): return !x.edges.isEmpty
        case let .chamfer(x): return !x.edges.isEmpty
        case let .shell(x): return !x.faces.isEmpty || x.body != nil
        default: return hasModellingInputs(f.kind)
        }
    }

    /// Live-updates the command's feature (no undo step; the whole command is one step).
    func updateCommandFeature(_ change: (inout FeatureKind) -> Void) {
        // Copy out first: `change` may read the document (e.g. the pre-command state).
        guard let id = command?.featureId, var kind = doc.feature(id)?.kind else { return }
        change(&kind)
        doc.update(id) { $0.kind = kind }
        rebuild()
    }

    // MARK: - Selection helpers

    func selectedProfiles() -> [ProfileRef] {
        selection.compactMap { p in
            guard case let .profile(sid, idx) = p, let sb = state.sketches[sid], idx < sb.regions.count else { return nil }
            return sb.profileRef(sb.regions[idx])
        }
    }

    func selectedPlanarFaces() -> [BodyFaceRef] {
        selection.compactMap { p in
            guard case let .face(b, i) = p, let body = state.bodies[b], body.faceInfo(at: i)?.isPlanar == true,
                  let ref = body.faceRef(i) else { return nil }
            return BodyFaceRef(body: b, face: ref)
        }
    }

    func selectedEdges() -> [BodyEdgeRef] {
        selection.compactMap { p in
            guard case let .edge(b, i) = p, let ref = state.bodies[b]?.edgeRef(i) else { return nil }
            return BodyEdgeRef(body: b, edge: ref)
        }
    }

    func singleProfileOfLatestSketch() -> ProfileRef? {
        for f in doc.features.prefix(doc.activeCount).reversed() {
            if case .sketch = f.kind, let sb = state.sketches[f.id] {
                return sb.regions.count == 1 ? sb.profileRef(sb.regions[0]) : nil
            }
        }
        return nil
    }

    func planeRef(for pick: Pick) -> PlaneRef? {
        switch pick {
        case let .originPlane(ref): return ref
        case let .face(b, i):
            guard let body = state.bodies[b], body.faceInfo(at: i)?.isPlanar == true, let ref = body.faceRef(i) else { return nil }
            return .face(BodyFaceRef(body: b, face: ref))
        default: return nil
        }
    }

    func axisRef(for pick: Pick) -> AxisRef? {
        switch pick {
        case let .originAxis(a): return a
        case let .sketchCurve(sid, cid):
            guard state.sketches[sid]?.sketch.curve(cid)?.isLine == true else { return nil }
            return .sketchLine(sketch: sid, curve: cid)
        case let .edge(b, i):
            // Straight edges, and circular edges standing for their axis (rim of a hole or bolt).
            guard let body = state.bodies[b], let info = body.edgeInfo(at: i), info.kind == .line || info.kind == .circle,
                  let ref = body.edgeRef(i) else { return nil }
            return .edge(BodyEdgeRef(body: b, edge: ref))
        case .face:
            return cylinderFace(pick, in: state).map { .cylinder($0) }
        default: return nil
        }
    }

    // MARK: - Picks while a command is active

    /// Which picks the current mode accepts for hover/click.
    func accepts(_ p: Pick) -> Bool {
        if let sid = sketchId {
            switch p {
            case let .sketchPoint(s, _), let .sketchCurve(s, _), let .constraint(s, _): return s == sid
            case .edge, .face: return sketchTool == .project
            default: return false
            }
        }
        guard let cmd = command else {
            if workspace == .cam {
                if camEdit != nil { return acceptsCAMPick(p) }
                if case .face = p { return true }
                return false
            }
            if measuring {
                switch p { case .face, .edge: return true; default: return false }
            }
            switch p {
            case .face, .edge, .profile, .sketchCurve, .originPlane(.construction): return true
            default: return false
            }
        }
        switch cmd.kind {
        case .sketchPlane:
            if case .originPlane = p { return true }
            if case .face = p { return planeRef(for: p) != nil }
            return false
        case .extrude:
            if case .profile = p { return true }
            if case let .face(b, i) = p { return state.bodies[b]?.faceInfo(at: i)?.isPlanar == true }
            return false
        case .revolve:
            if cmd.activeInput == 1 { return axisRef(for: p) != nil }
            if case .profile = p { return true }
            return false
        case .fillet, .chamfer:
            if case .edge = p { return true }
            return false
        case .shell:
            if case .face = p { return true }
            return false
        default:
            return acceptsModelling(p)
        }
    }

    func commandClick(_ p: Pick) {
        guard let cmd = command else { return }
        switch cmd.kind {
        case .sketchPlane:
            if let ref = planeRef(for: p) { beginSketch(on: ref, tool: cmd.pendingTool) }
        case .extrude:
            updateCommandFeature { k in
                guard case var .extrude(e) = k else { return }
                toggleProfile(p, in: &e.profiles)
                if case let .face(b, i) = p, let ref = state.bodies[b]?.faceRef(i) {
                    let r = BodyFaceRef(body: b, face: ref)
                    if let j = e.faces.firstIndex(where: { $0.body == b && $0.face.index == i }) { e.faces.remove(at: j) } else { e.faces.append(r) }
                }
                k = .extrude(e)
            }
        case .revolve:
            updateCommandFeature { k in
                guard case var .revolve(r) = k else { return }
                if cmd.activeInput == 1 {
                    r.axis = axisRef(for: p)
                } else {
                    toggleProfile(p, in: &r.profiles)
                }
                k = .revolve(r)
            }
            if cmd.activeInput == 0, case .revolve(let r)? = commandFeature?.kind, r.axis == nil { command?.activeInput = 1 }
        case .fillet, .chamfer:
            guard case let .edge(b, i) = p else { return }
            let pre = stateBeforeCommand
            guard let mid = state.bodies[b]?.edgeInfo(at: i)?.midpoint, let preBody = pre.bodies[b],
                  let preIdx = preBody.resolve(EdgeRef(index: -1, midpoint: mid)), let ref = preBody.edgeRef(preIdx) else { return }
            updateCommandFeature { k in
                func toggle(_ edges: inout [BodyEdgeRef]) {
                    if let j = edges.firstIndex(where: { $0.body == b && preBody.resolve($0.edge) == preIdx }) {
                        edges.remove(at: j)
                    } else {
                        edges.append(BodyEdgeRef(body: b, edge: ref))
                    }
                }
                if case var .fillet(f) = k { toggle(&f.edges); k = .fillet(f) }
                if case var .chamfer(c) = k { toggle(&c.edges); k = .chamfer(c) }
            }
        case .shell:
            guard case let .face(b, i) = p else { return }
            let pre = stateBeforeCommand
            guard let info = state.bodies[b]?.faceInfo(at: i), let preBody = pre.bodies[b],
                  let preIdx = preBody.resolve(FaceRef(index: -1, centroid: info.centroid, normal: info.normal)),
                  let ref = preBody.faceRef(preIdx) else { return }
            updateCommandFeature { k in
                guard case var .shell(s) = k else { return }
                if let j = s.faces.firstIndex(where: { $0.body == b && preBody.resolve($0.face) == preIdx }) {
                    s.faces.remove(at: j)
                } else {
                    s.faces.append(BodyFaceRef(body: b, face: ref))
                }
                s.body = s.faces.isEmpty ? b : nil
                k = .shell(s)
            }
        default:
            modellingClick(p)
        }
    }

    private func toggleProfile(_ p: Pick, in profiles: inout [ProfileRef]) {
        guard case let .profile(sid, idx) = p, let sb = stateBeforeCommand.sketches[sid] ?? state.sketches[sid], idx < sb.regions.count else { return }
        let region = sb.regions[idx]
        if let j = profiles.firstIndex(where: { $0.sketch == sid && sb.resolve($0) === region }) {
            profiles.remove(at: j)
        } else {
            profiles.append(sb.profileRef(region))
        }
    }

    // MARK: - Extrude manipulator

    /// Anchor, direction and current distance for the on-canvas extrude arrow.
    var extrudeHandle: (origin: Vec3, direction: Vec3, distance: Double)? {
        guard let cmd = command, cmd.kind == .extrude, case let .extrude(e)? = commandFeature?.kind else { return nil }
        let pre = stateBeforeCommand
        var origin: Vec3?
        var normal: Vec3?
        if let p = e.profiles.first, let sb = pre.sketches[p.sketch] {
            origin = sb.plane.point(sb.resolve(p)?.center ?? p.sample)
            normal = sb.plane.normal
        } else if let f = e.faces.first, let body = pre.bodies[f.body], let idx = body.resolve(f.face), let info = body.faceInfos[idx] {
            origin = info.centroid
            normal = info.normal
        }
        guard let origin, let normal else { return nil }
        let d = (try? evaluator.value(e.distance)) ?? 0
        let base = e.extent == .symmetric ? origin - normal * d / 2 : origin
        return (base, normal, d)
    }

    func setExtrudeDistance(_ d: Double) {
        updateCommandFeature { k in
            guard case var .extrude(e) = k else { return }
            e.distance = plainNumber(d)
            // Pushing into existing material switches to cut automatically (like Fusion).
            if !e.faces.isEmpty || !state.bodyOrder.isEmpty {
                if d < 0, e.operation == .join { e.operation = .cut }
                if d > 0, e.operation == .cut, !e.faces.isEmpty { e.operation = .join }
            }
            k = .extrude(e)
        }
    }

    // MARK: - Dragging along a line

    /// Position along the line through `origin` that is closest to the mouse ray at a screen point.
    func dragParameter(at pt: CGPoint, origin: Vec3, direction D: Vec3) -> Double? {
        let r = camera.rayD(at: pt)
        let w0 = origin - r.origin
        let b = simd_dot(D, r.direction), d = simd_dot(D, w0), ee = simd_dot(r.direction, w0)
        let den = 1 - b * b
        guard abs(den) > 1e-6 else { return nil }
        return (b * ee - d) / den
    }

    /// Snap step for dragged values that fits the zoom (1 mm, 10 mm, 0.1 mm …).
    var dragStep: Double { pow(10, floor(log10(Double(camera.worldPerPoint) * 8))) }

    // MARK: - Hole manipulator

    /// A hole position on a face with its arrows along the face's own X and Y.
    struct HoleHandle {
        var index: Int
        var center: Vec3
        var axes: [Vec3]
        /// Current distances from the face's corner (the dialog's "X/Y ab Kante").
        var offsets: [Double]
    }

    /// Arrows for every hole position given by distances on a face.
    var holeHandles: [HoleHandle] {
        guard let cmd = command, cmd.kind == .hole, case let .hole(h)? = commandFeature?.kind else { return [] }
        let pre = stateBeforeCommand
        return h.points.enumerated().compactMap { i, pt in
            guard case let .faceOffset(bf, x, y) = pt, let body = pre.bodies[bf.body], let idx = body.resolve(bf.face),
                  let frame = FaceFrame.of(body, face: idx),
                  let xv = try? evaluator.value(x), let yv = try? evaluator.value(y) else { return nil }
            return HoleHandle(index: i, center: frame.point(xv, yv), axes: [frame.plane.xDir, frame.plane.yDir], offsets: [xv, yv])
        }
    }

    /// Arrow length in the model, constant on screen.
    var arrowLength: Double { Double(camera.worldPerPoint) * 45 }

    /// New distance from the edge when an arrow of `h` is dragged from `from` to `to`.
    func holeOffset(_ h: HoleHandle, axis: Int, from: CGPoint, to: CGPoint) -> Double? {
        guard let t0 = dragParameter(at: from, origin: h.center, direction: h.axes[axis]),
              let t = dragParameter(at: to, origin: h.center, direction: h.axes[axis]) else { return nil }
        let step = dragStep
        return ((h.offsets[axis] + t - t0) / step).rounded() * step
    }

    func setHoleOffset(_ i: Int, axis: Int, _ v: Double) {
        updateCommandFeature { k in
            guard case var .hole(h) = k, h.points.indices.contains(i), case let .faceOffset(r, x, y) = h.points[i] else { return }
            h.points[i] = axis == 0 ? .faceOffset(r, x: plainNumber(v), y: y) : .faceOffset(r, x: x, y: plainNumber(v))
            k = .hole(h)
        }
    }

    // MARK: - Fillet / chamfer manipulator

    /// Arrow on the first chosen edge, pointing out of the corner along the bisector of the two faces.
    struct EdgeHandle {
        /// Middle of the rounded or chamfered surface (the arrow's base).
        var center: Vec3
        var direction: Vec3
        /// Current radius or chamfer distance.
        var value: Double
        /// How far the surface's middle moves along `direction` per millimetre of `value`.
        var scale: Double
    }

    var edgeHandle: EdgeHandle? {
        guard let cmd = command, cmd.kind == .fillet || cmd.kind == .chamfer, let kind = commandFeature?.kind else { return nil }
        let edges: [BodyEdgeRef], expr: String
        switch kind {
        case let .fillet(f): (edges, expr) = (f.edges, f.radius)
        case let .chamfer(c): (edges, expr) = (c.edges, c.distance)
        default: return nil
        }
        guard let e = edges.first, let body = stateBeforeCommand.bodies[e.body], let idx = body.resolve(e.edge),
              let mid = body.edgeInfo(at: idx)?.midpoint else { return nil }
        let normals = body.edgeFaceNormals(idx)
        guard let n0 = normals.first else { return nil }
        let value = (try? evaluator.value(expr)) ?? 0
        var dir = n0, scale = 1.0
        if normals.count >= 2, simd_length(n0 + normals[1]) > 1e-6 {
            dir = simd_normalize(n0 + normals[1])
            // Half the angle between the normals: 45° at a right-angled corner.
            // Fillet: the surface's middle lies r·(1 − cos)/cos inside the corner; chamfer: d·sin.
            let c: Double = min(1, max(0, simd_dot(n0, dir)))
            scale = cmd.kind == .fillet ? (1 - c) / max(c, 1e-6) : (1 - c * c).squareRoot()
            if scale < 0.1 { scale = 1 }
        }
        return EdgeHandle(center: mid - dir * value * scale, direction: dir, value: value, scale: scale)
    }

    /// New radius or distance when the arrow of `h` is dragged from `from` to `to` (dragging into the corner makes it larger).
    func edgeValue(_ h: EdgeHandle, from: CGPoint, to: CGPoint) -> Double? {
        guard let t0 = dragParameter(at: from, origin: h.center, direction: h.direction),
              let t = dragParameter(at: to, origin: h.center, direction: h.direction) else { return nil }
        let step = dragStep
        return max(step, ((h.value + (t0 - t) / h.scale) / step).rounded() * step)
    }

    func setEdgeValue(_ v: Double) {
        updateCommandFeature { k in
            if case var .fillet(f) = k { f.radius = plainNumber(v); k = .fillet(f) }
            if case var .chamfer(c) = k { c.distance = plainNumber(v); k = .chamfer(c) }
        }
    }

    // MARK: - Move manipulator

    /// Arrows along X/Y/Z and rings to turn the bodies of a move, like Fusion's manipulator.
    struct MoveHandle {
        /// Centre of the moved bodies (where the arrows start).
        var center: Vec3
        /// Current dx, dy, dz.
        var offsets: [Double]
        var angle: Double
        /// Rings: X, Y, Z of an origin axis, or the single picked axis. `active` is the one that turns now.
        var rings: [MoveRing]
    }

    struct MoveRing {
        var axis: AxisRef
        var center: Vec3
        var direction: Vec3
        /// Direction in the ring's plane where the knob sits at 0°.
        var start: Vec3
        var active: Bool
    }

    static let moveAxes: [Vec3] = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]

    var moveHandle: MoveHandle? {
        guard let cmd = command, cmd.kind == .move, case let .move(m)? = commandFeature?.kind else { return nil }
        let pre = stateBeforeCommand
        let ev = evaluator
        guard let c0 = pre.center(of: m.bodies), let dx = try? ev.value(m.dx), let dy = try? ev.value(m.dy),
              let dz = try? ev.value(m.dz) else { return nil }
        let angle = (try? ev.value(m.angle, kind: .angle)) ?? 0
        let t = Vec3(dx, dy, dz)
        var r = matrix_identity_double3x3, o = c0
        var turn: (origin: Vec3, direction: Vec3)?
        if let a = m.axis, let line = try? builder.axis(a, pre) {
            o = m.turnsAboutCenter ? c0 : line.0
            r = rotationMatrix(axis: line.1, angle: angle * .pi / 180)
            turn = (o + t, line.1)
        }
        let center = r * (c0 - o) + o + t
        func ring(_ a: AxisRef, _ dir: Vec3, through p: Vec3, active: Bool) -> MoveRing {
            // Ring centre: the point of the axis closest to the bodies.
            let c = p + dir * simd_dot(center - p, dir)
            let other = abs(dir.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let start = simd_normalize(simd_cross(other, dir))
            return MoveRing(axis: a, center: c, direction: dir, start: start, active: active)
        }
        var rings: [MoveRing] = []
        let origin: [AxisRef] = [.x, .y, .z]
        if let a = m.axis, !origin.contains(a), let turn {
            rings = [ring(a, turn.direction, through: turn.origin, active: true)]
        } else {
            // Once turned, only the ring of that axis stays (a move holds one turn).
            for (i, a) in origin.enumerated() where abs(angle) < 1e-9 || m.axis == a {
                rings.append(ring(a, Self.moveAxes[i], through: m.axis == a ? (turn?.origin ?? center) : center, active: m.axis == a))
            }
        }
        return MoveHandle(center: center, offsets: [dx, dy, dz], angle: angle, rings: rings)
    }

    /// Arrow length and ring radius in the model, constant on screen.
    var moveArrowLength: Double { Double(camera.worldPerPoint) * 70 }
    var moveRingRadius: Double { Double(camera.worldPerPoint) * 50 }

    /// Knob position on a ring for the current angle.
    func moveKnob(_ h: MoveHandle, _ ring: MoveRing) -> Vec3 {
        let a = ring.active ? h.angle * .pi / 180 : 0
        return ring.center + rotationMatrix(axis: ring.direction, angle: a) * ring.start * moveRingRadius
    }

    /// New dx/dy/dz when the arrow along `axis` is dragged from `from` to `to`.
    func moveOffset(_ h: MoveHandle, axis: Int, from: CGPoint, to: CGPoint) -> Double? {
        let d = Self.moveAxes[axis]
        guard let t0 = dragParameter(at: from, origin: h.center, direction: d),
              let t = dragParameter(at: to, origin: h.center, direction: d) else { return nil }
        let step = dragStep
        return ((h.offsets[axis] + t - t0) / step).rounded() * step
    }

    func setMoveOffset(axis: Int, _ v: Double) {
        updateCommandFeature { k in
            guard case var .move(m) = k else { return }
            switch axis {
            case 0: m.dx = plainNumber(v)
            case 1: m.dy = plainNumber(v)
            default: m.dz = plainNumber(v)
            }
            k = .move(m)
        }
    }

    /// New angle when the knob of `ring` is dragged from `from` to `to` (5° steps, ⇧ for 1°).
    func moveAngle(_ h: MoveHandle, _ ring: MoveRing, from: CGPoint, to: CGPoint, fine: Bool = false) -> Double? {
        func onPlane(_ pt: CGPoint) -> Vec3? {
            let r = camera.rayD(at: pt)
            let den = simd_dot(r.direction, ring.direction)
            guard abs(den) > 1e-6 else { return nil }
            let p = r.origin + r.direction * (simd_dot(ring.center - r.origin, ring.direction) / den)
            let v = p - ring.center
            return simd_length(v) > 1e-9 ? v : nil
        }
        guard let a = onPlane(from), let b = onPlane(to) else { return nil }
        let delta = atan2(simd_dot(simd_cross(a, b), ring.direction), simd_dot(a, b)) * 180 / .pi
        let step = fine ? 1.0 : 5.0
        return (((ring.active ? h.angle : 0) + delta) / step).rounded() * step
    }

    func setMoveAngle(_ ring: MoveRing, _ v: Double) {
        updateCommandFeature { k in
            guard case var .move(m) = k else { return }
            m.axis = ring.axis
            m.angle = plainNumber(v)
            k = .move(m)
        }
    }
}
