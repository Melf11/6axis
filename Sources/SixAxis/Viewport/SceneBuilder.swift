import AppKit
import Foundation
import simd
import SixAxisCore

/// Visual style of the viewport. Light and dark variants follow the system appearance.
struct SceneStyle {
    var body: SIMD4<Float>
    var edge: SIMD4<Float>
    var curveFree: SIMD4<Float>
    var curveFixed: SIMD4<Float>
    var curveInactive: SIMD4<Float>
    var construction: SIMD4<Float>
    var profile: SIMD4<Float>
    var gridMinor: SIMD4<Float>
    var gridMajor: SIMD4<Float>
    var plane: SIMD4<Float>
    var planeEdge: SIMD4<Float>
    var select: SIMD4<Float>

    static func current(dark: Bool) -> SceneStyle {
        if dark {
            return SceneStyle(
                body: SIMD4(0.60, 0.64, 0.70, 1), edge: SIMD4(0.03, 0.035, 0.045, 1),
                curveFree: SIMD4(0.35, 0.62, 1.0, 1), curveFixed: SIMD4(0.93, 0.94, 0.96, 1),
                curveInactive: SIMD4(0.55, 0.62, 0.72, 1), construction: SIMD4(1.0, 0.62, 0.25, 1),
                profile: SIMD4(1.0, 0.70, 0.35, 0.20), gridMinor: SIMD4(1, 1, 1, 0.045), gridMajor: SIMD4(1, 1, 1, 0.10),
                plane: SIMD4(0.40, 0.60, 1.0, 0.13), planeEdge: SIMD4(0.45, 0.65, 1.0, 0.7), select: SIMD4(0.20, 0.55, 1.0, 1))
        }
        return SceneStyle(
            body: SIMD4(0.74, 0.77, 0.81, 1), edge: SIMD4(0.12, 0.13, 0.15, 1),
            curveFree: SIMD4(0.10, 0.42, 0.95, 1), curveFixed: SIMD4(0.07, 0.07, 0.09, 1),
            curveInactive: SIMD4(0.35, 0.44, 0.58, 1), construction: SIMD4(0.95, 0.52, 0.10, 1),
            profile: SIMD4(1.0, 0.66, 0.30, 0.20), gridMinor: SIMD4(0, 0, 0, 0.055), gridMajor: SIMD4(0, 0, 0, 0.11),
            plane: SIMD4(0.30, 0.50, 0.95, 0.12), planeEdge: SIMD4(0.30, 0.50, 0.95, 0.65), select: SIMD4(0.04, 0.47, 1.0, 1))
    }
}

/// Translates editor + model state into GPU batches and a pick-id table.
struct SceneBuilder {
    let editor: Editor
    let scale: Float
    let style: SceneStyle

    private(set) var scene = RenderScene()
    private(set) var picks: [Pick] = []
    private(set) var ids: [Pick: UInt32] = [:]
    private(set) var bodyFaceIds: [UUID: [UInt32]] = [:]

    init(editor: Editor, scale: CGFloat) {
        self.editor = editor
        self.scale = Float(scale)
        self.style = SceneStyle.current(dark: editor.darkMode)
    }

    private mutating func id(_ p: Pick) -> UInt32 {
        if let i = ids[p] { return i }
        picks.append(p)
        let i = UInt32(picks.count)
        ids[p] = i
        return i
    }

