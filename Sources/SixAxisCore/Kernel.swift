import Foundation
import OCCTBridge
import simd

public struct KernelError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }

    static func last(_ fallback: String) -> KernelError {
        let msg = String(cString: ob_last_error())
        return KernelError(msg.isEmpty ? fallback : msg)
    }
}

/// An immutable B-Rep shape owned by Swift. Shapes are never mutated; every operation returns a new one.
public final class Shape: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) { self.handle = handle }

    static func wrap(_ ptr: OpaquePointer?, _ fallback: String) throws -> Shape {
        guard let ptr else { throw KernelError.last(fallback) }
        return Shape(ptr)
    }

    deinit { ob_shape_free(handle) }

    public var faceCount: Int { Int(ob_shape_face_count(handle)) }
    public var edgeCount: Int { Int(ob_shape_edge_count(handle)) }
    public var solidCount: Int { Int(ob_shape_solid_count(handle)) }
    public var volume: Double { ob_shape_volume(handle) }
    public var area: Double { ob_shape_area(handle) }

    public var boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var lo = [0.0, 0.0, 0.0], hi = [0.0, 0.0, 0.0]
        guard ob_shape_bbox(handle, &lo, &hi) != 0 else { return nil }
        return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
    }

    public func face(_ index: Int) throws -> Shape {
        try Shape.wrap(ob_shape_face(handle, Int32(index)), "Fläche nicht gefunden")
    }

    public func solid(_ index: Int) throws -> Shape {
        try Shape.wrap(ob_shape_solid(handle, Int32(index)), "Körper nicht gefunden")
    }

    public var faces: [Shape] { (0..<faceCount).compactMap { try? face($0) } }
    public var solids: [Shape] { (0..<solidCount).compactMap { try? solid($0) } }

    public func faceInfo(_ index: Int) -> FaceInfo? {
        var info = OBFaceInfo()
        guard ob_face_info(handle, Int32(index), &info) != 0 else { return nil }
        return FaceInfo(
            index: index,
            isPlanar: info.isPlanar != 0,
            origin: vec(info.origin),
            normal: vec(info.normal),
            centroid: vec(info.centroid),
            area: info.area)
    }

    public func edgeInfo(_ index: Int) -> EdgeInfo? {
        var info = OBEdgeInfo()
        guard ob_edge_info(handle, Int32(index), &info) != 0 else { return nil }
        return EdgeInfo(
            index: index,
            kind: EdgeInfo.Kind(rawValue: Int(info.kind)) ?? .other,
            midpoint: vec(info.midpoint),
            start: vec(info.start),
            end: vec(info.end),
            length: info.length)
    }

    public func contains(_ p: SIMD3<Double>) -> Bool {
        var a = [p.x, p.y, p.z]
        return ob_face_contains(handle, &a) != 0
    }

    // MARK: Modeling

    public func extruded(_ v: SIMD3<Double>) throws -> Shape {
        var d = [v.x, v.y, v.z]
        return try Shape.wrap(ob_prism(handle, &d), "Extrusion fehlgeschlagen")
    }

    public func translated(_ v: SIMD3<Double>) throws -> Shape {
        var d = [v.x, v.y, v.z]
        return try Shape.wrap(ob_translate(handle, &d), "Verschieben fehlgeschlagen")
    }

    /// Rigid transform `p' = rotation * p + translation` (rotation must be orthonormal, det = +1).
    public func transformed(rotation r: simd_double3x3, translation t: Vec3) throws -> Shape {
        var m = [r[0, 0], r[1, 0], r[2, 0], t.x,
                 r[0, 1], r[1, 1], r[2, 1], t.y,
                 r[0, 2], r[1, 2], r[2, 2], t.z]
        return try Shape.wrap(ob_transform(handle, &m), "Transformieren fehlgeschlagen")
    }

    public func revolved(origin: SIMD3<Double>, axis: SIMD3<Double>, angle: Double) throws -> Shape {
        var o = [origin.x, origin.y, origin.z], a = [axis.x, axis.y, axis.z]
        return try Shape.wrap(ob_revolve(handle, &o, &a, angle), "Drehung fehlgeschlagen")
    }

    public enum BooleanOp: Int32 { case fuse = 0, cut = 1, common = 2 }

    public func boolean(_ op: BooleanOp, _ other: Shape) throws -> Shape {
        try Shape.wrap(ob_boolean(handle, other.handle, op.rawValue), "Boolesche Operation fehlgeschlagen")
    }

    public func filleted(edges: [Int], radius: Double) throws -> Shape {
        let e = edges.map { Int32($0) }
        return try Shape.wrap(ob_fillet(handle, e, Int32(e.count), radius), "Abrundung fehlgeschlagen")
    }

    public func chamfered(edges: [Int], distance: Double) throws -> Shape {
        let e = edges.map { Int32($0) }
        return try Shape.wrap(ob_chamfer(handle, e, Int32(e.count), distance), "Fase fehlgeschlagen")
    }

    public func shelled(removing faces: [Int], thickness: Double) throws -> Shape {
        let f = faces.map { Int32($0) }
        return try Shape.wrap(ob_shell(handle, f, Int32(f.count), thickness), "Wandstärke fehlgeschlagen")
    }

    public static func compound(_ shapes: [Shape]) -> Shape {
        let ptrs: [OpaquePointer?] = shapes.map { $0.handle }
        return ptrs.withUnsafeBufferPointer { Shape(ob_compound($0.baseAddress, Int32(shapes.count))!) }
    }

    public static func fuseFaces(_ faces: [Shape]) throws -> Shape {
        if faces.count == 1 { return faces[0] }
        let ptrs: [OpaquePointer?] = faces.map { $0.handle }
        return try ptrs.withUnsafeBufferPointer {
            try Shape.wrap(ob_fuse_faces($0.baseAddress, Int32(faces.count)), "Profile vereinen fehlgeschlagen")
        }
    }

    // MARK: Sketch regions

    public static func sketchRegions(plane: Plane, segments: [Segment2D]) throws -> Shape {
        var pl = OBPlane()
        withUnsafeMutableBytes(of: &pl.origin) { copy(plane.origin, into: $0) }
        withUnsafeMutableBytes(of: &pl.xDir) { copy(plane.xDir, into: $0) }
        withUnsafeMutableBytes(of: &pl.normal) { copy(plane.normal, into: $0) }
        let segs: [OBSegment] = segments.map { s in
            var o = OBSegment()
            switch s {
            case let .line(a, b):
                o.kind = Int32(OB_SEG_LINE)
                o.a = (a.x, a.y); o.b = (b.x, b.y)
            case let .arc(c, r, a, b):
                o.kind = Int32(OB_SEG_ARC)
                o.a = (a.x, a.y); o.b = (b.x, b.y); o.c = (c.x, c.y); o.radius = r
            case let .circle(c, r):
                o.kind = Int32(OB_SEG_CIRCLE)
                o.c = (c.x, c.y); o.radius = r
            }
            return o
        }
        return try Shape.wrap(ob_sketch_regions(&pl, segs, Int32(segs.count)), "Profilerkennung fehlgeschlagen")
    }

    // MARK: Tessellation

    public func mesh(linearDeflection: Double = 0.05, angularDeflection: Double = 0.35) throws -> TriangleMesh {
        var m = OBMesh()
        guard ob_mesh(handle, linearDeflection, angularDeflection, &m) != 0 else {
            throw KernelError.last("Vernetzung fehlgeschlagen")
        }
        defer { ob_mesh_free(&m) }
        let vc = Int(m.vertexCount), ic = Int(m.indexCount), ec = Int(m.edgeSegmentCount)
        var positions = [SIMD3<Float>](), normals = [SIMD3<Float>]()
        positions.reserveCapacity(vc)
        normals.reserveCapacity(vc)
        for i in 0..<vc {
            positions.append(SIMD3(m.positions[3 * i], m.positions[3 * i + 1], m.positions[3 * i + 2]))
            normals.append(SIMD3(m.normals[3 * i], m.normals[3 * i + 1], m.normals[3 * i + 2]))
        }
        var edgeSegments = [(SIMD3<Float>, SIMD3<Float>)]()
        edgeSegments.reserveCapacity(ec)
        for i in 0..<ec {
            let p = m.edgePoints + 6 * i
            edgeSegments.append((SIMD3(p[0], p[1], p[2]), SIMD3(p[3], p[4], p[5])))
        }
        return TriangleMesh(
            positions: positions,
            normals: normals,
            faceIds: Array(UnsafeBufferPointer(start: m.faceIds, count: vc)),
            indices: Array(UnsafeBufferPointer(start: m.indices, count: ic)),
            edgeSegments: edgeSegments,
            edgeIds: Array(UnsafeBufferPointer(start: m.edgeIds, count: ec)),
            faceCount: Int(m.faceCount),
            edgeCount: Int(m.edgeCount))
    }

    // MARK: Exchange

    public func writeSTL(to url: URL, linearDeflection: Double = 0.01, ascii: Bool = false) throws {
        guard ob_write_stl(handle, url.path, linearDeflection, ascii ? 1 : 0) != 0 else {
            throw KernelError.last("STL-Export fehlgeschlagen")
        }
    }

    public func writeSTEP(to url: URL) throws {
        guard ob_write_step(handle, url.path) != 0 else { throw KernelError.last("STEP-Export fehlgeschlagen") }
    }

    public static func readSTEP(from url: URL) throws -> Shape {
        try Shape.wrap(ob_read_step(url.path), "STEP-Import fehlgeschlagen")
    }
}

