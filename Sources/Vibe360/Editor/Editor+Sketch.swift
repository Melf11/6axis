import AppKit
import Foundation
import simd
import VibeCore

extension Editor {
    var activeSketch: Sketch? { sketchId.flatMap { doc.feature($0)?.kind.sketch } }
    var activeSketchBuild: SketchBuild? { sketchId.flatMap { state.sketches[$0] } }
    var activePlane: Plane? { activeSketchBuild?.plane }

    // MARK: - Enter / leave

    func beginSketch(on plane: PlaneRef, tool: SketchTool? = nil) {
        let sk = Sketch(plane: plane)
        let f = Feature(name: doc.nextName(for: .sketch(sk)), kind: .sketch(sk))
        let before = command?.snapshot ?? doc
        command = nil
        doc = before
        let insertAt = doc.activeCount
        doc.features.insert(f, at: insertAt)
        if let r = doc.rollback { doc.rollback = r + 1 }
        pushUndo(before)
        rebuild()
        if state.errors[f.id] != nil {
            showToast(state.errors[f.id]!)
        }
        enterSketch(f.id, rollbackBefore: doc.rollback)
        sketchTool = tool ?? .select
        if tool == nil { showToast("Skizze erstellt – wähle ein Werkzeug (L Linie, R Rechteck, C Kreis)") }
    }

    func editSketch(_ id: UUID) {
        guard let idx = doc.index(of: id) else { return }
        let previous = doc.rollback
        doc.rollback = idx + 1 == doc.features.count ? nil : idx + 1
        rebuild()
        enterSketch(id, rollbackBefore: previous)
    }

    private func enterSketch(_ id: UUID, rollbackBefore: Int?) {
        sketchId = id
        sketchRollbackBefore = rollbackBefore
        selection.removeAll()
        toolPoints.removeAll()
        editingDimension = nil
        solveActiveSketch(store: false)
        lookAtSketchPlane()
    }

    func lookAtSketchPlane() {
        guard let plane = activePlane else { return }
        var c = camera
        c.orientation = Camera.lookOrientation(direction: -plane.normal.float, up: plane.yDir.float)
        let t = c.target
        let tp = plane.point(plane.project(Vec3(Double(t.x), Double(t.y), Double(t.z))))
        c.target = tp.float
        animateCamera(to: c)
    }

    func finishSketch() {
        guard sketchId != nil else { return }
        doc.rollback = sketchRollbackBefore
        sketchId = nil
        sketchTool = .select
        toolPoints.removeAll()
        selection.removeAll()
        editingDimension = nil
        dimensionFirst = nil
        constraintPicks.removeAll()
        lastSolve = nil
        rebuild()
    }

    // MARK: - Mutation

    /// Applies a change to the active sketch, re-solves, and records an undo step.
    @discardableResult
    func mutateSketch<T>(undoable: Bool = true, _ change: (inout Sketch) -> T) -> T? {
        guard let id = sketchId, var sk = activeSketch else { return nil }
        let before = doc
        let result = change(&sk)
        lastSolve = SketchSolver(evaluator: evaluator).solve(&sk)
        doc.update(id) { $0.kind = .sketch(sk) }
        if undoable { pushUndo(before) }
        rebuild()
        return result
    }

    /// Adds a constraint unless it would over-constrain the sketch.
    @discardableResult
    func addConstraintChecked(_ kind: ConstraintKind, labelOffset: Vec2 = .zero) -> Int? {
        guard let id = sketchId, var sk = activeSketch else { return nil }
        let cid = sk.addConstraint(kind, labelOffset: labelOffset)
        let r = SketchSolver(evaluator: evaluator).solve(&sk)
        guard r.converged else {
            showToast("Abhängigkeit nicht möglich – die Skizze wäre überbestimmt")
            return nil
        }
        let before = doc
        doc.update(id) { $0.kind = .sketch(sk) }
        lastSolve = r
        pushUndo(before)
        rebuild()
        return cid
    }

