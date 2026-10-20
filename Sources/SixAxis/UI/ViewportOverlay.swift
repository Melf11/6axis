import simd
import SwiftUI
import SixAxisCore

/// 2D overlay drawn on top of the Metal viewport: sketch tool previews, dimensions,
/// constraint glyphs and the extrude manipulator. Only interactive elements receive clicks.
struct ViewportOverlay: View {
    @Bindable var editor: Editor
    @State private var gizmoFocus: GizmoFocus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                drawToolPreview(ctx)
                drawDimensions(ctx)
                drawExtrudeArrow(ctx)
                drawHoleArrows(ctx)
                drawEdgeArrow(ctx)
                drawMoveManipulator(ctx)
                drawSplineHandles(ctx)
                drawMachineTool(ctx)
            }
            .allowsHitTesting(false)

            if editor.sketchId != nil {
                constraintGlyphs
                dimensionLabels
                splineHandleKnobs
                toolInputBoxes
            }
            extrudeHandle
            holeHandles
            edgeHandle
            moveHandles
        }
        .coordinateSpace(name: "overlay")
    }
    /// Live cutter position from a connected machine (work position + program zero of the milling setup).
    private func drawMachineTool(_ ctx: GraphicsContext) {
        let session = MachineSession.shared
        guard session.connected, editor.workspace == .cam, let origin = editor.camResult?.origin else { return }
        let tip = origin + session.snapshot.status.work
        guard let a = editor.camera.project(tip), let b = editor.camera.project(tip + Vec3(0, 0, 40)) else { return }
        var shaft = Path()
        shaft.move(to: a)
        shaft.addLine(to: b)
        ctx.stroke(shaft, with: .color(.red.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: a.x - 5, y: a.y - 5, width: 10, height: 10)), with: .color(.red))
    }


    // MARK: Helpers

    private var plane: Plane? { editor.activePlane }
    private var sketch: Sketch? { editor.activeSketch }

    private func screen(_ uv: Vec2) -> CGPoint? {
        guard let plane else { return nil }
        return editor.camera.project(plane.point(uv))
    }

    private func path(_ pts: [Vec2]) -> Path {
        var p = Path()
        let s = pts.compactMap(screen)
        guard s.count == pts.count, let first = s.first else { return p }
        p.move(to: first)
        for q in s.dropFirst() { p.addLine(to: q) }
        return p
    }

    private var accent: Color { .accentColor }
    private var dimColor: Color { editor.darkMode ? Color(white: 0.85) : Color(white: 0.2) }

    // MARK: Tool preview

    private func drawToolPreview(_ ctx: GraphicsContext) {
        guard editor.sketchId != nil, let cur = editor.cursor else { return }
        if let preview = editor.sketchTool == .offset ? editor.offsetPreview() : editor.patternPreview(), let sk = editor.activeSketch {
            let known = Set(sk.curves.map(\.id))
            for c in preview.curves where !known.contains(c.id) {
                ctx.stroke(path(preview.polyline(c, segments: 64)), with: .color(accent), style: StrokeStyle(lineWidth: 1.6, dash: [5, 3]))
            }
        }
        if let r = editor.textRequest, let h = editor.textRequestHeight, !r.text.isEmpty {
            let polys = TextOutline.polylines(TextOutline.contours(r.text, height: h, font: r.font, origin: r.anchor.position))
            for p in polys { ctx.stroke(path(p + (p.first.map { [$0] } ?? [])), with: .color(accent), style: StrokeStyle(lineWidth: 1.2, dash: [4, 2])) }
        }
        if editor.sketchTool == .trim, case let .sketchCurve(_, cid)? = editor.hover, let sk = editor.activeSketch,
           let piece = SketchEdit.trimPreview(sk, curve: cid, at: cur.position) {
            ctx.stroke(path(piece), with: .color(.red.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            return
        }
        let style = StrokeStyle(lineWidth: 1.6, dash: [5, 3])
        let c = cur.position

        if let snapPt = screen(c) {
            if cur.point != nil {
                ctx.stroke(Path(ellipseIn: CGRect(x: snapPt.x - 7, y: snapPt.y - 7, width: 14, height: 14)), with: .color(accent), lineWidth: 2)
            } else if cur.curve != nil {
                ctx.stroke(Path(CGRect(x: snapPt.x - 4, y: snapPt.y - 4, width: 8, height: 8)), with: .color(accent), lineWidth: 1.5)
            }
        }
        drawCursorMarker(ctx, cur)
        guard let p0 = editor.toolPoints.first?.position else { return }
        let e = editor.effectiveToolEnd(c)
        switch editor.sketchTool {
        case .line:
            ctx.stroke(path([p0, e]), with: .color(accent), style: style)
            if !editor.hasLockedInput, let inf = editor.inference, let s = screen((p0 + e) / 2) {
                badge(ctx, inf == .horizontal ? "H" : "V", at: CGPoint(x: s.x, y: s.y - 14))
            }
        case .rectangle, .centerRectangle:
            let lo = editor.sketchTool == .centerRectangle ? p0 - (e - p0) : p0
            ctx.stroke(path([lo, Vec2(e.x, lo.y), e, Vec2(lo.x, e.y), lo]), with: .color(accent), style: style)
        case .circle:
            let r = simd_distance(p0, e)
            let pts = (0...72).map { i -> Vec2 in
                let t = Double(i) / 72 * 2 * .pi
                return p0 + r * Vec2(cos(t), sin(t))
            }
            ctx.stroke(path(pts), with: .color(accent), style: style)
            var radius = Path()
            if let a = screen(p0), let b = screen(e) { radius.move(to: a); radius.addLine(to: b) }
            ctx.stroke(radius, with: .color(accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        case .arc:
            if editor.toolPoints.count == 1 {
                ctx.stroke(path([p0, e]), with: .color(accent), style: style)
            } else if editor.toolPoints.count == 2, let (center, r) = circleThrough(p0, e, editor.toolPoints[1].position) {
                let p1 = editor.toolPoints[1].position
                let ccw = editor.arcIsCCW(center: center, start: p0, end: p1, through: e)
                let (s, e) = ccw ? (p0, p1) : (p1, p0)
                let a0 = atan2(s.y - center.y, s.x - center.x)
                var sweep = normalizedAngle(atan2(e.y - center.y, e.x - center.x) - a0)
                if sweep < 1e-6 { sweep = 2 * .pi }
                let pts = (0...64).map { i -> Vec2 in
                    let t = a0 + sweep * Double(i) / 64
                    return center + r * Vec2(cos(t), sin(t))
                }
                ctx.stroke(path(pts), with: .color(accent), style: style)
                label(ctx, "R " + formatValue(r), near: e)
            }
        case .spline:
            let fit = editor.toolPoints.map(\.position) + [c]
            ctx.stroke(path(Spline.polyline(fit, closed: false, perSegment: 24)), with: .color(accent), style: style)
            for p in editor.toolPoints {
                if let s = screen(p.position) { ctx.fill(Path(ellipseIn: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6)), with: .color(accent)) }
            }
        default:
            break
        }
    }

    private var isDrawingTool: Bool {
        switch editor.sketchTool {
        case .line, .rectangle, .centerRectangle, .circle, .arc, .spline: return true
        default: return false
        }
    }

    /// Shows where the next point will be placed; before the first click also its coordinates.
    private func drawCursorMarker(_ ctx: GraphicsContext, _ cur: SnapTarget) {
        guard isDrawingTool else { return }
        let pos = editor.toolPoints.isEmpty ? cur.position : editor.effectiveToolEnd(cur.position)
        guard let s = screen(pos) else { return }
        let dot = Path(ellipseIn: CGRect(x: s.x - 4.5, y: s.y - 4.5, width: 9, height: 9))
        ctx.fill(dot, with: .color(accent))
        ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
        guard editor.toolPoints.isEmpty else { return }
        var text = String(localized: "X \(editor.plainNumber(pos.x))  Y \(editor.plainNumber(pos.y))")
        if cur.point == nil && cur.curve == nil && !cur.onGrid && AppSettings.shared.snapToGrid { text += String(localized: "  · frei") }
        let t = ctx.resolve(Text(text).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.8)))
        let size = t.measure(in: CGSize(width: 300, height: 40))
        let rect = CGRect(x: s.x + 12, y: s.y + 10, width: size.width + 12, height: size.height + 5)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(.primary.opacity(0.15)), lineWidth: 0.5)
        ctx.draw(t, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func label(_ ctx: GraphicsContext, _ text: String, near p: Vec2) {
        guard let s = screen(p) else { return }
        let t = ctx.resolve(Text(text).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white))
        let size = t.measure(in: CGSize(width: 300, height: 40))
        let rect = CGRect(x: s.x + 14, y: s.y + 10, width: size.width + 12, height: size.height + 4)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(accent))
        ctx.draw(t, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func badge(_ ctx: GraphicsContext, _ text: String, at p: CGPoint) {
        let t = ctx.resolve(Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
        let rect = CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.orange))
        ctx.draw(t, at: p)
    }

    // MARK: Typed tool inputs

    /// Screen anchors for each input box, pushed away from the shape so they don't cover it.
    private func toolInputPositions() -> [CGPoint] {
        guard let p0 = editor.toolPoints.first?.position, let cur = editor.cursor?.position else { return [] }
        let e = editor.effectiveToolEnd(cur)
        func away(_ p: Vec2, from center: Vec2, by d: CGFloat) -> CGPoint? {
            guard let sp = screen(p), let sc = screen(center) else { return nil }
            var v = CGVector(dx: sp.x - sc.x, dy: sp.y - sc.y)
            let len = hypot(v.dx, v.dy)
            v = len > 1e-3 ? CGVector(dx: v.dx / len, dy: v.dy / len) : CGVector(dx: 0, dy: 1)
            return CGPoint(x: sp.x + v.dx * d, y: sp.y + v.dy * d)
        }
        switch editor.sketchTool {
        case .line:
            let mid = (p0 + e) / 2
            let side = mid + simd_normalize(e - p0 + Vec2(1e-12, 0)).perpendicular
            let lengthPos = away(mid, from: side, by: -30) ?? .zero
            let anglePos = away(p0, from: e, by: 48) ?? .zero
            return [lengthPos, anglePos]
        case .rectangle, .centerRectangle:
            let lo = editor.sketchTool == .centerRectangle ? p0 - (e - p0) : p0
            let center = (lo + e) / 2
            let bottomMid = Vec2(center.x, lo.y), sideMid = Vec2(e.x, center.y)
            return [away(bottomMid, from: center, by: 26) ?? .zero, away(sideMid, from: center, by: 70) ?? .zero]
        case .circle:
            return [away(e, from: p0, by: 70) ?? .zero]
        default:
            return []
        }
    }

    private var toolInputBoxes: some View {
        let specs = editor.toolInputSpecs
        let positions = toolInputPositions()
        let live = editor.toolLiveValues
        return ForEach(Array(specs.enumerated()), id: \.offset) { i, spec in
            if i < positions.count {
                ToolInputBox(editor: editor, index: i, spec: spec, live: i < live.count ? live[i] : nil)
                    .position(positions[i])
            }
        }
    }

    // MARK: Dimensions

    private struct DimensionGeometry {
        var lines: [[Vec2]] = []
        var arrows: [(tip: Vec2, from: Vec2)] = []
        var label: Vec2
    }

    private func geometry(_ c: SketchConstraint, _ sk: Sketch) -> DimensionGeometry? {
        let anchor = editor.dimensionAnchor(c.kind, sk)
        guard let anchor else { return nil }
        let L = anchor + c.labelOffset
        var g = DimensionGeometry(label: L)
        func aligned(_ a: Vec2, _ b: Vec2) {
            let d = b - a
            guard simd_length(d) > 1e-9 else { return }
            let n = simd_normalize(d).perpendicular
            let off = simd_dot(c.labelOffset, n) * n
            g.lines = [[a, a + off], [b, b + off], [a + off, b + off]]
            g.arrows = [(a + off, b + off), (b + off, a + off)]
        }
        switch c.kind {
        case let .distance(p1, p2, _):
            guard let a = sk.point(p1), let b = sk.point(p2) else { return nil }
            aligned(a, b)
        case let .length(l, _):
            guard let cv = sk.curve(l), case let .line(p1, p2) = cv.geometry, let a = sk.point(p1), let b = sk.point(p2) else { return nil }
            aligned(a, b)
        case let .horizontalDistance(p1, p2, _):
            guard let a = sk.point(p1), let b = sk.point(p2) else { return nil }
            let ya = Vec2(a.x, L.y), yb = Vec2(b.x, L.y)
            g.lines = [[a, ya], [b, yb], [ya, yb]]
            g.arrows = [(ya, yb), (yb, ya)]
        case let .verticalDistance(p1, p2, _):
            guard let a = sk.point(p1), let b = sk.point(p2) else { return nil }
            let xa = Vec2(L.x, a.y), xb = Vec2(L.x, b.y)
            g.lines = [[a, xa], [b, xb], [xa, xb]]
            g.arrows = [(xa, xb), (xb, xa)]
        case let .pointLineDistance(p, l, _):
            guard let pp = sk.point(p), let cv = sk.curve(l) else { return nil }
            let foot = editor.footPoint(pp, on: cv, sk)
            g.lines = [[pp, foot]]
            g.arrows = [(pp, foot), (foot, pp)]
        case let .radius(cid, _), let .diameter(cid, _):
            guard let cv = sk.curve(cid), let center = sk.center(of: cv) else { return nil }
            let r = sk.radius(of: cv)
            let dir = simd_length(c.labelOffset) > 1e-9 ? simd_normalize(c.labelOffset) : Vec2(1, 0)
            if case .diameter = c.kind {
                g.lines = [[center - dir * r, center + dir * r], [center + dir * r, L]]
                g.arrows = [(center + dir * r, center), (center - dir * r, center)]
            } else {
                g.lines = [[center, center + dir * r], [center + dir * r, L]]
                g.arrows = [(center + dir * r, center)]
            }
        case let .angle(l1, l2, _):
            guard let c1 = sk.curve(l1), let c2 = sk.curve(l2), case let .line(a1, b1) = c1.geometry, case let .line(a2, b2) = c2.geometry,
                  let pa1 = sk.point(a1), let pb1 = sk.point(b1), let pa2 = sk.point(a2), let pb2 = sk.point(b2) else { return nil }
            let d1 = pb1 - pa1, d2 = pb2 - pa2
            let den = d1.x * d2.y - d1.y * d2.x
            guard abs(den) > 1e-12 else { return nil }
            let t = ((pa2.x - pa1.x) * d2.y - (pa2.y - pa1.y) * d2.x) / den
            let v = pa1 + t * d1
            let r = max(simd_distance(v, L), 1e-6)
            var u1 = simd_normalize(d1), u2 = simd_normalize(d2)
            // Orient the rays toward the label so the arc covers the labelled sector.
            if simd_dot(u1, L - v) < 0 { u1 = -u1 }
            if simd_dot(u2, L - v) < 0 { u2 = -u2 }
            let a0 = atan2(u1.y, u1.x)
            var sweep = normalizedAngle(atan2(u2.y, u2.x) - a0)
            var start = a0
            if sweep > .pi { start = atan2(u2.y, u2.x); sweep = 2 * .pi - sweep }
            g.lines = [(0...32).map { i in v + r * Vec2(cos(start + sweep * Double(i) / 32), sin(start + sweep * Double(i) / 32)) }]
        case let .offset(copyId, sourceId, _):
            guard let cc = sk.curve(copyId), let sc = sk.curve(sourceId) else { return nil }
            if sc.isLine {
                let a = editor.footPoint(L, on: sc, sk), b = editor.footPoint(L, on: cc, sk)
                g.lines = [[a, b]]
                g.arrows = [(a, b), (b, a)]
            } else if let center = sk.center(of: sc) {
                let dir = simd_length(L - center) > 1e-9 ? simd_normalize(L - center) : Vec2(1, 0)
                let a = center + dir * sk.radius(of: sc), b = center + dir * sk.radius(of: cc)
                g.lines = [[a, b]]
                g.arrows = [(a, b), (b, a)]
            }
        case let .translated(p1, p2, _, _):
            guard let a = sk.point(p1), let b = sk.point(p2) else { return nil }
            aligned(a, b)
        case let .rotated(m, p1, p2, _):
            guard let c0 = sk.point(m), let a = sk.point(p1), let b = sk.point(p2) else { return nil }
            let r = simd_distance(c0, a)
            let a0 = atan2(a.y - c0.y, a.x - c0.x), sweep = normalizedAngle(atan2(b.y - c0.y, b.x - c0.x) - a0)
            g.lines = [(0...32).map { i in c0 + r * Vec2(cos(a0 + sweep * Double(i) / 32), sin(a0 + sweep * Double(i) / 32)) }]
        default:
            return nil
        }
        return g
    }

    private func drawDimensions(_ ctx: GraphicsContext) {
        guard editor.sketchId != nil, let sk = sketch else { return }
        let failed = editor.lastSolve?.failedConstraints ?? []
        for c in sk.constraints where c.kind.isDimension && !sk.isGroupFollower(c) {
            guard let g = geometry(c, sk) else { continue }
            let selected = editor.selection.contains(.constraint(editor.sketchId!, c.id))
            let color = failed.contains(c.id) ? Color.red : (selected ? accent : dimColor)
            for l in g.lines { ctx.stroke(path(l), with: .color(color.opacity(0.85)), lineWidth: 1) }
            for (tip, from) in g.arrows {
                guard let t = screen(tip), let f = screen(from) else { continue }
                let d = CGVector(dx: f.x - t.x, dy: f.y - t.y)
                let len = max(hypot(d.dx, d.dy), 1e-6)
                let u = CGVector(dx: d.dx / len, dy: d.dy / len)
                let n = CGVector(dx: -u.dy, dy: u.dx)
                var p = Path()
                p.move(to: t)
                p.addLine(to: CGPoint(x: t.x + u.dx * 8 + n.dx * 3, y: t.y + u.dy * 8 + n.dy * 3))
                p.addLine(to: CGPoint(x: t.x + u.dx * 8 - n.dx * 3, y: t.y + u.dy * 8 - n.dy * 3))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
            }
        }
    }

    private var dimensionLabels: some View {
        let sk = sketch
        let sid = editor.sketchId
        return ForEach(sk?.constraints.filter { $0.kind.isDimension && !(sk?.isGroupFollower($0) ?? false) } ?? [], id: \.id) { c in
            if let sk, let sid, let g = geometry(c, sk), let pos = screen(g.label) {
                DimensionLabel(editor: editor, sketchId: sid, constraint: c, failed: editor.lastSolve?.failedConstraints.contains(c.id) == true)
                    .position(pos)
            }
        }
    }

    // MARK: Spline handles

    private func drawSplineHandles(_ ctx: GraphicsContext) {
        for c in editor.splinesWithHandles {
            for h in editor.splineHandles(c) {
                ctx.stroke(path([h.position - h.handle, h.position + h.handle]), with: .color(accent.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.2, dash: h.custom ? [] : [3, 3]))
            }
        }
    }

    /// Draggable handle ends: direction = tangent, length = how full the curve runs through the point.
    private var splineHandleKnobs: some View {
        let items: [(id: String, curve: Int, point: Int, sign: Double, pos: Vec2, custom: Bool)] = editor.splinesWithHandles.flatMap { c in
            editor.splineHandles(c).flatMap { h in
                [1.0, -1.0].map { s in ("\(c)-\(h.point)-\(s)", c, h.point, s, h.position + h.handle * s, h.custom) }
            }
        }
        return ForEach(items, id: \.id) { item in
            if let p = screen(item.pos) {
                SplineHandleKnob(editor: editor, curve: item.curve, point: item.point, sign: item.sign, custom: item.custom)
                    .position(p)
            }
        }
    }

    // MARK: Constraint glyphs

    private struct Glyph: Identifiable {
        let id: String
        let constraint: Int
        let symbol: String
        let position: CGPoint
    }

    private var glyphs: [Glyph] {
        guard let sk = sketch else { return [] }
        var out: [Glyph] = []
        var stack: [Int: Int] = [:]
        func onCurve(_ cid: Int, _ con: Int, _ symbol: String, _ tag: String) {
            guard let c = sk.curve(cid) else { return }
            let poly = sk.polyline(c, segments: 32)
            guard poly.count >= 2 else { return }
            let mid = poly[poly.count / 2], next = poly[min(poly.count - 1, poly.count / 2 + 1)]
            guard let s = screen(mid), let s2 = screen(next) else { return }
            let d = CGVector(dx: s2.x - s.x, dy: s2.y - s.y)
            let len = max(hypot(d.dx, d.dy), 1e-6)
            let u = CGVector(dx: d.dx / len, dy: d.dy / len)
            let k = stack[cid, default: 0]
            stack[cid] = k + 1
            let pos = CGPoint(x: s.x - u.dy * 14 + u.dx * CGFloat(k) * 19, y: s.y + u.dx * 14 + u.dy * CGFloat(k) * 19)
            out.append(Glyph(id: "\(con)-\(tag)", constraint: con, symbol: symbol, position: pos))
        }
        func atPoint(_ pid: Int, _ con: Int, _ symbol: String, _ tag: String) {
            guard let p = sk.point(pid), let s = screen(p) else { return }
            let k = stack[-pid - 1, default: 0]
            stack[-pid - 1] = k + 1
            out.append(Glyph(id: "\(con)-\(tag)", constraint: con, symbol: symbol, position: CGPoint(x: s.x + 12 + CGFloat(k) * 19, y: s.y - 12)))
        }
        // Constraints of copies (patterns, mirror) are shown by their dimension, not one glyph per copy.
        for c in sk.constraints where c.group == nil {
            switch c.kind {
            case let .horizontal(l): onCurve(l, c.id, "arrow.left.and.right", "h")
            case let .vertical(l): onCurve(l, c.id, "arrow.up.and.down", "v")
            case let .parallel(a, b): onCurve(a, c.id, "pause", "a"); onCurve(b, c.id, "pause", "b")
            case let .perpendicular(a, b): onCurve(a, c.id, "angle", "a"); onCurve(b, c.id, "angle", "b")
            case let .equal(a, b): onCurve(a, c.id, "equal", "a"); onCurve(b, c.id, "equal", "b")
            case let .collinear(a, b): onCurve(a, c.id, "line.diagonal", "a"); onCurve(b, c.id, "line.diagonal", "b")
            case let .tangent(a, b): onCurve(a, c.id, "circle.and.line.horizontal", "a"); onCurve(b, c.id, "circle.and.line.horizontal", "b")
            case let .concentric(a, b): onCurve(a, c.id, "circle.circle", "a"); onCurve(b, c.id, "circle.circle", "b")
            case let .pointOnCurve(p, _): atPoint(p, c.id, "smallcircle.filled.circle", "p")
            case let .midpoint(p, _): atPoint(p, c.id, "arrow.right.and.line.vertical.and.arrow.left", "p")
            case let .horizontalPoints(a, b): atPoint(a, c.id, "arrow.left.and.right", "a"); atPoint(b, c.id, "arrow.left.and.right", "b")
            case let .verticalPoints(a, b): atPoint(a, c.id, "arrow.up.and.down", "a"); atPoint(b, c.id, "arrow.up.and.down", "b")
            case let .symmetric(a, b, _): atPoint(a, c.id, "arrow.left.and.line.vertical.and.arrow.right", "a"); atPoint(b, c.id, "arrow.left.and.line.vertical.and.arrow.right", "b")
            case let .coincident(a, _): atPoint(a, c.id, "smallcircle.filled.circle", "p")
            default: break
            }
        }
        for p in sk.points where p.fixed && p.id != Sketch.originId {
            atPoint(p.id, -p.id, "lock.fill", "fix")
        }
        return out
    }

    private var constraintGlyphs: some View {
        let sid = editor.sketchId
        return ForEach(glyphs) { g in
            if let sid {
                let pick = Pick.constraint(sid, g.constraint)
                let selected = editor.selection.contains(pick)
                let hovered = editor.overlayHover == pick
                Image(systemName: g.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(selected ? Color.white : (hovered ? Color.accentColor : .primary.opacity(0.75)))
                    .frame(width: 15, height: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    .contentShape(Rectangle())
                    .onHover { h in editor.overlayHover = h ? pick : (editor.overlayHover == pick ? nil : editor.overlayHover) }
                    .onTapGesture {
                        if g.constraint < 0 { return }
                        editor.selection = selected ? [] : [pick]
                        editor.requestRedraw()
                    }
                    .help(g.constraint < 0 ? String(localized: "Fixiert") : (sketch?.constraints.first { $0.id == g.constraint }?.kind.displayName ?? ""))
                    .position(g.position)
            }
        }
    }

    // MARK: Manipulators (extrude, hole, fillet/chamfer, move) – shared look in `Gizmo`

    private func state(_ id: String) -> (highlighted: Bool, dimmed: Bool) {
        (gizmoFocus?.id == id, gizmoFocus?.dragging == true && gizmoFocus?.id != id)
    }

    private func drawExtrudeArrow(_ ctx: GraphicsContext) {
        guard let h = editor.extrudeHandle, let a = editor.camera.project(h.origin),
              let b = editor.camera.project(h.origin + h.direction * h.distance) else { return }
        let s = state("extrude")
        Gizmo.base(ctx, a, accent)
        Gizmo.shaft(ctx, a, b, accent, highlighted: s.highlighted)
    }

    private var extrudeHandle: some View {
        Group {
            if let h = editor.extrudeHandle, let base = editor.camera.project(h.origin),
               let tip = editor.camera.project(h.origin + h.direction * h.distance) {
                ExtrudeHandle(editor: editor, handle: h, angle: Gizmo.angle(base, tip), focus: $gizmoFocus)
                    .position(tip)
            }
        }
    }

    private func drawEdgeArrow(_ ctx: GraphicsContext) {
        guard let h = editor.edgeHandle, let a = editor.camera.project(h.center),
              let b = editor.camera.project(h.center + h.direction * editor.arrowLength) else { return }
        Gizmo.base(ctx, a, accent)
        Gizmo.shaft(ctx, a, b, accent, highlighted: state("edge").highlighted)
    }

    @ViewBuilder private var edgeHandle: some View {
        if let h = editor.edgeHandle, let base = editor.camera.project(h.center),
           let tip = editor.camera.project(h.center + h.direction * editor.arrowLength) {
            EdgeArrow(editor: editor, handle: h, angle: Gizmo.angle(base, tip), focus: $gizmoFocus)
                .position(tip)
        }
    }

    private func drawHoleArrows(_ ctx: GraphicsContext) {
        // Only touch the camera when there are arrows (otherwise the overlay would redraw on every camera move).
        let handles = editor.holeHandles
        guard !handles.isEmpty else { return }
        let len = editor.arrowLength
        for h in handles {
            guard let a = editor.camera.project(h.center) else { continue }
            for (axis, d) in h.axes.enumerated() {
                guard let b = editor.camera.project(h.center + d * len) else { continue }
                let s = state("hole-\(h.index)-\(axis)")
                Gizmo.shaft(ctx, a, b, accent, highlighted: s.highlighted, opacity: (s.dimmed ? 0.3 : 1) * Gizmo.visibility(a, b))
            }
            Gizmo.base(ctx, a, accent)
        }
    }

    private var holeHandles: some View {
        let handles = editor.holeHandles
        return ForEach(handles, id: \.index) { h in
            ForEach(0..<2, id: \.self) { axis in
                if let base = editor.camera.project(h.center),
                   let tip = editor.camera.project(h.center + h.axes[axis] * editor.arrowLength) {
                    HoleArrow(editor: editor, handle: h, axis: axis, angle: Gizmo.angle(base, tip), focus: $gizmoFocus)
                        .opacity((state("hole-\(h.index)-\(axis)").dimmed ? 0.3 : 1) * Gizmo.visibility(base, tip))
                        .allowsHitTesting(Gizmo.visibility(base, tip) > 0.5)
                        .position(tip)
                }
            }
        }
    }

    private func drawMoveManipulator(_ ctx: GraphicsContext) {
        // Only touch the camera while the move command is open.
        guard let h = editor.moveHandle, let a = editor.camera.project(h.center) else { return }
        let len = editor.moveArrowLength, radius = editor.moveRingRadius
        let forward = Vec3(editor.camera.forward)
        for ring in h.rings {
            let s = state("ring-\(ring.axis)")
            let color = moveRingColor(ring)
            let u = ring.start, v = simd_cross(ring.direction, ring.start)
            // Swept angle while the ring turns: a light wedge from 0° to the current angle.
            if ring.active, abs(h.angle) > 0.01 {
                var wedge = Path()
                wedge.move(to: editor.camera.project(ring.center) ?? a)
                let steps = max(2, Int(abs(h.angle) / 4))
                for k in 0...steps {
                    let t = h.angle * .pi / 180 * Double(k) / Double(steps)
                    if let p = editor.camera.project(ring.center + (u * cos(t) + v * sin(t)) * radius) { wedge.addLine(to: p) }
                }
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(color.opacity(0.18)))
            }
            // The half of the ring behind the centre is drawn faintly, like a real ring seen at an angle.
            var front = Path(), back = Path()
            var last: (CGPoint, Bool)?
            for k in 0...96 {
                let t = Double(k) / 96 * 2 * .pi
                let w = u * cos(t) + v * sin(t)
                guard let p = editor.camera.project(ring.center + w * radius) else { last = nil; continue }
                let behind = simd_dot(w, forward) > 0
                if let (q, wasBehind) = last {
                    if wasBehind { back.move(to: q); back.addLine(to: p) } else { front.move(to: q); front.addLine(to: p) }
                }
                last = (p, behind)
            }
            let o = s.dimmed ? 0.25 : 1
            ctx.stroke(back, with: .color(color.opacity(0.35 * o)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            Gizmo.stroke(ctx, front, color, highlighted: s.highlighted || (ring.active && gizmoFocus?.dragging == true && !s.dimmed),
                         opacity: o)
        }
        for (i, d) in Editor.moveAxes.enumerated() {
            guard let b = editor.camera.project(h.center + d * len) else { continue }
            let s = state("move-\(i)")
            Gizmo.shaft(ctx, a, b, moveAxisColor(i), highlighted: s.highlighted, opacity: (s.dimmed ? 0.25 : 1) * Gizmo.visibility(a, b))
        }
        Gizmo.base(ctx, a, .white, radius: 4.5)
    }

    private func moveAxisColor(_ i: Int) -> Color { Gizmo.axisColors[i] }

    private func moveRingColor(_ ring: Editor.MoveRing) -> Color {
        switch ring.axis {
        case .x: return moveAxisColor(0)
        case .y: return moveAxisColor(1)
        case .z: return moveAxisColor(2)
        default: return accent
        }
    }

    private var moveHandles: some View {
        Group {
            if let h = editor.moveHandle, let base = editor.camera.project(h.center) {
                ForEach(0..<3, id: \.self) { axis in
                    if let tip = editor.camera.project(h.center + Editor.moveAxes[axis] * editor.moveArrowLength) {
                        MoveArrow(editor: editor, handle: h, axis: axis, color: moveAxisColor(axis),
                                  angle: Gizmo.angle(base, tip), focus: $gizmoFocus)
                            .opacity((state("move-\(axis)").dimmed ? 0.25 : 1) * Gizmo.visibility(base, tip))
                            .allowsHitTesting(Gizmo.visibility(base, tip) > 0.5)
                            .position(tip)
                    }
                }
                // By axis: the other rings vanish once turning starts, the dragged knob must stay the same view.
                ForEach(h.rings, id: \.axis) { ring in
                    if let knob = editor.camera.project(editor.moveKnob(h, ring)) {
                        MoveRingKnob(editor: editor, handle: h, ring: ring, color: moveRingColor(ring), focus: $gizmoFocus)
                            .opacity(state("ring-\(ring.axis)").dimmed ? 0.25 : 1)
                            .position(knob)
                    }
                }
            }
        }
    }
}

/// Which manipulator the pointer is over or drags; the others step back while one is dragged.
struct GizmoFocus: Equatable {
    var id: String
    var dragging: Bool
}

/// Shared look of all viewport manipulators: round shafts with a soft dark edge (readable on light
/// and dark surfaces), rounded arrowheads, and value badges in the panels' material.
enum Gizmo {
    static let axisColors = [Color(nsColor: .systemRed), Color(nsColor: .systemGreen), Color(nsColor: .systemBlue)]
    static let headSize: CGFloat = 26
    static let animation = Animation.snappy(duration: 0.16)

    static func angle(_ base: CGPoint, _ tip: CGPoint) -> CGFloat { atan2(tip.y - base.y, tip.x - base.x) }

    /// An arrow that points (almost) at the viewer is short on screen and cannot be dragged sensibly: fade it out.
    static func visibility(_ a: CGPoint, _ b: CGPoint) -> Double {
        min(1, max(0, (hypot(b.x - a.x, b.y - a.y) - 10) / 14))
    }

    static func stroke(_ ctx: GraphicsContext, _ p: Path, _ color: Color, highlighted: Bool, opacity: Double = 1) {
        guard opacity > 0.01 else { return }
        let w: CGFloat = highlighted ? 3.5 : 2.5
        ctx.stroke(p, with: .color(.black.opacity(0.28 * opacity)), style: StrokeStyle(lineWidth: w + 2, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }

    static func shaft(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ color: Color, highlighted: Bool, opacity: Double = 1) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        stroke(ctx, p, color, highlighted: highlighted, opacity: opacity)
    }

    /// Small puck where arrows start.
    static func base(_ ctx: GraphicsContext, _ p: CGPoint, _ color: Color, radius r: CGFloat = 3.5) {
        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.stroke(dot, with: .color(.black.opacity(0.3)), lineWidth: 2.5)
        ctx.fill(dot, with: .color(color))
    }
}

/// Arrowhead pointing right with softly rounded corners and a slightly swept-back base.
private struct ArrowHead: SwiftUI.Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), s = rect.width / 26
        let tip = CGPoint(x: c.x + 10 * s, y: c.y)
        let top = CGPoint(x: c.x - 6 * s, y: c.y - 7.5 * s), bottom = CGPoint(x: c.x - 6 * s, y: c.y + 7.5 * s)
        let notch = CGPoint(x: c.x - 2.5 * s, y: c.y)
        var p = Path()
        p.move(to: notch)
        p.addArc(tangent1End: top, tangent2End: tip, radius: 1.8 * s)
        p.addArc(tangent1End: tip, tangent2End: bottom, radius: 1.6 * s)
        p.addArc(tangent1End: bottom, tangent2End: notch, radius: 1.8 * s)
        p.closeSubpath()
        return p
    }
}

/// Arrowhead of a manipulator; grows and gets a soft halo under the pointer or while dragged.
private struct GizmoTip: View {
    let color: Color
    let angle: CGFloat
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(active ? 0.22 : 0))
                .frame(width: 30, height: 30)
            ArrowHead()
                .fill(color.gradient)
                .overlay(ArrowHead().stroke(.white.opacity(0.85), lineWidth: 1.2))
                .frame(width: Gizmo.headSize, height: Gizmo.headSize)
                .shadow(color: .black.opacity(PanelStyle.fast ? 0 : 0.35), radius: 2.5, y: 1)
                .rotationEffect(.radians(angle))
                .scaleEffect(active ? 1.18 : 1)
        }
        .animation(Gizmo.animation, value: active)
    }
}

