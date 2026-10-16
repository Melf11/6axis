import Foundation
import simd

// Features of 1.2 "Modellieren": construction geometry, holes, threads, patterns, moving and combining bodies.

// MARK: - Construction geometry

public enum ConstructionPlaneMode: String, Codable, CaseIterable, Hashable, Sendable {
    case offset, angle, midplane

    public var displayName: String {
        switch self {
        case .offset: return String(localized: "Versetzt")
        case .angle: return String(localized: "Unter Winkel")
        case .midplane: return String(localized: "Mittelebene")
        }
    }
}

public struct ConstructionPlaneFeature: Codable, Hashable, Sendable {
    public var mode: ConstructionPlaneMode = .offset
    /// Reference plane (offset, angle) or first plane (midplane).
    public var plane: PlaneRef? = nil
    /// Second plane (midplane).
    public var plane2: PlaneRef? = nil
    /// Rotation axis (angle).
    public var axis: AxisRef? = nil
    public var distance: String = "10 mm"
    public var angle: String = "45"
    public init() {}
}

public enum ConstructionAxisMode: String, Codable, CaseIterable, Hashable, Sendable {
    case reference, twoPlanes

    public var displayName: String {
        switch self {
        case .reference: return String(localized: "Durch Zylinder oder Kante")
        case .twoPlanes: return String(localized: "Schnitt zweier Ebenen")
        }
    }
}

public struct ConstructionAxisFeature: Codable, Hashable, Sendable {
    public var mode: ConstructionAxisMode = .reference
    public var axis: AxisRef? = nil
    public var plane: PlaneRef? = nil
    public var plane2: PlaneRef? = nil
    public init() {}
}

/// An axis in space (unit direction).
public struct Axis3: Hashable, Sendable {
    public var origin: Vec3
    public var direction: Vec3
    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = simd_normalize(direction)
    }
}

// MARK: - Threads

/// ISO metric coarse threads (DIN 13): nominal diameter, pitch and tap drill.
public struct MetricThread: Hashable, Sendable, Identifiable {
    public let name: String
    public let major: Double
    public let pitch: Double
    public let tapDrill: Double
    public var id: String { name }

    public static let all: [MetricThread] = [
        .init(name: "M2", major: 2, pitch: 0.4, tapDrill: 1.6),
        .init(name: "M2.5", major: 2.5, pitch: 0.45, tapDrill: 2.05),
        .init(name: "M3", major: 3, pitch: 0.5, tapDrill: 2.5),
        .init(name: "M4", major: 4, pitch: 0.7, tapDrill: 3.3),
        .init(name: "M5", major: 5, pitch: 0.8, tapDrill: 4.2),
        .init(name: "M6", major: 6, pitch: 1, tapDrill: 5),
        .init(name: "M8", major: 8, pitch: 1.25, tapDrill: 6.8),
        .init(name: "M10", major: 10, pitch: 1.5, tapDrill: 8.5),
        .init(name: "M12", major: 12, pitch: 1.75, tapDrill: 10.2),
        .init(name: "M14", major: 14, pitch: 2, tapDrill: 12),
        .init(name: "M16", major: 16, pitch: 2, tapDrill: 14),
        .init(name: "M20", major: 20, pitch: 2.5, tapDrill: 17.5),
        .init(name: "M24", major: 24, pitch: 3, tapDrill: 21),
    ]

    public static func named(_ name: String) -> MetricThread? { all.first { $0.name == name } }

    /// Best match for a cylinder: bolts by nominal diameter, holes by tap drill.
    public static func matching(diameter d: Double, isInternal: Bool) -> MetricThread? {
        all.min { abs((isInternal ? $0.tapDrill : $0.major) - d) < abs((isInternal ? $1.tapDrill : $1.major) - d) }
    }
}

public struct ThreadFeature: Codable, Hashable, Sendable {
    /// Cylindrical faces (bolts or holes).
    public var faces: [BodyFaceRef] = []
    /// Thread size such as "M8"; nil = chosen from the cylinder's diameter.
    public var size: String? = nil
    /// Real thread geometry (3D printing); otherwise only marked (drawing callout).
    public var modeled: Bool = true
    public init() {}
}

// MARK: - Holes

public enum HolePoint: Codable, Hashable, Sendable {
    /// A point of a sketch: the hole follows the sketch's dimensions.
    case sketchPoint(sketch: UUID, point: Int)
    /// A clicked point on a planar face (1.2; new holes use `faceOffset`).
    case face(BodyFaceRef, position: Vec3)
    /// On a planar face, `x`/`y` (expressions) from the face's lower left corner in its own frame
    /// (`FaceFrame`): exact, and the hole follows when the part changes size.
    case faceOffset(BodyFaceRef, x: String, y: String)
}

/// A planar face's own 2D frame: axes like a sketch on that face, origin at the lower left corner of the face.
public struct FaceFrame: Sendable {
    public var plane: Plane
    public var corner: Vec2

    /// Point on the face for distances from the corner.
    public func point(_ x: Double, _ y: Double) -> Vec3 { plane.point(corner + Vec2(x, y)) }
    /// Distances from the corner of a point on the face.
    public func offsets(_ p: Vec3) -> Vec2 { plane.project(p) - corner }