    func solveActiveSketch(store: Bool) {
        guard let id = sketchId, var sk = activeSketch else { return }
        lastSolve = SketchSolver(evaluator: evaluator).solve(&sk)
        if store {
            doc.update(id) { $0.kind = .sketch(sk) }
            rebuild()
        }
    }

    // MARK: - Cursor & snapping

    func sketchPosition(at pt: CGPoint) -> Vec2? {
        guard let plane = activePlane else { return nil }
        let r = camera.rayD(at: pt)
        guard let hit = plane.intersect(rayOrigin: r.origin, direction: r.direction) else { return nil }
        return plane.project(hit)
    }

    func snap(at pt: CGPoint) -> SnapTarget? {
        guard let sid = sketchId, let sk = activeSketch, let raw = sketchPosition(at: pt) else { return nil }
        inference = nil
        switch hover {
        case let .sketchPoint(s, p) where s == sid:
            if let pos = sk.point(p) { return SnapTarget(position: pos, point: p) }
        case let .sketchCurve(s, c) where s == sid:
            if let curve = sk.curve(c) { return SnapTarget(position: closestPoint(on: curve, sk, to: raw), curve: c) }
        default:
            break
        }
        var pos = raw
        if let start = toolPoints.last?.position, [.line, .rectangle, .centerRectangle].contains(sketchTool) || sketchTool == .arc {
            let d = raw - start
            let tol = 4.0 * Double(camera.worldPerPoint)
            if sketchTool == .line, simd_length(d) > tol * 3 {
                if abs(d.y) < tol * 1.5 || abs(d.y) < abs(d.x) * 0.035 {
                    pos.y = start.y; inference = .horizontal
                } else if abs(d.x) < tol * 1.5 || abs(d.x) < abs(d.y) * 0.035 {
                    pos.x = start.x; inference = .vertical
                }
            }
        }
        return SnapTarget(position: pos)
    }

    func closestPoint(on curve: SketchCurve, _ sk: Sketch, to p: Vec2) -> Vec2 {
        switch curve.geometry {
        case let .line(a, b):
            guard let pa = sk.point(a), let pb = sk.point(b) else { return p }
            let d = pb - pa
            let t = max(0, min(1, simd_dot(p - pa, d) / max(simd_length_squared(d), 1e-12)))
            return pa + t * d
        case .circle, .arc:
            guard let c = sk.center(of: curve) else { return p }
            let r = sk.radius(of: curve)
            let v = p - c
            return simd_length(v) < 1e-12 ? c + Vec2(r, 0) : c + simd_normalize(v) * r
        }
    }

    /// Resolves a snap into a point id, creating a point (and point-on-curve constraint) if needed.
    func resolvePoint(_ s: SnapTarget, _ sk: inout Sketch) -> Int {
        if let p = s.point, sk.point(p) != nil { return p }
        let id = sk.addPoint(s.position)
        if let c = s.curve { sk.addConstraint(.pointOnCurve(point: id, curve: c)) }
        return id
    }

    // MARK: - Tools

    func setSketchTool(_ tool: SketchTool) {
        guard sketchId != nil else {
            beginCommand(.sketchPlane, pendingTool: tool)
            return
        }
        sketchTool = tool
        toolPoints.removeAll()
        dimensionFirst = nil
        constraintPicks.removeAll()
        editingDimension = nil
        if case let .constraint(ct) = tool {
            let picks = selection.filter { if case .sketchPoint = $0 { return true }; if case .sketchCurve = $0 { return true }; return false }
            if !picks.isEmpty, applyConstraint(ct, picks) {
                selection.removeAll()
                sketchTool = .select
            }
        }
        requestRedraw()
    }

    func cancelSketchTool() {
        if !toolPoints.isEmpty || dimensionFirst != nil || !constraintPicks.isEmpty {
            toolPoints.removeAll()
            dimensionFirst = nil
            dimensionSecond = nil
            constraintPicks.removeAll()
        } else if sketchTool != .select {
            sketchTool = .select
        } else if !selection.isEmpty {
            selection.removeAll()
        }
        requestRedraw()
    }