/// Round knob in the same style (ring handles).
private struct GizmoKnob: View {
    let color: Color
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(active ? 0.22 : 0))
                .frame(width: 28, height: 28)
            Circle()
                .fill(color.gradient)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(PanelStyle.fast ? 0 : 0.35), radius: 2.5, y: 1)
                .scaleEffect(active ? 1.2 : 1)
        }
        .animation(Gizmo.animation, value: active)
    }
}

/// Current value next to a manipulator, in the floating panels' material.
private struct ValueBadge: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(PanelStyle.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(PanelStyle.fast ? 0 : 0.18), radius: 4, y: 1)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// Hover and drag bookkeeping shared by all manipulator handles.
private struct GizmoInteraction: ViewModifier {
    let id: String
    @Binding var focus: GizmoFocus?

    func body(content: Content) -> some View {
        content
            .contentShape(Circle())
            .onHover { inside in
                if focus?.dragging == true { return }
                if inside { focus = GizmoFocus(id: id, dragging: false) } else if focus?.id == id { focus = nil }
            }
    }
}

private extension View {
    func gizmo(_ id: String, _ focus: Binding<GizmoFocus?>) -> some View { modifier(GizmoInteraction(id: id, focus: focus)) }
}

/// Arrow tip of the move manipulator; dragging shifts the bodies along X, Y or Z.
private struct MoveArrow: View {
    let editor: Editor
    let handle: Editor.MoveHandle
    let axis: Int
    let color: Color
    let angle: CGFloat
    @Binding var focus: GizmoFocus?
    @State private var start: Editor.MoveHandle?

