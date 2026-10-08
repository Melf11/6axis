import simd
import SwiftUI
import VibeCore

/// 2D overlay drawn on top of the Metal viewport: sketch tool previews, dimensions,
/// constraint glyphs and the extrude manipulator. Only interactive elements receive clicks.
struct ViewportOverlay: View {
    @Bindable var editor: Editor

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                drawToolPreview(ctx)
                drawDimensions(ctx)
                drawExtrudeArrow(ctx)
            }
            .allowsHitTesting(false)

            if editor.sketchId != nil {
                constraintGlyphs
                dimensionLabels
                toolInputBoxes
            }
            extrudeHandle
        }
        .coordinateSpace(name: "overlay")
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
                ctx.stroke(path([p0, c]), with: .color(accent), style: style)
            } else if editor.toolPoints.count == 2, let (center, r) = circleThrough(p0, c, editor.toolPoints[1].position) {
                let p1 = editor.toolPoints[1].position
                let ccw = editor.arcIsCCW(center: center, start: p0, end: p1, through: c)
                let (s, e) = ccw ? (p0, p1) : (p1, p0)
                let a0 = atan2(s.y - center.y, s.x - center.x)
                var sweep = normalizedAngle(atan2(e.y - center.y, e.x - center.x) - a0)
                if sweep < 1e-6 { sweep = 2 * .pi }
                let pts = (0...64).map { i -> Vec2 in
                    let t = a0 + sweep * Double(i) / 64
                    return center + r * Vec2(cos(t), sin(t))
                }
                ctx.stroke(path(pts), with: .color(accent), style: style)
                label(ctx, "R " + formatValue(r), near: c)
            }
        default:
            break
        }
    }

    private var isDrawingTool: Bool {
        switch editor.sketchTool {
        case .line, .rectangle, .centerRectangle, .circle, .arc: return true
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
        var text = "X \(editor.plainNumber(pos.x))  Y \(editor.plainNumber(pos.y))"
        if cur.point == nil && cur.curve == nil && !cur.onGrid && AppSettings.shared.snapToGrid { text += "  · frei" }
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
        default:
            return nil
        }
        return g
    }

    private func drawDimensions(_ ctx: GraphicsContext) {
        guard editor.sketchId != nil, let sk = sketch else { return }
        let failed = editor.lastSolve?.failedConstraints ?? []
        for c in sk.constraints where c.kind.isDimension {
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
        return ForEach(sk?.constraints.filter { $0.kind.isDimension } ?? [], id: \.id) { c in
            if let sk, let sid, let g = geometry(c, sk), let pos = screen(g.label) {
                DimensionLabel(editor: editor, sketchId: sid, constraint: c, failed: editor.lastSolve?.failedConstraints.contains(c.id) == true)
                    .position(pos)
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
        for c in sk.constraints {
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
                    .help(g.constraint < 0 ? "Fixiert" : (sketch?.constraints.first { $0.id == g.constraint }?.kind.displayName ?? ""))
                    .position(g.position)
            }
        }
    }

    // MARK: Extrude manipulator

    private func drawExtrudeArrow(_ ctx: GraphicsContext) {
        guard let h = editor.extrudeHandle, let a = editor.camera.project(h.origin),
              let b = editor.camera.project(h.origin + h.direction * h.distance) else { return }
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        ctx.stroke(p, with: .color(accent), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
    }

    private var extrudeHandle: some View {
        Group {
            if let h = editor.extrudeHandle, let tip = editor.camera.project(h.origin + h.direction * h.distance) {
                ExtrudeHandle(editor: editor, handle: h)
                    .position(tip)
            }
        }
    }
}

/// Draggable arrow tip that sets the extrusion distance.
private struct ExtrudeHandle: View {
    let editor: Editor
    let handle: (origin: Vec3, direction: Vec3, distance: Double)
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: hovering ? 18 : 14, height: hovering ? 18 : 14)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Text(formatValue(handle.distance))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.regularMaterial))
                .fixedSize()
                .offset(x: 50, y: -16)
                .allowsHitTesting(false)
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("overlay"))
                .onChanged { v in
                    guard case let .extrude(e)? = editor.commandFeature?.kind else { return }
                    let symmetric = e.extent == .symmetric
                    // Profile origin (handle origin is shifted back for symmetric extrusions).
                    let o = symmetric ? handle.origin + handle.direction * handle.distance / 2 : handle.origin
                    let r = editor.camera.rayD(at: v.location)
                    let D = handle.direction, w0 = o - r.origin
                    let b = simd_dot(D, r.direction), d = simd_dot(D, w0), ee = simd_dot(r.direction, w0)
                    let den = 1 - b * b
                    guard abs(den) > 1e-6 else { return }
                    var t = (b * ee - d) / den
                    let step = pow(10, floor(log10(Double(editor.camera.worldPerPoint) * 8)))
                    t = (t / step).rounded() * step
                    let dist = symmetric ? 2 * t : t
                    if abs(dist) > 1e-9 { editor.setExtrudeDistance(dist) }
                }
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
                    .help(isExpr ? "\(expr) – Doppelklick zum Bearbeiten" : "Doppelklick zum Bearbeiten")
            }
        }
    }
}