    mutating func build() {
        let doc = editor.doc
        let state = editor.state
        let cmd = editor.command
        let translucentSource = (cmd?.kind == .extrude || cmd?.kind == .revolve) ? cmd?.featureId : nil

        if AppSettings.shared.showGrid { addGrid() }
        addAxes()
        if cmd?.kind == .sketchPlane || editor.showOriginPlanes { addOriginPlanes() }

        // Bodies
        var translucent: [MeshBatch] = []
        var edgeLines: [LineInstance] = []
        for body in state.orderedBodies where doc.isBodyVisible(body.id) {
            guard let mesh = body.mesh else { continue }
            let isPreview = translucentSource != nil && body.sourceFeature == translucentSource
            var faceIds = [UInt32](repeating: 0, count: mesh.faceCount)
            if !isPreview {
                for f in 0..<mesh.faceCount { faceIds[f] = id(.face(body.id, f)) }
                bodyFaceIds[body.id] = faceIds
            }
            var verts = [MeshVertex]()
            verts.reserveCapacity(mesh.positions.count)
            for i in 0..<mesh.positions.count {
                let p = mesh.positions[i], n = mesh.normals[i]
                let fid = Int(mesh.faceIds[i])
                verts.append(MeshVertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z, id: fid < faceIds.count ? faceIds[fid] : 0))
            }
            if isPreview {
                translucent.append(MeshBatch(vertices: verts, indices: mesh.indices, color: SIMD4(style.select.x * 0.5 + 0.35, style.select.y * 0.5 + 0.4, style.select.z * 0.5 + 0.45, 0.55), translucent: true))
            } else {
                scene.meshes.append(MeshBatch(vertices: verts, indices: mesh.indices, color: style.body))
            }
            for (k, seg) in mesh.edgeSegments.enumerated() {
                let eid = isPreview ? 0 : id(.edge(body.id, Int(mesh.edgeIds[k])))
                edgeLines.append(LineInstance(seg.0, seg.1, id: eid))
            }
        }
        // Hidden edges stay pickable (transparent), so fillets still work; hover/selection still shows them.
        let showEdges = AppSettings.shared.showEdges
        let edgeColor = showEdges ? style.edge : SIMD4<Float>(0, 0, 0, 0)
        let edgeWidth = Float(showEdges ? AppSettings.shared.edgeWidth : 2) * scale
        scene.lines.append(LineBatch(instances: edgeLines, width: edgeWidth, color: edgeColor, depthBias: 0.0015))
        scene.meshes.append(contentsOf: translucent)
        if AppSettings.shared.groundShadow {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for m in scene.meshes where !m.translucent {
                for v in m.vertices {
                    lo = simd_min(lo, SIMD3(v.px, v.py, v.pz))
                    hi = simd_max(hi, SIMD3(v.px, v.py, v.pz))
                }
            }
            if lo.x <= hi.x { scene.shadowBounds = (lo, hi) }
        }

        addCommandHighlights()