    var body: some View {
        let id = "move-\(axis)"
        ZStack {
            GizmoTip(color: color, angle: angle, active: focus?.id == id)
            if start != nil {
                ValueBadge(text: formatValue(handle.offsets[axis]), tint: color).offset(y: -28)
            }
        }
        .frame(width: 30, height: 30)
        .gizmo(id, $focus)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                .onChanged { v in
                    if start == nil { start = handle; focus = GizmoFocus(id: id, dragging: true) }
                    guard let start, let value = editor.moveOffset(start, axis: axis, from: v.startLocation, to: v.location) else { return }
                    editor.setMoveOffset(axis: axis, value)
                }
                .onEnded { _ in start = nil; focus = nil }
        )
        .help("Ziehen, um die Körper zu verschieben")
    }
}

/// Knob on a ring of the move manipulator; dragging it around turns the bodies (⇧ in 1° steps).
private struct MoveRingKnob: View {
    let editor: Editor
    let handle: Editor.MoveHandle
    let ring: Editor.MoveRing
    let color: Color
    @Binding var focus: GizmoFocus?
    @State private var start: (handle: Editor.MoveHandle, ring: Editor.MoveRing)?

    var body: some View {
        let id = "ring-\(ring.axis)"
        ZStack {
            GizmoKnob(color: color, active: focus?.id == id)
            if start != nil {
                ValueBadge(text: formatValue(handle.angle, kind: .angle), tint: color).offset(y: -28)
            }
        }
        .frame(width: 30, height: 30)
        .gizmo(id, $focus)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                .onChanged { v in
                    if start == nil { start = (handle, ring); focus = GizmoFocus(id: id, dragging: true) }
                    guard let start, let value = editor.moveAngle(start.handle, start.ring, from: v.startLocation, to: v.location,
                                                                  fine: NSEvent.modifierFlags.contains(.shift)) else { return }
                    editor.setMoveAngle(start.ring, value)
                }
                .onEnded { _ in start = nil; focus = nil }
        )
        .help("Ziehen, um die Körper zu drehen")
    }
}

