import Foundation
import simd

/// Measuring faces and edges of bodies (Prüfen → Messen).
public enum Measure {
    public enum Target {
        case face(BuiltBody, Int)
        case edge(BuiltBody, Int)
    }

    public enum Unit: Sendable { case length, area, angle }

    public struct Row: Sendable, Equatable {
        public var label: String
        public var value: Double
        public var unit: Unit
    }

    public struct Result: Sendable {
        public var rows: [Row] = []
        /// Closest points of two picks (drawn as a dimension line).
        public var line: (Vec3, Vec3)?
    }

    /// Direction of a target: plane normal, cylinder/circle axis or line direction.
    static func direction(_ t: Target) -> (dir: Vec3, isAxis: Bool, point: Vec3)? {
        switch t {
        case let .face(b, i):
            guard let f = b.faceInfos[i] else { return nil }
            if f.isPlanar { return (f.normal, false, f.origin) }
            if f.surface == .cylinder || f.surface == .cone { return (f.axisDir, true, f.axisOrigin) }
            return nil
        case let .edge(b, i):
            guard let e = b.edgeInfos[i] else { return nil }
            if e.kind == .line { return (simd_normalize(e.end - e.start), false, e.start) }
            if e.kind == .circle { return (e.axis, true, e.center) }
            return nil
        }
    }

    static func shape(_ t: Target) -> Shape? {
        switch t {
        case let .face(b, i): return try? b.shape.face(i)
        case let .edge(b, i): return try? b.shape.edge(i)
        }
    }

    public static func measure(_ targets: [Target]) -> Result {
        var r = Result()
        guard let first = targets.first else { return r }
        if targets.count == 1 {
            switch first {
            case let .face(b, i):
                guard let f = b.faceInfos[i] else { break }
                r.rows.append(Row(label: String(localized: "Fläche"), value: f.area, unit: .area))
                if f.surface == .cylinder { r.rows.append(Row(label: String(localized: "Durchmesser"), value: 2 * f.radius, unit: .length)) }
            case let .edge(b, i):
                guard let e = b.edgeInfos[i] else { break }
                r.rows.append(Row(label: String(localized: "Länge"), value: e.length, unit: .length))
                if e.kind == .circle { r.rows.append(Row(label: String(localized: "Durchmesser"), value: 2 * e.radius, unit: .length)) }
            }
            return r
        }
        let second = targets[1]
        if let a = shape(first), let b = shape(second), let d = a.distance(to: b) {
            r.rows.append(Row(label: String(localized: "Abstand"), value: d.distance, unit: .length))
            if d.distance > 1e-9 { r.line = (d.a, d.b) }
        }
        if let da = direction(first), let db = direction(second) {
            let c = min(1, abs(simd_dot(da.dir, db.dir)))
            let parallel = c > 1 - 1e-9
            if da.isAxis && db.isAxis && parallel {
                // Distance between two parallel axes (hole spacing).
                let v = db.point - da.point
                let off = v - simd_dot(v, da.dir) * da.dir
                r.rows.append(Row(label: String(localized: "Achsabstand"), value: simd_length(off), unit: .length))
            } else if !da.isAxis && !db.isAxis {
                // Faces: angle between the planes; lines: angle between the lines (0…90°).
                r.rows.append(Row(label: String(localized: "Winkel"), value: acos(c) * 180 / .pi, unit: .angle))
            }
        }
        return r
    }
}
