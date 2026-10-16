import AppKit
import Foundation
import simd
import SixAxisCore

/// Commands of 1.2 "Modellieren": construction planes and axes, holes, threads, patterns, move and combine.
/// Inputs are numbered (`ActiveCommand.activeInput`); the dialog shows which one receives clicks.
extension Editor {
    /// Construction plane with a preset mode (from the toolbar menu).
    func beginPlane(_ mode: ConstructionPlaneMode) {
        beginCommand(.plane)
        updateCommandFeature { k in if case var .plane(p) = k { p.mode = mode; k = .plane(p) } }
    }

    // MARK: - New features from the current selection

    func makeModellingFeature(_ kind: CommandKind) -> FeatureKind? {
        let bodies = selectedBodies()
        switch kind {
        case .plane:
            var p = ConstructionPlaneFeature()
            p.plane = selection.compactMap { planeRef(for: $0) }.first
            return .plane(p)
        case .axis:
            var a = ConstructionAxisFeature()
            a.axis = selection.compactMap { axisRef(for: $0) }.first
            return .axis(a)
        case .hole:
            var h = HoleFeature()
            h.points = selection.compactMap { p in
                guard case let .sketchPoint(s, i) = p else { return nil }
                return .sketchPoint(sketch: s, point: i)
            }
            return .hole(h)
        case .thread:
            var t = ThreadFeature()
            t.faces = selection.compactMap { cylinderFace($0, in: state) }
            return .thread(t)
        case .rectPattern, .circularPattern, .mirror:
            var p = PatternFeature()
            p.kind = kind == .rectPattern ? .rectangular : (kind == .circularPattern ? .circular : .mirror)
            p.bodies = bodies.isEmpty && state.bodyOrder.count == 1 ? state.bodyOrder : bodies
            if let id = timelineSelection, isPatternable(id) { p.features = [id]; p.bodies = [] }
            if kind == .mirror, let plane = selection.compactMap({ planeRef(for: $0) }).first { p.plane = plane }
            return .pattern(p)
        case .move:
            var m = MoveFeature()
            m.bodies = bodies.isEmpty && state.bodyOrder.count == 1 ? state.bodyOrder : bodies
            return .move(m)
        case .combine:
            var c = CombineFeature()
            c.target = bodies.first
            c.tools = Array(bodies.dropFirst())
            return .combine(c)
        default:
            return nil
        }
    }

    /// Which input should receive clicks first for a fresh command.
    func firstInput(_ kind: FeatureKind) -> Int {
        switch kind {
        case let .plane(p): return p.plane == nil ? 0 : 1
        case let .pattern(p): return p.bodies.isEmpty && p.features.isEmpty ? 0 : 1
        case let .combine(c): return c.target == nil ? 0 : 1
        default: return 0
        }
    }

    func selectedBodies() -> [UUID] {
        var out: [UUID] = []
        for p in selection { if let b = p.bodyId, !out.contains(b) { out.append(b) } }
        return out
    }

    func cylinderFace(_ p: Pick, in s: ModelState) -> BodyFaceRef? {
        guard case let .face(b, i) = p, let body = s.bodies[b], body.faceInfos[i]?.surface == .cylinder,
              let ref = body.faceRef(i) else { return nil }
        return BodyFaceRef(body: b, face: ref)
    }

    /// Features whose tool can be repeated by a pattern.
    func isPatternable(_ id: UUID) -> Bool {
        switch doc.feature(id)?.kind {
        case .extrude?, .revolve?, .hole?, .thread?: return true
        default: return false
        }
    }

    /// Earlier timeline steps a pattern can repeat.
    var patternableFeatures: [Feature] {
        guard let id = command?.featureId, let idx = doc.index(of: id) else { return [] }
        return doc.features.prefix(idx).filter { isPatternable($0.id) && !$0.suppressed }
    }

    func hasModellingInputs(_ kind: FeatureKind) -> Bool {
        switch kind {
        case let .plane(p): return p.plane != nil
        case let .axis(a): return a.axis != nil || a.plane != nil
        case let .hole(h): return !h.points.isEmpty
        case let .thread(t): return !t.faces.isEmpty
        case let .pattern(p): return !p.bodies.isEmpty || !p.features.isEmpty
        case let .move(m): return !m.bodies.isEmpty
        case let .combine(c): return c.target != nil
        default: return true
        }
    }

    // MARK: - What the active input accepts

    enum InputKind { case plane, axis, bodies, body, cylinder, holePosition, none }

    /// The kind of geometry the active command input expects.
    var modellingInput: InputKind {
        guard let cmd = command, let kind = commandFeature?.kind else { return .none }
        let i = cmd.activeInput
        switch kind {
        case let .plane(p):
            if i == 0 { return .plane }
            return p.mode == .angle ? .axis : (p.mode == .midplane ? .plane : .none)
        case let .axis(a):
            return a.mode == .reference ? (i == 0 ? .axis : .none) : .plane
        case .hole: return .holePosition
        case .thread: return .cylinder
        case let .pattern(p):
            if i == 0 { return .bodies }
            return p.kind == .mirror ? .plane : .axis
        case .move: return i == 0 ? .bodies : .axis
        case .combine: return i == 0 ? .body : .bodies
        default: return .none
        }
    }

    /// Origin and construction planes are shown and pickable.
    var wantsPlanePick: Bool { command?.kind == .sketchPlane || modellingInput == .plane }
    /// Origin and construction axes are pickable.
    var wantsAxisPick: Bool { (command?.kind == .revolve && command?.activeInput == 1) || modellingInput == .axis }