/// Arrow tip at a hole position; dragging moves the hole along the face's X or Y.
private struct HoleArrow: View {
    let editor: Editor
    let handle: Editor.HoleHandle
    let axis: Int
    let angle: CGFloat
    @Binding var focus: GizmoFocus?
    @State private var start: Editor.HoleHandle?

    var body: some View {
        let id = "hole-\(handle.index)-\(axis)"
        ZStack {
            GizmoTip(color: .accentColor, angle: angle, active: focus?.id == id)
            if start != nil {
                ValueBadge(text: formatValue(handle.offsets[axis])).offset(y: -28)
            }
        }
        .frame(width: 30, height: 30)
        .gizmo(id, $focus)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                .onChanged { v in
                    if start == nil { start = handle; focus = GizmoFocus(id: id, dragging: true) }
                    guard let start, let value = editor.holeOffset(start, axis: axis, from: v.startLocation, to: v.location) else { return }
                    editor.setHoleOffset(start.index, axis: axis, value)
                }
                .onEnded { _ in start = nil; focus = nil }
        )
        .help("Ziehen, um die Bohrung zu verschieben")
    }
}

/// Arrow tip on the first edge of a fillet or chamfer; dragging into the corner makes it larger.
private struct EdgeArrow: View {
    let editor: Editor
    let handle: Editor.EdgeHandle
    let angle: CGFloat
    @Binding var focus: GizmoFocus?
    @State private var start: Editor.EdgeHandle?