    func sketchClick(at pt: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        switch sketchTool {
        case .select:
            if let h = hover {
                if modifiers.contains(.shift) || modifiers.contains(.command) {
                    if let i = selection.firstIndex(of: h) { selection.remove(at: i) } else { selection.append(h) }
                } else {
                    selection = [h]
                }
                if clickCount == 2, case let .constraint(_, cid) = h, activeSketch?.constraints.first(where: { $0.id == cid })?.kind.isDimension == true {
                    editingDimension = cid
                }
            } else {
                selection.removeAll()
            }
        case .line: lineClick(pt, clickCount: clickCount)
        case .rectangle, .centerRectangle: rectangleClick(pt)
        case .circle: circleClick(pt)
        case .arc: arcClick(pt)
        case .dimension: dimensionClick(pt)
        case let .constraint(ct): constraintClick(ct)
        }
        requestRedraw()
    }

    private func lineClick(_ pt: CGPoint, clickCount: Int) {
        guard let s = snap(at: pt) else { return }
        if clickCount == 2 { toolPoints.removeAll(); return }
        guard let start = toolPoints.first else {
            toolPoints = [s]
            chainStart = s.point
            return
        }
        guard simd_distance(start.position, s.position) > 1e-6 else { return }
        let inf = inference
        let endId: Int? = mutateSketch { sk in
            let a = resolvePoint(start, &sk)
            let b = resolvePoint(s, &sk)
            let l = sk.addLine(a, b)
            if inf == .horizontal { sk.addConstraint(.horizontal(line: l)) }
            if inf == .vertical { sk.addConstraint(.vertical(line: l)) }
            if chainStart == nil { chainStart = a }
            return b
        }
        if let endId, let pos = activeSketch?.point(endId) {
            if s.point != nil && s.point == chainStart {
                toolPoints.removeAll()   // closed loop
                chainStart = nil
            } else {
                toolPoints = [SnapTarget(position: pos, point: endId)]
            }
        }
    }

    private func rectangleClick(_ pt: CGPoint) {
        guard let s = snap(at: pt) else { return }
        guard let first = toolPoints.first else { toolPoints = [s]; return }
        let centered = sketchTool == .centerRectangle
        let a = first.position, b = s.position
        let lo = centered ? a - (b - a) : a
        guard abs(b.x - lo.x) > 1e-6, abs(b.y - lo.y) > 1e-6 else { return }
        mutateSketch { sk in
            let corners = [lo, Vec2(b.x, lo.y), b, Vec2(lo.x, b.y)]
            var ids = corners.map { sk.addPoint($0) }
            if !centered, let p = first.point, sk.point(p) != nil { sk.merge(point: ids[0], into: p); ids[0] = p }
            if let p = s.point, sk.point(p) != nil { sk.merge(point: ids[2], into: p); ids[2] = p }
            let l = (0..<4).map { sk.addLine(ids[$0], ids[($0 + 1) % 4]) }
            sk.addConstraint(.horizontal(line: l[0]))
            sk.addConstraint(.horizontal(line: l[2]))
            sk.addConstraint(.vertical(line: l[1]))
            sk.addConstraint(.vertical(line: l[3]))
            if centered {
                let diag = sk.addLine(ids[0], ids[2], construction: true)
                let c = resolvePoint(first, &sk)
                sk.addConstraint(.midpoint(point: c, line: diag))
            }
        }
        toolPoints.removeAll()
    }

    private func circleClick(_ pt: CGPoint) {
        guard let s = snap(at: pt) else { return }
        guard let center = toolPoints.first else { toolPoints = [s]; return }
        let r = simd_distance(center.position, s.position)
        guard r > 1e-6 else { return }
        mutateSketch { sk in
            let c = resolvePoint(center, &sk)
            let circle = sk.addCircle(center: c, radius: r)
            if let p = s.point { sk.addConstraint(.pointOnCurve(point: p, curve: circle)) }
        }
        toolPoints.removeAll()
    }