    /// The world axis a direction mostly follows ("X", "Y", "Z"), for labels.
    public static func axisName(_ d: Vec3) -> String {
        let a = [abs(d.x), abs(d.y), abs(d.z)]
        return ["X", "Y", "Z"][a.firstIndex(of: a.max()!)!]
    }

    public static func of(_ body: BuiltBody, face idx: Int) -> FaceFrame? {
        guard let info = body.faceInfos[safe: idx] ?? nil, info.isPlanar, let face = try? body.shape.face(idx) else { return nil }
        let plane = Plane.forFace(point: info.origin, normal: info.normal)
        guard let outer = face.faceLoops(deflection: 0.05).first, !outer.isEmpty else { return nil }
        let uv = outer.map { plane.project($0) }
        return FaceFrame(plane: plane, corner: Vec2(uv.map(\.x).min()!, uv.map(\.y).min()!))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

public enum HoleType: String, Codable, CaseIterable, Hashable, Sendable {
    case simple, counterbore, countersink

    public var displayName: String {
        switch self {
        case .simple: return String(localized: "Einfach")
        case .counterbore: return String(localized: "Flachsenkung")
        case .countersink: return String(localized: "Kegelsenkung")
        }
    }
}

public enum HoleExtent: String, Codable, CaseIterable, Hashable, Sendable {
    case depth, through

    public var displayName: String {
        switch self {
        case .depth: return String(localized: "Tiefe")
        case .through: return String(localized: "Durch alles")
        }
    }
}

public struct HoleFeature: Codable, Hashable, Sendable {
    public var points: [HolePoint] = []
    public var type: HoleType = .simple
    public var extent: HoleExtent = .depth
    public var diameter: String = "5 mm"
    public var depth: String = "10 mm"
    /// Counterbore/countersink diameter and counterbore depth.
    public var headDiameter: String = "10 mm"
    public var headDepth: String = "5 mm"
    public var countersinkAngle: String = "90"
    /// Tap drill for this thread ("M8"); the diameter then follows the table.
    public var thread: String? = nil
    public var threadModeled: Bool = true
    /// Drill in the direction of the face/sketch normal instead of against it.
    public var flip: Bool = false
    public init() {}
}

// MARK: - Patterns

public enum PatternKind: String, Codable, CaseIterable, Hashable, Sendable {
    case rectangular, circular, mirror

    public var displayName: String {
        switch self {
        case .rectangular: return String(localized: "Rechteckmuster")
        case .circular: return String(localized: "Kreismuster")
        case .mirror: return String(localized: "Spiegeln")
        }
    }

    public var symbol: String {
        switch self {
        case .rectangular: return "square.grid.3x1.below.line.grid.1x2"
        case .circular: return "circle.hexagongrid"
        case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        }
    }
}

public struct PatternFeature: Codable, Hashable, Sendable {
    public var kind: PatternKind = .rectangular
    /// Whole bodies to copy (copies become new bodies).
    public var bodies: [UUID] = []
    /// Features to repeat (extrusion, revolve, hole, thread): their tool is applied again at each position.
    public var features: [UUID] = []
    public var direction: AxisRef? = .x
    public var count: String = "3"
    public var spacing: String = "50 mm"
    public var direction2: AxisRef? = nil
    public var count2: String = "2"
    public var spacing2: String = "50 mm"
    public var axis: AxisRef? = .z
    public var circularCount: String = "6"
    /// Total angle; 360 spreads the copies evenly around the full circle.
    public var angle: String = "360"
    public var plane: PlaneRef? = .yz
    public init() {}
}

// MARK: - Moving and combining bodies

public struct MoveFeature: Codable, Hashable, Sendable {
    public var bodies: [UUID] = []
    public var dx: String = "0 mm"
    public var dy: String = "0 mm"
    public var dz: String = "0 mm"
    public var axis: AxisRef? = .z
    public var angle: String = "0"
    /// Keep the original and add a moved copy.
    public var copy: Bool = false
    public init() {}
}

public struct CombineFeature: Codable, Hashable, Sendable {
    public var target: UUID? = nil
    public var tools: [UUID] = []
    public var operation: BodyOperation = .join
    public var keepTools: Bool = false
    public init() {}
}

// MARK: - Helpers

extension UUID {
    /// Stable id for the n-th result of a feature (copies keep their names and settings across rebuilds).
    public func derived(_ n: Int) -> UUID {
        var bytes = withUnsafeBytes(of: uuid) { Array($0) }
        var x = UInt64(truncatingIfNeeded: n) &* 0x9E37_79B9_7F4A_7C15 &+ 0x6A09_E667_F3BC_C909
        for i in 0..<16 {
            bytes[i] ^= UInt8(truncatingIfNeeded: x)
            x = (x >> 8) | (x << 56)
            x = x &* 0xBF58_476D_1CE4_E5B9 &+ UInt64(i)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Rotation matrix around a unit axis (Rodrigues).
public func rotationMatrix(axis a: Vec3, angle: Double) -> simd_double3x3 {
    let k = simd_normalize(a), c = cos(angle), s = sin(angle), t = 1 - c
    return simd_double3x3(rows: [
        Vec3(t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y),
        Vec3(t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x),
        Vec3(t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c),
    ])
}