        // Sketches
        var referenced = Set<UUID>()
        if let f = editor.commandFeature {
            switch f.kind {
            case let .extrude(e): referenced = Set(e.profiles.map(\.sketch))
            case let .revolve(r): referenced = Set(r.profiles.map(\.sketch))
            default: break
            }
        }
        let showAllProfiles = cmd?.kind == .extrude || cmd?.kind == .revolve
        for f in doc.features.prefix(doc.activeCount) {
            guard case .sketch = f.kind, let sb = state.sketches[f.id] else { continue }
            let active = f.id == editor.sketchId
            guard active || !doc.hiddenSketches.contains(f.id) || referenced.contains(f.id) else { continue }
            addSketch(sb, active: active, showProfiles: active || showAllProfiles || editor.sketchId == nil)
        }
    }

    // MARK: Sketches

    private mutating func addSketch(_ sb: SketchBuild, active: Bool, showProfiles: Bool) {
        let sid = sb.featureId
        let sk = (active ? editor.activeSketch : nil) ?? sb.sketch
        let solve = active ? (editor.lastSolve ?? sb.solve) : sb.solve
        let plane = sb.plane

        if showProfiles {
            var fills: [FillVertex] = []
            let color = packColor(style.profile)
            for region in sb.regions {
                guard let m = region.mesh else { continue }
                let rid = id(.profile(sid, region.index))
                for idx in m.indices {
                    let p = m.positions[Int(idx)]
                    fills.append(FillVertex(x: p.x, y: p.y, z: p.z, id: rid, color: color))
                }
            }
            scene.fills.append(FillBatch(vertices: fills, depthBias: 0.001, pickable: !active))
        }

        var lines: [LineInstance] = []
        for c in sk.curves {
            let poly = sk.polyline(c, segments: 96)
            let color: SIMD4<Float>
            var flags: UInt32 = 0
            if c.construction {
                color = style.construction
                flags |= LineInstance.dashed
            } else if !active {
                color = style.curveInactive
            } else if solve.fullyConstrainedCurves.contains(c.id) {
                color = style.curveFixed
            } else {
                color = style.curveFree
            }
            let cid = id(.sketchCurve(sid, c.id))
            let packed = packColor(color)
            for i in 0..<max(0, poly.count - 1) {
                lines.append(LineInstance(plane.point(poly[i]).float, plane.point(poly[i + 1]).float, id: cid, color: packed, flags: flags))
            }
        }
        scene.lines.append(LineBatch(instances: lines, width: (active ? 2.0 : 1.5) * scale, depthBias: 0.003))

        guard active else { return }
        var pts: [PointInstance] = []
        let centers = Set(sk.curves.compactMap { c -> Int? in
            switch c.geometry {
            case let .circle(ci, _), let .arc(ci, _, _): return ci
            case .line: return nil
            }
        })
        for p in sk.points {
            let w = plane.point(p.position).float
            let fixed = p.fixed || solve.fullyConstrainedPoints.contains(p.id)
            let color = p.id == Sketch.originId ? SIMD4<Float>(0.9, 0.3, 0.2, 1) : (fixed ? style.curveFixed : style.curveFree)
            let size: Float = (centers.contains(p.id) ? 6 : 8) * scale
            pts.append(PointInstance(x: w.x, y: w.y, z: w.z, id: id(.sketchPoint(sid, p.id)), color: packColor(color), size: size))
        }
        scene.points.append(PointBatch(instances: pts, depthBias: 0.004, depth: .always))
    }

    // MARK: Command highlights (selected inputs on the pre-feature geometry)

    private mutating func addCommandHighlights() {
        guard let cmd = editor.command, let f = editor.commandFeature else { return }
        let pre = editor.stateBeforeCommand
        let sel = packColor(style.select)
        switch (cmd.kind, f.kind) {
        case let (.fillet, .fillet(x)):
            addEdgeHighlights(x.edges, pre, sel)
        case let (.chamfer, .chamfer(x)):
            addEdgeHighlights(x.edges, pre, sel)
        case let (.shell, .shell(x)):
            var fills: [FillVertex] = []
            let color = packColor(SIMD4(style.select.x, style.select.y, style.select.z, 0.35))
            for ref in x.faces {
                guard let body = pre.bodies[ref.body], let idx = body.resolve(ref.face), let m = body.mesh else { continue }
                for t in stride(from: 0, to: m.indices.count, by: 3) where Int(m.faceIds[Int(m.indices[t])]) == idx {
                    for k in 0..<3 {
                        let p = m.positions[Int(m.indices[t + k])]
                        fills.append(FillVertex(x: p.x, y: p.y, z: p.z, id: 0, color: color))
                    }
                }
            }
            scene.fills.append(FillBatch(vertices: fills, depthBias: 0.002, depth: .always, pickable: false))
        default:
            break
        }
    }

    private mutating func addEdgeHighlights(_ refs: [BodyEdgeRef], _ pre: ModelState, _ color: UInt32) {
        var lines: [LineInstance] = []
        for ref in refs {
            guard let body = pre.bodies[ref.body], let idx = body.resolve(ref.edge), let m = body.mesh else { continue }
            for (k, seg) in m.edgeSegments.enumerated() where Int(m.edgeIds[k]) == idx {
                lines.append(LineInstance(seg.0, seg.1, id: 0, color: color, flags: LineInstance.emphasized))
            }
        }
        scene.lines.append(LineBatch(instances: lines, width: 2.2 * scale, depthBias: 0.003, depth: .always, pickable: false))
    }

    // MARK: Grid, axes, origin planes

    private mutating func addGrid() {
        let cam = editor.camera
        let plane = editor.activePlane ?? .xy
        let (step, major) = editor.gridSpacing
        let center = plane.project(Vec3(Double(cam.target.x), Double(cam.target.y), Double(cam.target.z)))
        let c = Vec2((center.x / major).rounded() * major, (center.y / major).rounded() * major)
        editor.gridCenter = center
        let n = 80
        let half = Double(n) * step
        var minor: [LineInstance] = [], majorLines: [LineInstance] = []
        let minorColor = packColor(style.gridMinor), majorColor = packColor(style.gridMajor)
        for i in -n...n {
            let o = Double(i) * step
            let isMajor = abs((c.x + o) / major - ((c.x + o) / major).rounded()) < 1e-6
            let a = plane.point(Vec2(c.x + o, c.y - half)).float, b = plane.point(Vec2(c.x + o, c.y + half)).float
            let isMajorY = abs((c.y + o) / major - ((c.y + o) / major).rounded()) < 1e-6
            let a2 = plane.point(Vec2(c.x - half, c.y + o)).float, b2 = plane.point(Vec2(c.x + half, c.y + o)).float
            if isMajor { majorLines.append(LineInstance(a, b, color: majorColor)) } else { minor.append(LineInstance(a, b, color: minorColor)) }
            if isMajorY { majorLines.append(LineInstance(a2, b2, color: majorColor)) } else { minor.append(LineInstance(a2, b2, color: minorColor)) }
        }
        scene.lines.append(LineBatch(instances: minor, width: 1 * scale, depthBias: -0.002, depth: .readOnly, pickable: false))
        scene.lines.append(LineBatch(instances: majorLines, width: 1 * scale, depthBias: -0.002, depth: .readOnly, pickable: false))
    }

    /// Origin axes as long lines through the grid, drawn *behind* geometry (negative depth bias),
    /// so body edges lying on an axis always win and no axis stubs show through.
    private mutating func addAxes() {
        let half = 80 * editor.gridSpacing.minor
        let t = editor.camera.target
        let c = (editor.activePlane ?? .xy).project(Vec3(Double(t.x), Double(t.y), Double(t.z)))
        let red = SIMD4<Float>(0.90, 0.25, 0.25, 0.75), green = SIMD4<Float>(0.25, 0.70, 0.30, 0.75), blue = SIMD4<Float>(0.25, 0.45, 0.95, 0.75)
        let pickable = editor.command?.kind == .revolve && editor.command?.activeInput == 1
        var lines: [LineInstance] = []

        if let plane = editor.activePlane {
            // Sketch: the sketch's own X/Y directions through its origin.
            lines.append(LineInstance(plane.point(Vec2(c.x - half, 0)).float, plane.point(Vec2(c.x + half, 0)).float, color: packColor(red)))
            lines.append(LineInstance(plane.point(Vec2(0, c.y - half)).float, plane.point(Vec2(0, c.y + half)).float, color: packColor(green)))
        } else {
            let showZ = pickable || editor.showOriginPlanes || editor.command?.kind == .sketchPlane
            let axes: [(Vec3, Double, SIMD4<Float>, AxisRef)] = [
                (Vec3(1, 0, 0), c.x, red, .x),
                (Vec3(0, 1, 0), c.y, green, .y),
            ] + (showZ ? [(Vec3(0, 0, 1), 0, blue, .z)] : [])
            for (dir, center, color, ref) in axes {
                let a = (dir * (center - half)).float, b = (dir * (center + half)).float
                lines.append(LineInstance(a, b, id: pickable ? id(.originAxis(ref)) : 0, color: packColor(color)))
            }
        }
        scene.lines.append(LineBatch(instances: lines, width: (pickable ? 2 : 1.3) * scale, depthBias: -0.003, pickable: pickable))
    }

    private mutating func addOriginPlanes() {
        let s = editor.camera.distance * 0.18
        let planes: [(PlaneRef, Plane)] = [(.xy, .xy), (.xz, .xz), (.yz, .yz)]
        var fills: [FillVertex] = []
        var outlines: [LineInstance] = []
        let fc = packColor(style.plane), oc = packColor(style.planeEdge)
        for (ref, plane) in planes {
            let pid = id(.originPlane(ref))
            let off: Double = 0.08
            let c = [Vec2(off, off), Vec2(1, off), Vec2(1, 1), Vec2(off, 1)].map { plane.point($0 * Double(s)).float }
            for i in [0, 1, 2, 0, 2, 3] { fills.append(FillVertex(x: c[i].x, y: c[i].y, z: c[i].z, id: pid, color: fc)) }
            for i in 0..<4 { outlines.append(LineInstance(c[i], c[(i + 1) % 4], id: pid, color: oc)) }
        }
        scene.fills.append(FillBatch(vertices: fills, depthBias: 0.0005, depth: .readOnly))
        scene.lines.append(LineBatch(instances: outlines, width: 1.2 * scale, depthBias: 0.001))
    }

    // MARK: Highlight ids

    func highlightIds(selection: [Pick], hover: Pick?) -> (UInt32, [UInt32]) {
        var sel: [UInt32] = []
        for p in selection {
            if case let .body(b) = p { sel += bodyFaceIds[b] ?? [] }
            if let i = ids[p] { sel.append(i) }
        }
        if let f = editor.commandFeature {
            switch f.kind {
            case let .extrude(e):
                sel += profileIds(e.profiles)
            case let .revolve(r):
                sel += profileIds(r.profiles)
                if let axis = r.axis {
                    switch axis {
                    case let .sketchLine(s, c): if let i = ids[.sketchCurve(s, c)] { sel.append(i) }
                    case .x, .y, .z: if let i = ids[.originAxis(axis)] { sel.append(i) }
                    case .edge: break
                    }
                }
            default: break
            }
        }
        return (hover.flatMap { ids[$0] } ?? 0, sel)
    }

    private func profileIds(_ profiles: [ProfileRef]) -> [UInt32] {
        profiles.compactMap { p in
            guard let sb = editor.state.sketches[p.sketch], let r = sb.resolve(p) else { return nil }
            return ids[.profile(p.sketch, r.index)]
        }
    }
}
