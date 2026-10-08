import Foundation
import simd

public typealias Vec2 = SIMD2<Double>
public typealias Vec3 = SIMD3<Double>

/// A right-handed plane frame. Sketch coordinates (u, v) map to `origin + u * xDir + v * yDir`.
public struct Plane: Codable, Hashable, Sendable {
    public var origin: Vec3
    public var xDir: Vec3
    public var normal: Vec3

    public init(origin: Vec3, xDir: Vec3, normal: Vec3) {
        self.origin = origin
        self.normal = simd_normalize(normal)
        // Re-orthogonalize xDir against the normal.
        let x = xDir - simd_dot(xDir, self.normal) * self.normal
        self.xDir = simd_normalize(x)
    }

    public var yDir: Vec3 { simd_cross(normal, xDir) }

    public func point(_ uv: Vec2) -> Vec3 { origin + uv.x * xDir + uv.y * yDir }

    public func project(_ p: Vec3) -> Vec2 {
        let d = p - origin
        return Vec2(simd_dot(d, xDir), simd_dot(d, yDir))
    }

    public func direction(_ d: Vec2) -> Vec3 { d.x * xDir + d.y * yDir }

    /// Intersection of a ray with the plane, if it hits in front of the ray origin.
    public func intersect(rayOrigin o: Vec3, direction d: Vec3) -> Vec3? {
        let denom = simd_dot(d, normal)
        guard abs(denom) > 1e-12 else { return nil }
        let t = simd_dot(origin - o, normal) / denom
        return o + t * d
    }

    public static let xy = Plane(origin: .zero, xDir: Vec3(1, 0, 0), normal: Vec3(0, 0, 1))
    public static let xz = Plane(origin: .zero, xDir: Vec3(1, 0, 0), normal: Vec3(0, -1, 0))
    public static let yz = Plane(origin: .zero, xDir: Vec3(0, 1, 0), normal: Vec3(1, 0, 0))

    /// A sketch frame for an arbitrary planar face: world origin projected onto the plane,
    /// x axis aligned with the most suitable world axis. Stable across rebuilds.
    public static func forFace(point: Vec3, normal: Vec3) -> Plane {
        let n = simd_normalize(normal)
        let origin = simd_dot(point, n) * n
        let candidates = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        let x = candidates.min { abs(simd_dot($0, n)) < abs(simd_dot($1, n)) }!
        return Plane(origin: origin, xDir: x, normal: n)
    }
}

extension SIMD2 where Scalar == Double {
    public var length: Double { simd_length(self) }
    public var perpendicular: Vec2 { Vec2(-y, x) }
}

extension SIMD3 where Scalar == Double {
    public var float: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

/// Circle through three points, if they are not collinear.
public func circleThrough(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> (center: Vec2, radius: Double)? {
    let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    guard abs(d) > 1e-12 else { return nil }
    let a2 = simd_length_squared(a), b2 = simd_length_squared(b), c2 = simd_length_squared(c)
    let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
    let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
    let center = Vec2(ux, uy)
    return (center, simd_distance(center, a))
}

/// Normalizes an angle to [0, 2π).
public func normalizedAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r
}
