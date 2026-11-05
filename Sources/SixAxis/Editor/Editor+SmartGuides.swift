import AppKit
import simd
import SixAxisCore

/// Dotted line from a noted point to where the next point lands, shown with their distance.
struct SmartGuide: Equatable {
    var from: Vec2
    var to: Vec2
}

/// Help while drawing: resting on a point notes it, and the cursor then lines up with it horizontally and
/// vertically; a line snaps to the usual angles. ⌘ turns all of it off and places the point freely.
extension Editor {
    private static let dwell: TimeInterval = 0.35
    private static let maxNotedPoints = 2
    /// How close the cursor must come, in points on the screen.
    private static let reach = 6.0
    private static let usualAngles: [Double] = stride(from: 0, to: 360, by: 15).map(Double.init).filter { Int($0) % 30 == 0 || Int($0) % 45 == 0 }

    var isDrawingTool: Bool {
        switch sketchTool {
        case .line, .rectangle, .centerRectangle, .circle, .arc, .spline: return true
        default: return false
        }
    }

    /// ⌘ is held. Automated runs ignore the real keyboard: someone working at the Mac meanwhile must not change them.
    var isCommandHeld: Bool {
        Self.isAutomatedRun ? freePlacementInChecks : NSEvent.modifierFlags.contains(.command)
    }

    /// ⌘ held while drawing: no snapping of any kind.
    var isFreePlacement: Bool { isDrawingTool && isCommandHeld }