private func vec(_ t: (Double, Double, Double)) -> SIMD3<Double> { SIMD3(t.0, t.1, t.2) }

private func copy(_ v: SIMD3<Double>, into buf: UnsafeMutableRawBufferPointer) {
    let p = buf.bindMemory(to: Double.self)
    p[0] = v.x; p[1] = v.y; p[2] = v.z
}

public struct FaceInfo: Sendable {
    public let index: Int
    public let isPlanar: Bool
    public let origin: SIMD3<Double>
    public let normal: SIMD3<Double>
    public let centroid: SIMD3<Double>
    public let area: Double
}

public struct EdgeInfo: Sendable {
    public enum Kind: Int, Sendable { case line = 0, circle = 1, other = 2 }
    public let index: Int
    public let kind: Kind
    public let midpoint: SIMD3<Double>
    public let start: SIMD3<Double>
    public let end: SIMD3<Double>
    public let length: Double
}

public enum Segment2D: Sendable {
    case line(SIMD2<Double>, SIMD2<Double>)
    /// Counter-clockwise arc from `start` to `end`.
    case arc(center: SIMD2<Double>, radius: Double, start: SIMD2<Double>, end: SIMD2<Double>)
    case circle(center: SIMD2<Double>, radius: Double)
}

public struct TriangleMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var faceIds: [UInt32]
    public var indices: [UInt32]
    public var edgeSegments: [(SIMD3<Float>, SIMD3<Float>)]
    public var edgeIds: [UInt32]
    public var faceCount: Int
    public var edgeCount: Int
}

