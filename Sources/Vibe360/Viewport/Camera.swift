import CoreGraphics
import Foundation
import simd
import VibeCore

/// Orbit camera around a target point. World is Z-up (3D printing convention).
struct Camera: Equatable {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 220
    /// Camera-to-world rotation. The camera looks along its local -Z, local +Y is up.
    var orientation = Camera.homeOrientation
    var fovY: Float = 30 * .pi / 180
    var orthographic = false
    /// Viewport size in points.
    var viewSize = CGSize(width: 800, height: 600)

    static let homeOrientation = Camera.lookOrientation(direction: SIMD3(-1, 1.6, -1.1), up: SIMD3(0, 0, 1))

    static func lookOrientation(direction d: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        let f = simd_normalize(d)
        var r = simd_cross(f, up)
        if simd_length(r) < 1e-5 { r = simd_cross(f, SIMD3(0, 1, 0)) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        let m = simd_float3x3(columns: (r, u, -f))
        return simd_quatf(m)
    }

    var forward: SIMD3<Float> { orientation.act(SIMD3(0, 0, -1)) }
    var up: SIMD3<Float> { orientation.act(SIMD3(0, 1, 0)) }
    var right: SIMD3<Float> { orientation.act(SIMD3(1, 0, 0)) }
    var eye: SIMD3<Float> { target - forward * distance }

    var aspect: Float { Float(max(viewSize.width, 1) / max(viewSize.height, 1)) }

    var viewMatrix: simd_float4x4 {
        let r = right, u = up, f = forward, e = eye
        return simd_float4x4(rows: [
            SIMD4(r.x, r.y, r.z, -simd_dot(r, e)),
            SIMD4(u.x, u.y, u.z, -simd_dot(u, e)),
            SIMD4(-f.x, -f.y, -f.z, simd_dot(f, e)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    var near: Float { orthographic ? -distance * 50 : max(0.01, distance * 0.01) }
    var far: Float { distance * 60 + 2000 }

    /// Half height of the visible area at the target distance.
    var halfHeight: Float { distance * tan(fovY / 2) }

    var projectionMatrix: simd_float4x4 {
        let n = near, f = far
        if orthographic {
            let h: Float = halfHeight
            let w: Float = h * aspect
            let range: Float = f - n
            // Metal clip space z in [0, 1].
            let r0 = SIMD4<Float>(1 / w, 0, 0, 0)
            let r1 = SIMD4<Float>(0, 1 / h, 0, 0)
            let r2 = SIMD4<Float>(0, 0, -1 / range, -n / range)
            let r3 = SIMD4<Float>(0, 0, 0, 1)
            return simd_float4x4(rows: [r0, r1, r2, r3])
        }
        let ys: Float = 1 / tan(fovY / 2)
        let xs: Float = ys / aspect
        let r0 = SIMD4<Float>(xs, 0, 0, 0)
        let r1 = SIMD4<Float>(0, ys, 0, 0)
        let r2 = SIMD4<Float>(0, 0, f / (n - f), n * f / (n - f))
        let r3 = SIMD4<Float>(0, 0, -1, 0)
        return simd_float4x4(rows: [r0, r1, r2, r3])
    }

    var viewProjection: simd_float4x4 { projectionMatrix * viewMatrix }

    /// World units per screen point at the target depth.
    var worldPerPoint: Float { 2 * halfHeight / Float(max(viewSize.height, 1)) }

    /// Screen point (top-left origin) for a world position; nil if behind the camera.
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let c = viewProjection * SIMD4(p, 1)
        guard c.w > 1e-6 else { return nil }
        let ndc = SIMD2(c.x, c.y) / c.w
        return CGPoint(x: CGFloat((ndc.x + 1) / 2) * viewSize.width, y: CGFloat((1 - ndc.y) / 2) * viewSize.height)
    }

    func project(_ p: Vec3) -> CGPoint? { project(p.float) }

    /// World-space ray through a screen point.
    func ray(at pt: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let nx = Float(pt.x / max(viewSize.width, 1)) * 2 - 1
        let ny = 1 - Float(pt.y / max(viewSize.height, 1)) * 2
        let h: Float = halfHeight
        let w: Float = h * aspect
        let side: SIMD3<Float> = right * (nx * w)
        let vertical: SIMD3<Float> = up * (ny * h)
        if orthographic {
            let back: SIMD3<Float> = forward * (distance * 10)
            return (target + side + vertical - back, forward)
        }
        let d: SIMD3<Float> = forward * distance + side + vertical
        return (eye, simd_normalize(d))
    }

    func rayD(at pt: CGPoint) -> (origin: Vec3, direction: Vec3) {
        let r = ray(at: pt)
        return (Vec3(Double(r.origin.x), Double(r.origin.y), Double(r.origin.z)),
                Vec3(Double(r.direction.x), Double(r.direction.y), Double(r.direction.z)))
    }

    // MARK: Navigation

    mutating func orbit(dx: Float, dy: Float) {
        let speed: Float = 0.006
        let yaw = simd_quatf(angle: -dx * speed, axis: SIMD3(0, 0, 1))
        var o = yaw * orientation
        let pitch = simd_quatf(angle: -dy * speed, axis: o.act(SIMD3(1, 0, 0)))
        let candidate = pitch * o
        // Keep the camera from flipping over the poles (turntable behaviour).
        let fz = abs(candidate.act(SIMD3<Float>(0, 0, -1)).z)
        let currentFz = abs(o.act(SIMD3<Float>(0, 0, -1)).z)
        if fz < 0.998 || fz < currentFz { o = candidate }
        orientation = simd_normalize(o)
    }

    mutating func pan(dx: Float, dy: Float) {
        let s = worldPerPoint
        target += (-right * dx + up * dy) * s
    }

    /// Zooms by factor (<1 = closer) keeping the world point under the cursor fixed.
    mutating func zoom(factor: Float, at pt: CGPoint?) {
        let f = max(0.2, min(5, factor))
        let newDistance = max(0.05, min(200_000, distance * f))
        if let pt {
            let before = pointOnTargetPlane(pt)
            distance = newDistance
            let after = pointOnTargetPlane(pt)
            target += before - after
        } else {
            distance = newDistance
        }
    }

    func pointOnTargetPlane(_ pt: CGPoint) -> SIMD3<Float> {
        let r = ray(at: pt)
        let n = forward
        let denom = simd_dot(r.direction, n)
        guard abs(denom) > 1e-6 else { return target }
        let t = simd_dot(target - r.origin, n) / denom
        return r.origin + r.direction * t
    }

    /// Frames a bounding box.
    mutating func fit(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        distance = radius / sin(fovY / 2) * (aspect < 1 ? 1 / aspect : 1) * 1.15
    }
}

/// Smooth camera transition.
struct CameraAnimation {
    var from: Camera
    var to: Camera
    var start: CFTimeInterval
    var duration: CFTimeInterval = 0.4

    func camera(at t: CFTimeInterval) -> (Camera, done: Bool) {
        let x = min(1, max(0, (t - start) / duration))
        let s = Float(x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2)
        var c = to
        c.orientation = simd_slerp(from.orientation, to.orientation, s)
        c.target = simd_mix(from.target, to.target, SIMD3(repeating: s))
        c.distance = from.distance + (to.distance - from.distance) * s
        return (c, x >= 1)
    }
}
