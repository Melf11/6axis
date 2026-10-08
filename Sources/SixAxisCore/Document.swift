import Foundation
import simd

// MARK: - References
// Topological references store a geometric signature so they survive upstream changes
// (the "topological naming problem"): on rebuild we re-resolve to the closest matching entity.

public struct FaceRef: Codable, Hashable, Sendable {
    public var index: Int
    public var centroid: Vec3
    public var normal: Vec3

    public init(index: Int, centroid: Vec3, normal: Vec3) {
        self.index = index
        self.centroid = centroid
        self.normal = normal
    }
}

public struct EdgeRef: Codable, Hashable, Sendable {
    public var index: Int
    public var midpoint: Vec3

    public init(index: Int, midpoint: Vec3) {
        self.index = index
        self.midpoint = midpoint
    }
}

public struct BodyFaceRef: Codable, Hashable, Sendable {
    public var body: UUID
    public var face: FaceRef
    public init(body: UUID, face: FaceRef) { self.body = body; self.face = face }
}

public struct BodyEdgeRef: Codable, Hashable, Sendable {
    public var body: UUID
    public var edge: EdgeRef
    public init(body: UUID, edge: EdgeRef) { self.body = body; self.edge = edge }
}

/// A closed sketch region, identified by a point inside it (sketch coordinates).
public struct ProfileRef: Codable, Hashable, Sendable {
    public var sketch: UUID
    public var sample: Vec2
    public init(sketch: UUID, sample: Vec2) { self.sketch = sketch; self.sample = sample }
}

public enum PlaneRef: Codable, Hashable, Sendable {
    case xy, xz, yz
    case face(BodyFaceRef)

    public var displayName: String {
        switch self {
        case .xy: return "XY-Ebene"
        case .xz: return "XZ-Ebene"
        case .yz: return "YZ-Ebene"
        case .face: return "Fläche"
        }
    }
}

public enum AxisRef: Codable, Hashable, Sendable {
    case x, y, z
    case sketchLine(sketch: UUID, curve: Int)
    case edge(BodyEdgeRef)

    public var displayName: String {
        switch self {
        case .x: return "X-Achse"
        case .y: return "Y-Achse"
        case .z: return "Z-Achse"
        case .sketchLine: return "Skizzenlinie"
        case .edge: return "Kante"
        }
    }
}

// MARK: - Features

public enum BodyOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case join, cut, intersect, newBody

    public var displayName: String {
        switch self {
        case .join: return "Verbinden"
        case .cut: return "Ausschneiden"
        case .intersect: return "Schneiden"
        case .newBody: return "Neuer Körper"
        }
    }

    public var symbol: String {
        switch self {
        case .join: return "plus.square.on.square"
        case .cut: return "minus.square"
        case .intersect: return "square.on.square.intersection.dashed"
        case .newBody: return "cube"
        }
    }
}

public enum ExtrudeExtent: String, Codable, CaseIterable, Hashable, Sendable {
    case oneSide, symmetric, twoSides

    public var displayName: String {
        switch self {
        case .oneSide: return "Eine Seite"
        case .symmetric: return "Symmetrisch"
        case .twoSides: return "Zwei Seiten"
        }
    }
}

public struct ExtrudeFeature: Codable, Hashable, Sendable {
    public var profiles: [ProfileRef] = []
    public var faces: [BodyFaceRef] = []
    public var distance: String = "10 mm"
    public var distance2: String = "10 mm"
    public var extent: ExtrudeExtent = .oneSide
    public var operation: BodyOperation = .newBody
    /// Bodies the operation applies to. Empty = all bodies the tool touches.
    public var targets: [UUID] = []
    public init() {}
}

public struct RevolveFeature: Codable, Hashable, Sendable {
    public var profiles: [ProfileRef] = []
    public var axis: AxisRef? = nil
    public var angle: String = "360"
    public var operation: BodyOperation = .newBody
    public var targets: [UUID] = []
    public init() {}
}

