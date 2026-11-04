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

    /// ⌘ held while drawing: no snapping of any kind.
    var isFreePlacement: Bool {
        isDrawingTool && (freePlacementInChecks || NSEvent.modifierFlags.contains(.command))
    }

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

    /// What a dragged point lands on near `cursor`: another point first, then a curve. Not the ones it already
    /// belongs to, and not the other end of its own line (the line would vanish).
    func dropTarget(for p: Int, at cursor: Vec2, in sk: Sketch) -> (point: Int?, curve: Int?, position: Vec2)? {
        guard !(freePlacementInChecks || NSEvent.modifierFlags.contains(.command)) else { return nil }
        let reach = 8 * Double(camera.worldPerPoint)
        let own = sk.curves.filter { $0.geometry.pointIds.contains(p) }
        let neighbours = Set(own.flatMap(\.geometry.pointIds))
        let nearPoint = sk.points.filter { !neighbours.contains($0.id) && $0.id != p && simd_distance($0.position, cursor) < reach }
            .min { simd_distance($0.position, cursor) < simd_distance($1.position, cursor) }
        if let q = nearPoint { return (q.id, nil, q.position) }
        let ownIds = Set(own.map(\.id))
        var best: (curve: Int, position: Vec2, distance: Double)?
        for curve in sk.curves where !ownIds.contains(curve.id) && !curve.isText && curve.polygon == nil {
            let on = closestPoint(on: curve, sk, to: cursor)
            let distance = simd_distance(on, cursor)
            if distance < reach, distance < best?.distance ?? .infinity { best = (curve.id, on, distance) }
        }
        return best.map { (nil, $0.curve, $0.position) }
    }

    /// Connects a dragged point to what it was let go on. A connection the sketch cannot satisfy is left out.
    func connectDraggedPoint(_ ds: DragState) {
        dropMarker = nil
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
