import AppKit
import Foundation
import simd
import SixAxisCore

/// Section view: cuts the bodies at a plane (view only – nothing changes in the model).
struct SectionView: Equatable {
    /// 0 = X, 1 = Y, 2 = Z: the plane's normal axis.
    var axis = 1
    var offset: Double = 0
    /// Keep the other side.
    var flip = false

    var normal: Vec3 {
        var n = Vec3.zero
        n[axis] = flip ? 1 : -1
        return n
    }

    /// Normal and offset for the shaders: points with dot(p, n) > d are cut away.
    var clip: SIMD4<Float> {
        let n = normal
        var p = Vec3.zero
        p[axis] = offset
        return SIMD4(Float(n.x), Float(n.y), Float(n.z), Float(simd_dot(n, p)))
    }
}

extension Editor {
    /// Extent of the visible bodies along an axis (for the section slider).
    func modelRange(axis: Int) -> ClosedRange<Double> {
        var lo = Double.greatestFiniteMagnitude, hi = -lo
        for b in state.orderedBodies where doc.isBodyVisible(b.id) {
            if let bb = b.shape.boundingBox { lo = min(lo, bb.min[axis]); hi = max(hi, bb.max[axis]) }
        }
        return lo <= hi ? lo...hi : -50...50
    }

    func toggleSection() {
        if section != nil {
            section = nil
        } else {
            var s = SectionView()
            let r = modelRange(axis: s.axis)
            s.offset = ((r.lowerBound + r.upperBound) / 2).rounded()
            section = s
        }
        sceneVersion &+= 1
        requestRedraw()
    }

    // MARK: Measure

    func toggleMeasure() {
        if measuring { endMeasure(); return }
        if command != nil { commitCommand() }
        if sketchId != nil { finishSketch() }
        selection.removeAll()
        measuring = true
        measurePicks = []
        measureResult = nil
        sceneVersion &+= 1
        requestRedraw()
    }

    func endMeasure() {
        measuring = false
        measurePicks = []
        measureResult = nil
        sceneVersion &+= 1
        requestRedraw()
    }

    func measureClick(_ p: Pick) {
        switch p {
        case .face, .edge: break
        default: return
        }
        // A third pick starts a new measurement; clicking a pick again removes it.
        if let i = measurePicks.firstIndex(of: p) { measurePicks.remove(at: i) }
        else if measurePicks.count >= 2 { measurePicks = [p] }
        else { measurePicks.append(p) }
        let targets: [Measure.Target] = measurePicks.compactMap { p in
            switch p {
            case let .face(b, i): return state.bodies[b].map { .face($0, i) }
            case let .edge(b, i): return state.bodies[b].map { .edge($0, i) }
            default: return nil
            }
        }
        measureResult = targets.isEmpty ? nil : Measure.measure(targets)
        sceneVersion &+= 1
        requestRedraw()
    }

    func setSectionAxis(_ axis: Int) {
        guard var s = section else { return }
        s.axis = axis
        let r = modelRange(axis: axis)
        s.offset = ((r.lowerBound + r.upperBound) / 2).rounded()
        section = s
        requestRedraw()
    }
}
