import AppKit
import Foundation
import simd
import VibeCore

extension Editor {
    var commandFeature: Feature? { command?.featureId.flatMap { doc.feature($0) } }

    /// Model state just before the command's feature (cached by the builder, so cheap).
    var stateBeforeCommand: ModelState {
        guard let id = command?.featureId, let idx = doc.index(of: id) else { return state }
        return builder.build(doc, upTo: idx)
    }

    var commandError: String? { command?.featureId.flatMap { state.errors[$0] } }

    // MARK: - Begin / end

    func beginCommand(_ kind: CommandKind, editing: UUID? = nil, pendingTool: SketchTool? = nil) {
        if command != nil { commitCommand() }
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
        }

        let f = Feature(name: doc.nextName(for: featureKind), kind: featureKind)
        let at = doc.activeCount
        doc.features.insert(f, at: at)
        if let r = doc.rollback { doc.rollback = r + 1 }
        var cmd = ActiveCommand(kind: kind, featureId: f.id, isNew: true, snapshot: snapshot)
        if kind == .revolve, case let .revolve(r) = featureKind, !r.profiles.isEmpty, r.axis == nil { cmd.activeInput = 1 }
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
            default: break
            }
        }
        command = nil
        pushUndo(cmd.snapshot)
        rebuild()
        if let err = state.errors[id] { showToast("\(f.name): \(err)") }
    }

    func cancelCommand() {
        guard let cmd = command else { return }
        doc = cmd.snapshot
        command = nil
        rebuild()
    }

    private func hasInputs(_ f: Feature) -> Bool {
        switch f.kind {
        case let .extrude(e): return !e.profiles.isEmpty || !e.faces.isEmpty
        case let .revolve(r): return !r.profiles.isEmpty
        case let .fillet(x): return !x.edges.isEmpty
        case let .chamfer(x): return !x.edges.isEmpty
        case let .shell(x): return !x.faces.isEmpty || x.body != nil
        default: return true
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
            return ProfileRef(sketch: sid, sample: sb.regions[idx].sample)
        }
    }

    func selectedPlanarFaces() -> [BodyFaceRef] {
        selection.compactMap { p in
            guard case let .face(b, i) = p, let body = state.bodies[b], body.faceInfos[i]?.isPlanar == true,
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
                return sb.regions.count == 1 ? ProfileRef(sketch: f.id, sample: sb.regions[0].sample) : nil
            }
        }
        return nil
    }

    func planeRef(for pick: Pick) -> PlaneRef? {
        switch pick {
        case let .originPlane(ref): return ref
        case let .face(b, i):
            guard let body = state.bodies[b], body.faceInfos[i]?.isPlanar == true, let ref = body.faceRef(i) else { return nil }
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
            guard let body = state.bodies[b], body.edgeInfos[i]?.kind == .line, let ref = body.edgeRef(i) else { return nil }
            return .edge(BodyEdgeRef(body: b, edge: ref))
        default: return nil
        }
    }

    // MARK: - Picks while a command is active

    /// Which picks the current mode accepts for hover/click.
    func accepts(_ p: Pick) -> Bool {
        if let sid = sketchId {
            switch p {
            case let .sketchPoint(s, _), let .sketchCurve(s, _), let .constraint(s, _): return s == sid
            default: return false
            }
        }
        guard let cmd = command else {
            switch p {
            case .face, .edge, .profile, .sketchCurve: return true
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
            if case let .face(b, i) = p { return state.bodies[b]?.faceInfos[i]?.isPlanar == true }
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
            guard let mid = state.bodies[b]?.edgeInfos[i]?.midpoint, let preBody = pre.bodies[b],
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
            guard let info = state.bodies[b]?.faceInfos[i], let preBody = pre.bodies[b],
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
        }
    }

    private func toggleProfile(_ p: Pick, in profiles: inout [ProfileRef]) {
        guard case let .profile(sid, idx) = p, let sb = stateBeforeCommand.sketches[sid] ?? state.sketches[sid], idx < sb.regions.count else { return }
        let region = sb.regions[idx]
        if let j = profiles.firstIndex(where: { $0.sketch == sid && sb.region(containing: $0.sample) === region }) {
            profiles.remove(at: j)
        } else {
            profiles.append(ProfileRef(sketch: sid, sample: region.sample))
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
            origin = sb.plane.point(sb.region(containing: p.sample)?.center ?? p.sample)
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
}