public struct FilletFeature: Codable, Hashable, Sendable {
    public var edges: [BodyEdgeRef] = []
    public var radius: String = "1 mm"
    public init() {}
}

public struct ChamferFeature: Codable, Hashable, Sendable {
    public var edges: [BodyEdgeRef] = []
    public var distance: String = "1 mm"
    public init() {}
}

public struct ShellFeature: Codable, Hashable, Sendable {
    public var faces: [BodyFaceRef] = []
    /// Body to hollow when no face is removed.
    public var body: UUID? = nil
    public var thickness: String = "2 mm"
    public init() {}
}

public struct ImportFeature: Codable, Hashable, Sendable {
    public var fileName: String
    public var stepText: String
    public init(fileName: String, stepText: String) {
        self.fileName = fileName
        self.stepText = stepText
    }
}

public enum FeatureKind: Codable, Hashable, Sendable {
    case sketch(Sketch)
    case extrude(ExtrudeFeature)
    case revolve(RevolveFeature)
    case fillet(FilletFeature)
    case chamfer(ChamferFeature)
    case shell(ShellFeature)
    case importStep(ImportFeature)

    public var typeName: String {
        switch self {
        case .sketch: return "Skizze"
        case .extrude: return "Extrusion"
        case .revolve: return "Drehung"
        case .fillet: return "Abrundung"
        case .chamfer: return "Fase"
        case .shell: return "Wandstärke"
        case .importStep: return "Import"
        }
    }

    public var symbol: String {
        switch self {
        case .sketch: return "pencil.and.outline"
        case .extrude: return "square.stack.3d.up.fill"
        case .revolve: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .fillet: return "button.roundedtop.horizontal"
        case .chamfer: return "triangle.bottomhalf.filled"
        case .shell: return "shippingbox"
        case .importStep: return "square.and.arrow.down"
        }
    }

    public var sketch: Sketch? {
        if case let .sketch(s) = self { return s }
        return nil
    }
}

public struct Feature: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var suppressed: Bool
    public var kind: FeatureKind

    public init(id: UUID = UUID(), name: String, kind: FeatureKind, suppressed: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.suppressed = suppressed
    }
}

public struct BodyMeta: Codable, Hashable, Sendable {
    public var name: String
    public var visible: Bool = true
    public init(name: String, visible: Bool = true) {
        self.name = name
        self.visible = visible
    }
}

// MARK: - Document

/// The complete persistent state of a design. Pure value type: snapshots make undo trivial.
public struct CADDocument: Codable, Hashable, Sendable {
    public var formatVersion = 1
    public var features: [Feature] = []
    public var parameters: [UserParameter] = []
    /// Number of active timeline entries (marker position). nil = all.
    public var rollback: Int? = nil
    public var bodies: [UUID: BodyMeta] = [:]
    public var hiddenSketches: Set<UUID> = []
    /// Technical drawing settings; optional so older files decode unchanged.
    public var drawing: DrawingSettings?

    public init() {}

    public var activeCount: Int { min(rollback ?? features.count, features.count) }

    public func index(of id: UUID) -> Int? { features.firstIndex { $0.id == id } }
    public func feature(_ id: UUID) -> Feature? { features.first { $0.id == id } }

    public mutating func update(_ id: UUID, _ change: (inout Feature) -> Void) {
        if let i = index(of: id) { change(&features[i]) }
    }

    /// Unique default name like "Skizze3".
    public func nextName(for kind: FeatureKind) -> String {
        let base = kind.typeName
        var n = 1
        let names = Set(features.map(\.name))
        while names.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    public func bodyName(_ id: UUID) -> String { bodies[id]?.name ?? "Körper" }
    public func isBodyVisible(_ id: UUID) -> Bool { bodies[id]?.visible ?? true }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> CADDocument {
        try JSONDecoder().decode(CADDocument.self, from: data)
    }
}