    func acceptsModelling(_ p: Pick) -> Bool {
        switch modellingInput {
        case .plane: return planeRef(for: p) != nil
        case .axis: return axisRef(for: p) != nil
        case .bodies, .body:
            if case .face = p { return true }
            if case .body = p { return true }
            return false
        case .cylinder: return cylinderFace(p, in: stateBeforeCommand) != nil || cylinderFace(p, in: state) != nil
        case .holePosition:
            if case .sketchPoint = p { return true }
            if case let .face(b, i) = p { return state.bodies[b]?.faceInfos[i]?.isPlanar == true }
            return false
        case .none: return false
        }
    }

    // MARK: - Clicks

    func modellingClick(_ p: Pick) {
        guard let cmd = command else { return }
        let input = modellingInput
        let pre = stateBeforeCommand
        let bodyId = p.bodyId
        updateCommandFeature { k in
            switch k {
            case var .plane(x):
                if input == .axis {
                    x.axis = axisRef(for: p)
                } else if let ref = planeRef(for: p) {
                    if cmd.activeInput == 0 { x.plane = ref } else { x.plane2 = ref }
                }
                k = .plane(x)
            case var .axis(x):
                if x.mode == .reference { x.axis = axisRef(for: p) }
                else if let ref = planeRef(for: p) { if cmd.activeInput == 0 { x.plane = ref } else { x.plane2 = ref } }
                k = .axis(x)
            case var .hole(x):
                if case let .sketchPoint(s, i) = p {
                    let point = HolePoint.sketchPoint(sketch: s, point: i)
                    if let j = x.points.firstIndex(of: point) { x.points.remove(at: j) } else { x.points.append(point) }
                } else if case let .face(b, i) = p, let hit = faceHit(b, i, in: state),
                          let preBody = pre.bodies[b], let info = state.bodies[b]?.faceInfos[i],
                          let preIdx = preBody.resolve(FaceRef(index: -1, centroid: info.centroid, normal: info.normal)),
                          let ref = preBody.faceRef(preIdx) {
                    x.points.append(.face(BodyFaceRef(body: b, face: ref), position: hit))
                }
                k = .hole(x)
            case var .thread(x):
                guard let ref = cylinderFace(p, in: pre) ?? cylinderFace(p, in: state) else { return }
                if let j = x.faces.firstIndex(where: { $0.body == ref.body && $0.face.index == ref.face.index }) {
                    x.faces.remove(at: j)
                } else {
                    x.faces.append(ref)
                }
                k = .thread(x)
            case var .pattern(x):
                if cmd.activeInput == 0, let b = bodyId {
                    if let j = x.bodies.firstIndex(of: b) { x.bodies.remove(at: j) } else { x.bodies.append(b) }
                } else if x.kind == .mirror {
                    x.plane = planeRef(for: p)
                } else if let a = axisRef(for: p) {
                    if x.kind == .circular { x.axis = a }
                    else if cmd.activeInput == 2 { x.direction2 = a } else { x.direction = a }
                }
                k = .pattern(x)
            case var .move(x):
                if cmd.activeInput == 0, let b = bodyId {
                    if let j = x.bodies.firstIndex(of: b) { x.bodies.remove(at: j) } else { x.bodies.append(b) }
                } else if let a = axisRef(for: p) {
                    x.axis = a
                }
                k = .move(x)
            case var .combine(x):
                guard let b = bodyId else { return }
                if cmd.activeInput == 0 {
                    x.target = b
                    x.tools.removeAll { $0 == b }
                } else if b != x.target {
                    if let j = x.tools.firstIndex(of: b) { x.tools.remove(at: j) } else { x.tools.append(b) }
                }
                k = .combine(x)
            default:
                break
            }
        }
        advanceInput()
    }

    /// After a single-choice input is filled, the next one becomes active (like Fusion's dialogs).
    private func advanceInput() {
        guard let cmd = command, let kind = commandFeature?.kind else { return }
        switch kind {
        case let .plane(p) where cmd.activeInput == 0 && p.plane != nil && p.mode != .offset:
            command?.activeInput = 1
        case let .axis(a) where a.mode == .twoPlanes && cmd.activeInput == 0 && a.plane != nil:
            command?.activeInput = 1
        case let .combine(c) where cmd.activeInput == 0 && c.target != nil:
            command?.activeInput = 1
        default:
            return
        }
        sceneVersion &+= 1
    }

    func setActiveInput(_ i: Int) {
        command?.activeInput = i
        sceneVersion &+= 1
        requestRedraw()
    }

    /// The point under the cursor on a planar face (for placing holes).
    func faceHit(_ body: UUID, _ face: Int, in s: ModelState) -> Vec3? {
        guard let info = s.bodies[body]?.faceInfos[face], info.isPlanar else { return nil }
        let r = camera.rayD(at: lastMouse)
        let plane = Plane.forFace(point: info.origin, normal: info.normal)
        return plane.intersect(rayOrigin: r.origin, direction: r.direction)
    }

    // MARK: - Pick helpers for construction geometry

    /// Construction planes and axes that are visible in the viewport.
    var visibleConstruction: (planes: [(UUID, Plane)], axes: [(UUID, Axis3)]) {
        var planes: [(UUID, Plane)] = [], axes: [(UUID, Axis3)] = []
        for f in doc.features.prefix(doc.activeCount) where !doc.hiddenSketches.contains(f.id) && f.id != command?.featureId {
            if let p = state.planes[f.id] { planes.append((f.id, p)) }
            if let a = state.axes[f.id] { axes.append((f.id, a)) }
        }
        return (planes, axes)
    }
}
