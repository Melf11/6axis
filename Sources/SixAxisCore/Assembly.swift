import Foundation
import simd

// 1.4 "Baugruppen": components (named sets of bodies), their copies (instances) and joints.

/// A named set of bodies, e.g. "Tür" made of frame and panel. Copies of these bodies (Verschieben/Kopieren,
/// Muster) belong to the component as further instances and follow the original's dimensions.
public struct ComponentDef: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bodies: [UUID]
    public init(id: UUID = UUID(), name: String, bodies: [UUID]) {
        self.id = id
        self.name = name
        self.bodies = bodies
    }
}

public enum JointKind: String, Codable, CaseIterable, Hashable, Sendable {
    case rigid, revolute, slider

    public var displayName: String {
        switch self {
        case .rigid: return String(localized: "Starr")
        case .revolute: return String(localized: "Drehung")
        case .slider: return String(localized: "Schieben")
        }
    }
}

/// Moves one instance of a component along one degree of freedom (or fixes it to another instance).
public struct JointFeature: Codable, Hashable, Sendable {
    public var kind: JointKind = .revolute
    /// Any body of the instance that moves.
    public var body: UUID? = nil
    /// Rigid: any body of the instance it is attached to (it then moves along with it).
    public var parent: UUID? = nil
    public var axis: AxisRef? = nil
    /// Angle (revolute) or distance (slider), an expression such as "tuer_winkel".
    public var value: String = "0"
    public init() {}
}

/// Which instance a body belongs to: the component and the feature that made the copy (nil = original).
public struct InstanceKey: Hashable, Sendable {
    public var component: UUID
    public var copiedBy: UUID?
}

extension ModelState {
    /// The original body a copy was made from (following copies of copies).
    public func original(of body: UUID) -> UUID {
        var b = body
        var seen: Set<UUID> = []
        while let o = copyOf[b], seen.insert(b).inserted { b = o }
        return b
    }

    public func component(of body: UUID, in components: [ComponentDef]) -> ComponentDef? {
        let o = original(of: body)
        return components.first { $0.bodies.contains(o) }
    }

    public func instance(of body: UUID, in components: [ComponentDef]) -> InstanceKey? {
        guard let c = component(of: body, in: components) else { return nil }
        return InstanceKey(component: c.id, copiedBy: copiedBy[body])
    }

    /// All bodies of an instance (present in this state).
    public func bodies(of key: InstanceKey, in components: [ComponentDef]) -> [UUID] {
        bodyOrder.filter { instance(of: $0, in: components) == key }
    }

    /// Exploded view: each instance (or loose body) moves away from the centre of `bodies` by `factor`
    /// times its own distance from it.
    public func explodeOffsets(_ bodies: [UUID], components: [ComponentDef], factor: Double) -> [UUID: Vec3] {
        guard factor > 0 else { return [:] }
        var groups: [String: [UUID]] = [:]
        for b in bodies {
            let key = instance(of: b, in: components).map { "\($0.component)-\($0.copiedBy?.uuidString ?? "")" } ?? b.uuidString
            groups[key, default: []].append(b)
        }
        func center(_ ids: [UUID]) -> Vec3? {
            var lo = Vec3(repeating: .greatestFiniteMagnitude), hi = -lo
            for id in ids { if let bb = self.bodies[id]?.shape.boundingBox { lo = simd_min(lo, bb.min); hi = simd_max(hi, bb.max) } }
            return lo.x <= hi.x ? (lo + hi) / 2 : nil
        }
        guard let mid = center(bodies) else { return [:] }
        var out: [UUID: Vec3] = [:]
        for ids in groups.values {
            guard let c = center(ids) else { continue }
            for id in ids { out[id] = (c - mid) * factor }
        }
        return out
    }

    /// Number of instances per component.
    public func instanceCounts(_ components: [ComponentDef]) -> [UUID: Int] {
        var keys = Set<InstanceKey>()
        for b in bodyOrder { if let k = instance(of: b, in: components) { keys.insert(k) } }
        var out: [UUID: Int] = [:]
        for k in keys { out[k.component, default: 0] += 1 }
        return out
    }
}

extension ModelBuilder {
    func applyJoint(_ f: Feature, _ j: JointFeature, _ components: [ComponentDef], _ state: inout ModelState, _ ev: inout Evaluator) throws {
        guard let body = j.body, state.bodies[body] != nil else { throw KernelError("Keine Komponente gewählt") }
        guard let key = state.instance(of: body, in: components) else { throw KernelError("Der Körper gehört zu keiner Komponente") }
        switch j.kind {
        case .rigid:
            guard let parent = j.parent, let pk = state.instance(of: parent, in: components) else { throw KernelError("Kein Bezugsteil gewählt") }
            guard pk != key else { throw KernelError("Ein Teil kann nicht an sich selbst befestigt werden") }
            state.attachments[key] = pk
        case .revolute, .slider:
            guard let a = j.axis else { throw KernelError("Keine Achse gewählt") }
            let (o, dir) = try axis(a, state)
            var r = matrix_identity_double3x3, t = Vec3.zero
            if j.kind == .revolute {
                r = rotationMatrix(axis: dir, angle: try ev.evaluate(j.value, kind: .angle) * .pi / 180)
                t = o - r * o
            } else {
                t = simd_normalize(dir) * (try ev.evaluate(j.value))
            }
            // The instance and everything rigidly attached to it (directly or in a chain).
            var moving: Set<InstanceKey> = [key]
            var grew = true
            while grew {
                grew = false
                for (child, parent) in state.attachments where moving.contains(parent) && !moving.contains(child) {
                    moving.insert(child)
                    grew = true
                }
            }
            for k in moving {
                for id in state.bodies(of: k, in: components) {
                    guard let b = state.bodies[id] else { continue }
                    state.setBody(BuiltBody(id: id, shape: try b.shape.transformed(rotation: r, translation: t), sourceFeature: f.id))
                }
            }
        }
    }
}