    private func arcClick(_ pt: CGPoint) {
        guard let s = snap(at: pt) else { return }
        if toolPoints.count < 2 {
            if let last = toolPoints.last, simd_distance(last.position, s.position) < 1e-6 { return }
            toolPoints.append(s)
            return
        }
        let a = toolPoints[0], b = toolPoints[1]
        guard let (center, _) = circleThrough(a.position, s.position, b.position) else { return }
        let ccw = arcIsCCW(center: center, start: a.position, end: b.position, through: s.position)
        mutateSketch { sk in
            let pa = resolvePoint(a, &sk), pb = resolvePoint(b, &sk)
            let pc = sk.addPoint(center)
            if ccw { sk.addArc(center: pc, start: pa, end: pb) } else { sk.addArc(center: pc, start: pb, end: pa) }
        }
        toolPoints.removeAll()
    }

    func arcIsCCW(center: Vec2, start: Vec2, end: Vec2, through: Vec2) -> Bool {
        func ang(_ p: Vec2) -> Double { atan2(p.y - center.y, p.x - center.x) }
        let a0 = ang(start)
        return normalizedAngle(ang(through) - a0) < normalizedAngle(ang(end) - a0)
    }

    // MARK: - Dimensions

    private func dimensionClick(_ pt: CGPoint) {
        guard let sid = sketchId, let sk = activeSketch, let pos = sketchPosition(at: pt) else { return }
        let picked: Pick? = {
            switch hover {
            case let .sketchPoint(s, _) where s == sid: return hover
            case let .sketchCurve(s, _) where s == sid: return hover
            default: return nil
            }
        }()

        if let first = dimensionFirst {
            if let p = picked, p != first, dimensionSecond == nil {
                // Two entities chosen: point-point waits for placement, others are created right away.
                if case .sketchPoint = first, case .sketchPoint = p {
                    dimensionSecond = p
                    return
                }
                createDimension(first, p, placement: pos, sk)
            } else if let second = dimensionSecond {
                createDimension(first, second, placement: pos, sk)
            } else if case let .sketchCurve(_, cid) = first, let c = sk.curve(cid), c.isLine {
                createLengthDimension(cid, placement: pos, sk)
            }
            dimensionFirst = nil
            dimensionSecond = nil
            return
        }

        guard let p = picked else { return }
        if case let .sketchCurve(_, cid) = p, let c = sk.curve(cid) {
            switch c.geometry {
            case .circle:
                let d = 2 * sk.radius(of: c)
                if let id = addConstraintChecked(.diameter(curve: cid, value: plainNumber(d)), labelOffset: pos - (sk.center(of: c) ?? .zero)) {
                    editingDimension = id
                }
                return
            case .arc:
                let r = sk.radius(of: c)
                if let id = addConstraintChecked(.radius(curve: cid, value: plainNumber(r)), labelOffset: pos - (sk.center(of: c) ?? .zero)) {
                    editingDimension = id
                }
                return
            case .line:
                break
            }
        }
        dimensionFirst = p
    }

    private func createLengthDimension(_ cid: Int, placement: Vec2, _ sk: Sketch) {
        guard let c = sk.curve(cid), case let .line(a, b) = c.geometry, let pa = sk.point(a), let pb = sk.point(b) else { return }
        let mid = (pa + pb) / 2
        if let id = addConstraintChecked(.length(line: cid, value: plainNumber(simd_distance(pa, pb))), labelOffset: placement - mid) {
            editingDimension = id
        }
    }