    var body: some View {
        ZStack {
            GizmoTip(color: .accentColor, angle: angle, active: focus?.id == "edge")
            ValueBadge(text: formatValue(handle.value)).offset(y: -28)
        }
        .frame(width: 30, height: 30)
        .gizmo("edge", $focus)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                .onChanged { v in
                    if start == nil { start = handle; focus = GizmoFocus(id: "edge", dragging: true) }
                    guard let start, let value = editor.edgeValue(start, from: v.startLocation, to: v.location) else { return }
                    editor.setEdgeValue(value)
                }
                .onEnded { _ in start = nil; focus = nil }
        )
        .help("Ziehen, um die Größe zu ändern")
    }
}

/// Draggable arrow tip that sets the extrusion distance.
private struct ExtrudeHandle: View {
    let editor: Editor
    let handle: (origin: Vec3, direction: Vec3, distance: Double)
    let angle: CGFloat
    @Binding var focus: GizmoFocus?

    var body: some View {
        ZStack {
            GizmoTip(color: .accentColor, angle: angle, active: focus?.id == "extrude")
            ValueBadge(text: formatValue(handle.distance)).offset(y: -28)
        }
        .frame(width: 30, height: 30)
        .gizmo("extrude", $focus)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                .onChanged { v in
                    if focus?.dragging != true { focus = GizmoFocus(id: "extrude", dragging: true) }
                    guard case let .extrude(e)? = editor.commandFeature?.kind else { return }
                    let symmetric = e.extent == .symmetric
                    // Profile origin (handle origin is shifted back for symmetric extrusions).
                    let o = symmetric ? handle.origin + handle.direction * handle.distance / 2 : handle.origin
                    guard var t = editor.dragParameter(at: v.location, origin: o, direction: handle.direction) else { return }
                    let step = editor.dragStep
                    t = (t / step).rounded() * step
                    let dist = symmetric ? 2 * t : t
                    if abs(dist) > 1e-9 { editor.setExtrudeDistance(dist) }
                }
                .onEnded { _ in focus = nil }
        )
        .help("Ziehen, um den Abstand zu ändern")
    }
}