// MARK: - Hidden-line projection

public struct Polyline2D: Sendable {
    public var points: [Vec2]
    public var hidden: Bool
    public var outline: Bool
    /// Tangent (smooth) edges: usually not drawn in technical drawings.
    public var smooth: Bool
}

public struct Circle2D: Sendable {
    public var center: Vec2
    public var radius: Double
    public var full: Bool
    public var hidden: Bool
}

public struct Projection2D: Sendable {
    public var polylines: [Polyline2D] = []
    public var circles: [Circle2D] = []

    public init() {}

    /// Bounding box of visible and hidden geometry (smooth edges excluded).
    public var bounds: (min: Vec2, max: Vec2)? {
        var lo = Vec2(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in polylines where !p.smooth {
            for q in p.points { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }
}

extension Shape {
    public static func box(min lo: Vec3, max hi: Vec3) throws -> Shape {
        var a = [lo.x, lo.y, lo.z], b = [hi.x, hi.y, hi.z]
        return try Shape.wrap(ob_box(&a, &b), "Quader fehlgeschlagen")
    }

    public static func planeFace(origin: Vec3, normal: Vec3, xDir: Vec3, halfSize: Double) throws -> Shape {
        var o = [origin.x, origin.y, origin.z], n = [normal.x, normal.y, normal.z], x = [xDir.x, xDir.y, xDir.z]
        return try Shape.wrap(ob_plane_face(&o, &n, &x, halfSize), "Schnittebene fehlgeschlagen")
    }

    /// Boundary polylines of every face, projected into the view plane (for hatching section faces).
    public func faceOutlines(viewDir: Vec3, xDir: Vec3, deflection: Double) -> [[Vec2]] {
        var p = OBProjection()
        var d = [viewDir.x, viewDir.y, viewDir.z], x = [xDir.x, xDir.y, xDir.z]
        guard ob_face_outlines(handle, &d, &x, deflection, &p) != 0 else { return [] }
        defer { ob_projection_free(&p) }
        return (0..<Int(p.polyCount)).map { i in
            (Int(p.polyStart[i])..<Int(p.polyStart[i + 1])).map { Vec2(Double(p.points[2 * $0]), Double(p.points[2 * $0 + 1])) }
        }
    }

    /// Exact hidden-line projection. `viewDir` points towards the viewer; `xDir` becomes the drawing's +x.
    public func project(viewDir: Vec3, xDir: Vec3, deflection: Double) throws -> Projection2D {
        var p = OBProjection()
        var d = [viewDir.x, viewDir.y, viewDir.z], x = [xDir.x, xDir.y, xDir.z]
        guard ob_hlr(handle, &d, &x, deflection, &p) != 0 else { throw KernelError.last("Projektion fehlgeschlagen") }
        defer { ob_projection_free(&p) }
        var out = Projection2D()
        for i in 0..<Int(p.polyCount) {
            let a = Int(p.polyStart[i]), b = Int(p.polyStart[i + 1])
            let pts = (a..<b).map { Vec2(Double(p.points[2 * $0]), Double(p.points[2 * $0 + 1])) }
            let f = Int32(p.polyFlags[i])
            out.polylines.append(Polyline2D(points: pts, hidden: f & Int32(OB_LINE_HIDDEN) != 0,
                                            outline: f & Int32(OB_LINE_OUTLINE) != 0, smooth: f & Int32(OB_LINE_SMOOTH) != 0))
        }
        for i in 0..<Int(p.circleCount) {
            let c = p.circles + 5 * i
            out.circles.append(Circle2D(center: Vec2(c[0], c[1]), radius: c[2], full: abs(c[4]) > 2 * .pi - 1e-6,
                                        hidden: Int32(p.circleFlags[i]) & Int32(OB_LINE_HIDDEN) != 0))
        }
        return out
    }
}