    private func createDimension(_ p1: Pick, _ p2: Pick, placement: Vec2, _ sk: Sketch) {
        var kind: ConstraintKind?
        var anchor = Vec2.zero
        switch (p1, p2) {
        case let (.sketchPoint(_, a), .sketchPoint(_, b)):
            guard let pa = sk.point(a), let pb = sk.point(b) else { return }
            anchor = (pa + pb) / 2
            let lo = simd_min(pa, pb), hi = simd_max(pa, pb)
            let margin = 2 * Double(camera.worldPerPoint)
            let outsideY = placement.y > hi.y + margin || placement.y < lo.y - margin
            let outsideX = placement.x > hi.x + margin || placement.x < lo.x - margin
            if outsideY && !outsideX {
                kind = .horizontalDistance(a, b, value: plainNumber(abs(pb.x - pa.x)))
            } else if outsideX && !outsideY {
                kind = .verticalDistance(a, b, value: plainNumber(abs(pb.y - pa.y)))
            } else {
                kind = .distance(a, b, value: plainNumber(simd_distance(pa, pb)))
            }
        case let (.sketchPoint(_, p), .sketchCurve(_, l)), let (.sketchCurve(_, l), .sketchPoint(_, p)):
            guard let c = sk.curve(l), case let .line(a, b) = c.geometry, let pp = sk.point(p),
                  let pa = sk.point(a), let pb = sk.point(b) else { return }
            let d = simd_normalize(pb - pa)
            let dist = abs(d.x * (pp.y - pa.y) - d.y * (pp.x - pa.x))
            anchor = (pp + closestPoint(on: c, sk, to: pp)) / 2
            kind = .pointLineDistance(point: p, line: l, value: plainNumber(dist))
        case let (.sketchCurve(_, l1), .sketchCurve(_, l2)):
            guard let c1 = sk.curve(l1), let c2 = sk.curve(l2), case let .line(a1, b1) = c1.geometry,
                  case let .line(a2, b2) = c2.geometry, let pa1 = sk.point(a1), let pb1 = sk.point(b1),
                  let pa2 = sk.point(a2), let pb2 = sk.point(b2) else { return }
            let d1 = pb1 - pa1, d2 = pb2 - pa2
            let cross = d1.x * d2.y - d1.y * d2.x
            let sinAngle = abs(cross) / max(simd_length(d1) * simd_length(d2), 1e-12)
            if sinAngle < 0.01 {
                let n = simd_normalize(d1)
                let dist = abs(n.x * (pa2.y - pa1.y) - n.y * (pa2.x - pa1.x))
                anchor = ((pa1 + pb1) / 2 + (pa2 + pb2) / 2) / 2
                kind = .pointLineDistance(point: a2, line: l1, value: plainNumber(dist))
            } else {
                let angle = abs(atan2(cross, simd_dot(d1, d2))) * 180 / .pi
                anchor = ((pa1 + pb1) / 2 + (pa2 + pb2) / 2) / 2
                kind = .angle(l1, l2, value: plainNumber(angle))
            }
        default:
            return
        }
        if let kind, let id = addConstraintChecked(kind, labelOffset: placement - (dimensionAnchor(kind, sk) ?? anchor)) {
            editingDimension = id
        }
    }

    /// Reference point that a dimension's label offset is measured from.
    func dimensionAnchor(_ kind: ConstraintKind, _ sk: Sketch) -> Vec2? {
        func lineMid(_ l: Int) -> Vec2? {
            guard let c = sk.curve(l), case let .line(a, b) = c.geometry, let pa = sk.point(a), let pb = sk.point(b) else { return nil }
            return (pa + pb) / 2
        }
        switch kind {
        case let .distance(a, b, _), let .horizontalDistance(a, b, _), let .verticalDistance(a, b, _):
            guard let pa = sk.point(a), let pb = sk.point(b) else { return nil }
            return (pa + pb) / 2
        case let .length(l, _):
            return lineMid(l)
        case let .pointLineDistance(p, l, _):
            guard let pp = sk.point(p), let c = sk.curve(l) else { return nil }
            return (pp + footPoint(pp, on: c, sk)) / 2
        case let .radius(c, _), let .diameter(c, _):
            return sk.curve(c).flatMap { sk.center(of: $0) }
        case let .angle(l1, l2, _):
            guard let m1 = lineMid(l1), let m2 = lineMid(l2) else { return nil }
            return (m1 + m2) / 2
        default:
            return nil
        }
    }