/// A dimension value on the sketch. Double-click to edit, drag to move.
private struct DimensionLabel: View {
    let editor: Editor
    let sketchId: UUID
    let constraint: SketchConstraint
    let failed: Bool
    @State private var text = ""
    @State private var dragStart: Vec2?
    @FocusState private var focused: Bool

    var body: some View {
        let pick = Pick.constraint(sketchId, constraint.id)
        let selected = editor.selection.contains(pick)
        let expr = constraint.kind.dimensionValue ?? ""
        let value = (try? editor.evaluator.value(expr, kind: constraint.kind.valueKind)) ?? .nan
        let isExpr = Double(expr.replacingOccurrences(of: ",", with: ".")) == nil
        let prefix: String = {
            switch constraint.kind {
            case .diameter: return "⌀"
            case .radius: return "R"
            default: return ""
            }
        }()
        return Group {
            if editor.editingDimension == constraint.id {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: max(64, CGFloat(text.count) * 8 + 16))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .focused($focused)
                    .onAppear {
                        text = expr
                        DispatchQueue.main.async { focused = true }
                    }
                    .onSubmit {
                        if editor.setDimensionValue(constraint.id, text) { editor.editingDimension = nil }
                    }
                    .onExitCommand { editor.editingDimension = nil }
            } else {
                Text((isExpr ? "ƒ " : "") + prefix + formatValue(value, kind: constraint.kind.valueKind))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(failed ? Color.red : (selected ? Color.white : .primary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                    .onTapGesture(count: 2) { editor.editingDimension = constraint.id }
                    .onTapGesture {
                        editor.selection = selected ? [] : [pick]
                        editor.requestRedraw()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .named("overlay"))
                            .onChanged { v in
                                guard let sk = editor.activeSketch, let anchor = editor.dimensionAnchor(constraint.kind, sk),
                                      let pos = editor.sketchPosition(at: v.location) else { return }
                                editor.moveDimensionLabel(constraint.id, to: pos - anchor, undoable: false)
                            }
                    )
                    .help(isExpr ? String(localized: "\(expr) – Doppelklick zum Bearbeiten") : String(localized: "Doppelklick zum Bearbeiten"))
            }
        }
    }
}

/// One end of a spline tangent handle.
private struct SplineHandleKnob: View {
    let editor: Editor
    let curve: Int
    let point: Int
    let sign: Double
    let custom: Bool
    @State private var snapshot: CADDocument?

    var body: some View {
        Circle()
            .fill(custom ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .contentShape(Circle().inset(by: -4))
            .onTapGesture(count: 2) {
                let before = editor.doc
                editor.setSplineHandle(curve: curve, point: point, to: nil)
                if editor.doc != before { editor.pushUndo(before) }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                    .onChanged { v in
                        if snapshot == nil { snapshot = editor.doc }
                        guard let pos = editor.sketchPosition(at: v.location),
                              let fit = editor.activeSketch?.point(point) else { return }
                        editor.setSplineHandle(curve: curve, point: point, to: (pos - fit) * sign)
                    }
                    .onEnded { _ in
                        if let s = snapshot, s != editor.doc { editor.pushUndo(s) }
                        snapshot = nil
                    }
            )
            .help(String(localized: "Ziehen: Richtung und Stärke der Kurve · Doppelklick: automatisch"))
    }
}