    /// Notes the point under the cursor once it has rested there for a moment.
    func updateDwell() {
        guard isDrawingTool, !isFreePlacement, case let .sketchPoint(s, p)? = hover, s == sketchId else {
            dwellPoint = nil
            return
        }
        guard dwellPoint != p else { return }
        dwellPoint = p
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell) { [weak self] in
            guard let self, self.dwellPoint == p else { return }
            self.notedPoints.removeAll { $0 == p }
            self.notedPoints.append(p)
            if self.notedPoints.count > Self.maxNotedPoints { self.notedPoints.removeFirst() }
            self.requestRedraw()
        }
    }

    func clearSmartGuides() {
        dwellPoint = nil
        overlayHover = nil
        if !notedPoints.isEmpty { notedPoints = [] }
        setSmartGuides([], angle: nil)
    }

    func setSmartGuides(_ guides: [SmartGuide], angle: Double?) {
        if smartGuides != guides { smartGuides = guides }
        if smartAngle != angle { smartAngle = angle }
    }

    /// The direction a line keeps while its end is dragged: fixed by a constraint, or near its own direction
    /// (pulling it longer) or a usual angle. Only for the free end of a single line.
    func dragDirection(for p: Int, at cursor: Vec2, in sk: Sketch, original: Sketch) -> (from: Vec2, direction: Vec2, held: Bool, angle: Double?)? {
        let own = sk.curves.filter { $0.geometry.pointIds.contains(p) }
        guard own.count == 1, let line = own.first, case let .line(a, b) = line.geometry else { return nil }
        let other = a == p ? b : a
        guard let from = sk.point(other), let was = original.point(p), let wasFrom = original.point(other) else { return nil }
        let held = sk.constraints.first { c in
            switch c.kind {
            case let .horizontal(l), let .vertical(l): return l == line.id
            default: return false
            }
        }
        if let held {
            if case .horizontal = held.kind { return (from, Vec2(1, 0), true, nil) }
            return (from, Vec2(0, 1), true, nil)
        }
        let d = cursor - from
        let reach = Self.reach * Double(camera.worldPerPoint)
        guard simd_length(d) > reach * 2 else { return nil }
        let wasDirection = was - wasFrom
        if simd_length(wasDirection) > 1e-9 {
            let u = simd_normalize(wasDirection)
            if abs(u.x * d.y - u.y * d.x) < reach, simd_dot(u, d) > 0 { return (from, u, false, nil) }
        }
        if let angle = usualAngle(from: from, to: cursor) {
            return (from, Vec2(cos(angle * .pi / 180), sin(angle * .pi / 180)), false, angle)
        }
        return nil
    }

    /// What a dragged point lands on near `cursor`: another point first, then a curve, where the line's direction
    /// crosses it if it keeps one. Not the curves it belongs to, and not the other end of its own line.
    func dropTarget(for p: Int, at cursor: Vec2, in sk: Sketch, original: Sketch) -> (point: Int?, curve: Int?, position: Vec2)? {
        guard !isCommandHeld else { return nil }
        let reach = 8 * Double(camera.worldPerPoint)
        let own = sk.curves.filter { $0.geometry.pointIds.contains(p) }
        let neighbours = Set(own.flatMap(\.geometry.pointIds))
        let nearPoint = sk.points.filter { !neighbours.contains($0.id) && $0.id != p && simd_distance($0.position, cursor) < reach }
            .min { simd_distance($0.position, cursor) < simd_distance($1.position, cursor) }
        if let q = nearPoint { return (q.id, nil, q.position) }
        let ownIds = Set(own.map(\.id))
        let keep = dragDirection(for: p, at: cursor, in: sk, original: original)
        let along = keep.map { $0.from + $0.direction * simd_dot(cursor - $0.from, $0.direction) } ?? cursor
        var best: (curve: Int, position: Vec2, distance: Double)?
        for curve in sk.curves where !ownIds.contains(curve.id) && !curve.isText && curve.polygon == nil {
            var on: Vec2?
            if let keep { on = crossing(of: curve, sk, through: keep.from, keep.direction, near: along) }
            if on == nil, keep?.held != true {
                let closest = closestPoint(on: curve, sk, to: cursor)
                if simd_distance(closest, cursor) < reach { on = closest }
            }
            guard let on else { continue }
            let distance = simd_distance(on, along)
            if distance < best?.distance ?? .infinity { best = (curve.id, on, distance) }
        }
        return best.map { (nil, $0.curve, $0.position) }
    }

    /// Connects a dragged point to what it was let go on. A connection the sketch cannot satisfy is left out.
    func connectDraggedPoint(_ ds: DragState) {
        dropMarker = nil
        if dragAngleMark != nil { dragAngleMark = nil }
        guard case let .sketchPoint(_, p)? = ds.pick, ds.dropPoint != nil || ds.dropCurve != nil, let id = sketchId, var sk = activeSketch else { return }
        if let q = ds.dropPoint {
            sk.merge(point: p, into: q)
        } else if let c = ds.dropCurve {
            sk.addConstraint(.pointOnCurve(point: p, curve: c))
        }
        let result = SketchSolver(evaluator: evaluator).solve(&sk)
        guard result.converged else {
            showToast(String(localized: "Verbinden nicht möglich – die Skizze wäre überbestimmt"))
            return
        }
        lastSolve = result
        selection.removeAll { $0 == .sketchPoint(id, p) }
        doc.update(id) { $0.kind = .sketch(sk) }
        rebuild()
    }

    /// The usual angle the line being drawn has, if this tool draws one.
    func lineAngle(from start: Vec2, to raw: Vec2) -> Double? {
        guard sketchTool == .line || (sketchTool == .arc && toolPoints.count == 1) else { return nil }
        return usualAngle(from: start, to: raw)
    }

    /// Records a snapped angle (horizontal and vertical lines also become constraints). Returns its direction.
    @discardableResult
    func noteAngle(_ angle: Double) -> Vec2 {
        switch angle {
        case 0, 180:
            if sketchTool == .line { inference = .horizontal }
            return Vec2(1, 0)
        case 90, 270:
            if sketchTool == .line { inference = .vertical }
            return Vec2(0, 1)
        default:
            smartAngle = angle
            return Vec2(cos(angle * .pi / 180), sin(angle * .pi / 180))
        }
    }

    /// On another curve the angle or guide stays: the point is where its line crosses the curve, not the nearest
    /// point of the curve. nil when there is none, or it crosses too far away (almost parallel).
    func keepingAngleOrGuide(on curve: SketchCurve, _ sk: Sketch, raw: Vec2) -> Vec2? {
        guard isDrawingTool, !isFreePlacement, !hasLockedInput else { return nil }
        if let start = toolPoints.last?.position, let angle = lineAngle(from: start, to: raw) {
            let direction = angle == 0 || angle == 180 ? Vec2(1, 0) : (angle == 90 || angle == 270 ? Vec2(0, 1) : Vec2(cos(angle * .pi / 180), sin(angle * .pi / 180)))
            guard let crossing = crossing(of: curve, sk, through: start, direction, near: raw) else { return nil }
            noteAngle(angle)
            return crossing
        }
        let reach = Self.reach * Double(camera.worldPerPoint)
        for p in notedPoints.compactMap({ sk.point($0) }) {
            let line = abs(p.x - raw.x) < reach ? Vec2(0, 1) : (abs(p.y - raw.y) < reach ? Vec2(1, 0) : nil)
            if let line, let crossing = crossing(of: curve, sk, through: p, line, near: raw) {
                if simd_distance(p, crossing) > 1e-9 { setSmartGuides([SmartGuide(from: p, to: crossing)], angle: nil) }
                return crossing
            }
        }
        return nil
    }

    /// Where the endless line through `origin` crosses the curve, nearest to `raw` and close to it.
    private func crossing(of curve: SketchCurve, _ sk: Sketch, through origin: Vec2, _ direction: Vec2, near raw: Vec2) -> Vec2? {
        let line = sk.polyline(curve, segments: 360)
        var best: Vec2?
        for (a, b) in zip(line, line.dropFirst()) {
            let e = b - a
            let denominator = direction.x * e.y - direction.y * e.x
            guard abs(denominator) > 1e-9 else { continue }
            let w = a - origin
            let along = -(direction.x * w.y - direction.y * w.x) / denominator   // position on the segment, 0…1
            guard along >= -1e-9, along <= 1 + 1e-9 else { continue }
            let point = a + e * max(0, min(1, along))
            if simd_distance(point, raw) < simd_distance(best ?? point + Vec2(1e12, 0), raw) { best = point }
        }
        guard let best, simd_distance(best, raw) < 4 * Self.reach * Double(camera.worldPerPoint) else { return nil }
        return best
    }

    /// The usual angle a line from `start` to `raw` is meant to have, if any: nil when it is clearly another one.
    func usualAngle(from start: Vec2, to raw: Vec2) -> Double? {
        let d = raw - start
        let reach = Self.reach * Double(camera.worldPerPoint)
        guard simd_length(d) > reach * 2 else { return nil }
        let angle = (atan2(d.y, d.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        func off(_ a: Double) -> Double { let x = abs(a - angle).truncatingRemainder(dividingBy: 360); return min(x, 360 - x) }
        guard let best = Self.usualAngles.min(by: { off($0) < off($1) }) else { return nil }
        let sideways = simd_length(d) * sin(off(best) * .pi / 180)
        return sideways < reach || off(best) < 1.5 ? best : nil
    }

    /// Lines `pos` up with the noted points and records the guides. `direction`: `pos` must stay on this line
    /// from `start` (an angle has snapped), so only the distance along it can change.
    func alignWithNotedPoints(_ pos: Vec2, raw: Vec2, sketch sk: Sketch, start: Vec2?, direction: Vec2?) -> Vec2 {
        let reach = Self.reach * Double(camera.worldPerPoint)
        let points = notedPoints.compactMap { sk.point($0) }
        let forX = points.filter { abs($0.x - raw.x) < reach }.min { abs($0.x - raw.x) < abs($1.x - raw.x) }
        let forY = points.filter { abs($0.y - raw.y) < reach }.min { abs($0.y - raw.y) < abs($1.y - raw.y) }
        var out = pos
        var used: [Vec2] = []
        if let direction, let start {
            // On a fixed line one alignment decides the point: the nearer one that does not leave the line.
            if let p = forX, abs(direction.x) > 1e-6 {
                out = start + direction * ((p.x - start.x) / direction.x)
                used = [p]
            } else if let p = forY, abs(direction.y) > 1e-6 {
                out = start + direction * ((p.y - start.y) / direction.y)
                used = [p]
            }
        } else {
            if let p = forX { out.x = p.x; used.append(p) }
            if let p = forY { out.y = p.y; used.append(p) }
        }
        let guides = used.filter { simd_distance($0, out) > 1e-9 }.map { SmartGuide(from: $0, to: out) }
        if smartGuides != guides { smartGuides = guides }
        return out
    }
}