    /// Perpendicular foot of a point on the infinite line of `curve`.
    func footPoint(_ p: Vec2, on curve: SketchCurve, _ sk: Sketch) -> Vec2 {
        guard case let .line(a, b) = curve.geometry, let pa = sk.point(a), let pb = sk.point(b) else { return p }
        let d = pb - pa
        let t = simd_dot(p - pa, d) / max(simd_length_squared(d), 1e-12)
        return pa + t * d
    }

    func plainNumber(_ v: Double) -> String {
        var s = String(format: "%.3f", (v * 1000).rounded() / 1000)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Commits a typed dimension value. Returns false if the value is invalid or conflicts.
    @discardableResult
    func setDimensionValue(_ cid: Int, _ text: String) -> Bool {
        guard let id = sketchId, var sk = activeSketch, let i = sk.constraints.firstIndex(where: { $0.id == cid }) else { return false }
        let kind = sk.constraints[i].kind
        do {
            let v = try evaluator.value(text, kind: kind.valueKind)
            if v <= 0 && kind.valueKind == .length { showToast("Wert muss größer als 0 sein"); return false }
        } catch {
            showToast(error.localizedDescription)
            return false
        }
        sk.constraints[i].kind = kind.withValue(text)
        let r = SketchSolver(evaluator: evaluator).solve(&sk)
        guard r.converged else {
            showToast("Dieser Wert lässt sich nicht erfüllen")
            return false
        }
        let before = doc
        doc.update(id) { $0.kind = .sketch(sk) }
        lastSolve = r
        pushUndo(before)
        rebuild()
        return true
    }

    func moveDimensionLabel(_ cid: Int, to offset: Vec2, undoable: Bool) {
        guard let id = sketchId, var sk = activeSketch, let i = sk.constraints.firstIndex(where: { $0.id == cid }) else { return }
        sk.constraints[i].labelOffset = offset
        doc.update(id) { $0.kind = .sketch(sk) }
        requestRedraw()
    }

    // MARK: - Constraints

    private func constraintClick(_ ct: ConstraintTool) {
        guard let h = hover else { return }
        switch h {
        case .sketchPoint, .sketchCurve: break
        default: return
        }
        constraintPicks.append(h)
        if applyConstraint(ct, constraintPicks) || constraintPicks.count >= 3 {
            constraintPicks.removeAll()
        }
    }

    /// Tries to create a constraint from the given picks. Returns true when the pick set was consumed.
    func applyConstraint(_ ct: ConstraintTool, _ picks: [Pick]) -> Bool {
        guard let sk = activeSketch else { return false }
        var points: [Int] = [], lines: [Int] = [], rounds: [Int] = []
        for p in picks {
            switch p {
            case let .sketchPoint(_, id): points.append(id)
            case let .sketchCurve(_, id):
                if sk.curve(id)?.isLine == true { lines.append(id) } else { rounds.append(id) }
            default: break
            }
        }
        var kinds: [ConstraintKind] = []
        switch ct {
        case .horizontal:
            if !lines.isEmpty { kinds = lines.map { .horizontal(line: $0) } }
            else if points.count == 2 { kinds = [.horizontalPoints(points[0], points[1])] }
        case .vertical:
            if !lines.isEmpty { kinds = lines.map { .vertical(line: $0) } }
            else if points.count == 2 { kinds = [.verticalPoints(points[0], points[1])] }
        case .coincident:
            if points.count == 2 {
                let (a, b) = points[1] == Sketch.originId ? (points[1], points[0]) : (points[0], points[1])
                mutateSketch { $0.merge(point: b, into: a) }
                return true
            }
            if points.count == 1, let c = (lines + rounds).first { kinds = [.pointOnCurve(point: points[0], curve: c)] }
        case .tangent:
            if lines.count == 1, rounds.count == 1 { kinds = [.tangent(lines[0], rounds[0])] }
            else if rounds.count == 2 { kinds = [.tangent(rounds[0], rounds[1])] }
        case .equal:
            if lines.count == 2 { kinds = [.equal(lines[0], lines[1])] }
            else if rounds.count == 2 { kinds = [.equal(rounds[0], rounds[1])] }
        case .parallel:
            if lines.count == 2 { kinds = [.parallel(lines[0], lines[1])] }
        case .perpendicular:
            if lines.count == 2 { kinds = [.perpendicular(lines[0], lines[1])] }
        case .collinear:
            if lines.count == 2 { kinds = [.collinear(lines[0], lines[1])] }
        case .concentric:
            if rounds.count == 2 { kinds = [.concentric(rounds[0], rounds[1])] }
        case .midpoint:
            if points.count == 1, lines.count == 1 { kinds = [.midpoint(point: points[0], line: lines[0])] }
        case .symmetric:
            if points.count == 2, lines.count == 1 { kinds = [.symmetric(points[0], points[1], line: lines[0])] }
        case .fix:
            let ids = points + (lines + rounds).flatMap { sk.curve($0)?.geometry.pointIds ?? [] }
            guard !ids.isEmpty else { return false }
            mutateSketch { s in
                let allFixed = ids.allSatisfy { id in s.points.first { $0.id == id }?.fixed == true }
                for id in ids { if let i = s.pointIndex(id), id != Sketch.originId { s.points[i].fixed = !allFixed } }
            }
            return true
        }
        guard !kinds.isEmpty else { return false }
        for k in kinds { addConstraintChecked(k) }
        return true
    }

    // MARK: - Editing

    func deleteSketchSelection() {
        guard sketchId != nil else { return }
        var curves = Set<Int>(), points = Set<Int>(), constraints = Set<Int>()
        for p in selection {
            switch p {
            case let .sketchCurve(_, c): curves.insert(c)
            case let .sketchPoint(_, pt): points.insert(pt)
            case let .constraint(_, c): constraints.insert(c)
            default: break
            }
        }
        guard !(curves.isEmpty && points.isEmpty && constraints.isEmpty) else { return }
        mutateSketch { $0.delete(curveIds: curves, pointIds: points, constraintIds: constraints) }
        selection.removeAll()
    }

    func toggleConstruction() {
        let curves = selection.compactMap { p -> Int? in if case let .sketchCurve(_, c) = p { return c }; return nil }
        guard !curves.isEmpty else { return }
        mutateSketch { sk in
            for c in curves { if let i = sk.curveIndex(c) { sk.curves[i].construction.toggle() } }
        }
    }

    // MARK: - Dragging sketch geometry

    func sketchDrag(to pt: CGPoint) {
        guard var ds = dragState, let original = ds.original, let start = ds.startSketchPos,
              let cur = sketchPosition(at: pt), let id = sketchId else { return }
        let delta = cur - start
        var sk = original
        var targets: [Int: Vec2] = [:]
        var radii: [Int: Double] = [:]
        switch ds.pick {
        case let .sketchPoint(_, p):
            if let pos = original.point(p) { targets[p] = pos + delta }
        case let .sketchCurve(_, c):
            guard let curve = original.curve(c) else { return }
            switch curve.geometry {
            case let .circle(center, _):
                radii[c] = simd_distance(original.point(center) ?? .zero, cur)
            default:
                for p in curve.geometry.pointIds { if let pos = original.point(p) { targets[p] = pos + delta } }
            }
        default:
            return
        }
        lastSolve = SketchSolver(evaluator: evaluator).drag(&sk, points: targets, radii: radii)
        doc.update(id) { $0.kind = .sketch(sk) }
        ds.moved = true
        dragState = ds
        rebuild()
    }
}
