import simd
import SwiftUI

/// Orientation cube in the top-right corner, like Fusion's ViewCube.
/// Each face is split into a 3×3 grid: the center looks at the face, the borders at edges, the corners at corners.
/// Drag on the cube to orbit.
struct ViewCube: View {
    @Bindable var editor: Editor
    @State private var hovered: Region?
    @State private var lastDrag: CGSize = .zero

    private struct Face {
        let normal: SIMD3<Float>
        let up: SIMD3<Float>
        let label: String
        /// Right-hand direction when looking at the face from outside.
        var right: SIMD3<Float> { simd_cross(up, normal) }
    }

    /// A clickable cell: face index plus position in the 3×3 grid (-1, 0, 1).
    private struct Region: Equatable {
        let face: Int
        let u: Int
        let v: Int
    }

    // Z-up world. "Vorne" faces -Y, i.e. the camera looks along +Y.
    private let faces: [Face] = [
        Face(normal: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0), label: String(localized: "OBEN")),
        Face(normal: SIMD3(0, 0, -1), up: SIMD3(0, -1, 0), label: String(localized: "UNTEN")),
        Face(normal: SIMD3(0, -1, 0), up: SIMD3(0, 0, 1), label: String(localized: "VORNE")),
        Face(normal: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), label: String(localized: "HINTEN")),
        Face(normal: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1), label: String(localized: "RECHTS")),
        Face(normal: SIMD3(-1, 0, 0), up: SIMD3(0, 0, 1), label: String(localized: "LINKS")),
    ]

    private let size: CGFloat = 104
    /// Border width of edge/corner cells, as a fraction of the face side.
    private let border: Float = 0.2

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, _ in draw(ctx) }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { v in
                            let d = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                            editor.orbit(dx: d.width * 2, dy: d.height * 2)
                            lastDrag = v.translation
                        }
                        .onEnded { _ in lastDrag = .zero }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p): hovered = region(at: p)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { p in
                    if let r = region(at: p) { look(at: r) }
                }
                .help("Klick auf Fläche, Kante oder Ecke richtet die Ansicht aus · Ziehen dreht")
            HStack(spacing: 2) {
                IconButton(symbol: "house", help: String(localized: "Ausgangsansicht"), size: 24) { editor.homeView() }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: String(localized: "Alles einpassen (⌘0)"), size: 24) { editor.fitAll() }
                IconButton(symbol: editor.isOrthographic ? "cube" : "perspective", help: editor.isOrthographic ? String(localized: "Orthografisch (O)") : String(localized: "Perspektive (O)"),
                           active: editor.isOrthographic, size: 24) { editor.toggleProjection() }
            }
            .padding(3)
            .floatingPanel(radius: 9)
        }
    }

    // MARK: Projection (orthographic, rotation only)

    private var rotation: simd_float3x3 {
        let c = editor.camera
        return simd_float3x3(rows: [c.right, c.up, -c.forward])
    }

    private var scale: CGFloat { size * 0.36 }

    private func screen(_ p: SIMD3<Float>) -> CGPoint {
        let v = rotation * p
        return CGPoint(x: size / 2 + CGFloat(v.x) * scale, y: size / 2 - CGFloat(v.y) * scale)
    }

    /// Screen-space frame of a face: center, and vectors spanning one full side along right/up.
    private func frame(_ f: Face) -> (c: CGPoint, r: CGVector, u: CGVector) {
        let c = screen(f.normal * 0.5)
        let pr = screen(f.normal * 0.5 + f.right * 0.5), pu = screen(f.normal * 0.5 + f.up * 0.5)
        return (c, CGVector(dx: (pr.x - c.x) * 2, dy: (pr.y - c.y) * 2), CGVector(dx: (pu.x - c.x) * 2, dy: (pu.y - c.y) * 2))
    }

    private func point(_ fr: (c: CGPoint, r: CGVector, u: CGVector), _ a: Float, _ b: Float) -> CGPoint {
        CGPoint(x: fr.c.x + CGFloat(a) * fr.r.dx + CGFloat(b) * fr.u.dx,
                y: fr.c.y + CGFloat(a) * fr.r.dy + CGFloat(b) * fr.u.dy)
    }

    private func quad(_ fr: (c: CGPoint, r: CGVector, u: CGVector), _ a0: Float, _ a1: Float, _ b0: Float, _ b1: Float) -> Path {
        var p = Path()
        p.addLines([point(fr, a0, b0), point(fr, a1, b0), point(fr, a1, b1), point(fr, a0, b1)])
        p.closeSubpath()
        return p
    }

    /// Faces turned towards the viewer, back to front.
    private func visibleFaces() -> [(Int, Float)] {
        faces.enumerated().compactMap { i, f in
            let z = (rotation * f.normal).z
            return z > 0.01 ? (i, z) : nil
        }.sorted { $0.1 < $1.1 }
    }

    private func cellBounds(_ k: Int) -> (Float, Float) {
        let h: Float = 0.5, inner = h - border
        switch k {
        case -1: return (-h, -inner)
        case 1: return (inner, h)
        default: return (-inner, inner)
        }
    }

    // MARK: Hit testing

    private func region(at p: CGPoint) -> Region? {
        for (i, _) in visibleFaces().reversed() {
            let fr = frame(faces[i])
            // Invert the 2×2 map (a, b) → c + a·r + b·u.
            let det = fr.r.dx * fr.u.dy - fr.r.dy * fr.u.dx
            guard abs(det) > 1e-6 else { continue }
            let dx = p.x - fr.c.x, dy = p.y - fr.c.y
            let a = Float((dx * fr.u.dy - dy * fr.u.dx) / det)
            let b = Float((fr.r.dx * dy - fr.r.dy * dx) / det)
            guard abs(a) <= 0.5, abs(b) <= 0.5 else { continue }
            let inner = 0.5 - border
            return Region(face: i, u: a > inner ? 1 : (a < -inner ? -1 : 0), v: b > inner ? 1 : (b < -inner ? -1 : 0))
        }
        return nil
    }

    private func look(at r: Region) {
        let f = faces[r.face]
        let d = simd_normalize(f.normal + Float(r.u) * f.right + Float(r.v) * f.up)
        // Edge and corner views keep Z up; straight top/bottom views use the face's own up vector.
        let up = (r.u == 0 && r.v == 0) || abs(d.z) > 0.99 ? f.up : SIMD3<Float>(0, 0, 1)
        editor.setView(direction: -d, up: up)
    }

    /// Whether a cell of another face belongs to the same edge/corner as the hovered cell (highlight across faces).
    private func sameDirection(_ a: Region, _ b: Region) -> Bool {
        func dir(_ r: Region) -> SIMD3<Float> {
            let f = faces[r.face]
            return f.normal + Float(r.u) * f.right + Float(r.v) * f.up
        }
        return simd_distance(dir(a), dir(b)) < 1e-3
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext) {
        let dark = editor.darkMode
        let edge = Color.primary.opacity(dark ? 0.45 : 0.3)
        for (i, z) in visibleFaces() {
            let f = faces[i]
            let fr = frame(f)
            let outline = quad(fr, -0.5, 0.5, -0.5, 0.5)
            // Faces turned towards the viewer are lighter, giving the cube a clear 3D read.
            let light = Double(z)
            let base = dark ? Color(white: 0.20 + 0.16 * light) : Color(white: 0.74 + 0.24 * light)
            ctx.fill(outline, with: .color(base))

            if let h = hovered {
                for cu in -1...1 {
                    for cv in -1...1 {
                        let cell = Region(face: i, u: cu, v: cv)
                        guard cell == h || ((cu != 0 || cv != 0) && sameDirection(cell, h)) else { continue }
                        let (a0, a1) = cellBounds(cu), (b0, b1) = cellBounds(cv)
                        ctx.fill(quad(fr, a0, a1, b0, b1), with: .color(Color.accentColor.opacity(0.75)))
                    }
                }
            }

            // Label mapped onto the face: local text space is a 44×44 square, y pointing down.
            if z > 0.15 {
                let s: CGFloat = 44
                var c2 = ctx
                c2.concatenate(CGAffineTransform(a: fr.r.dx / s, b: fr.r.dy / s, c: -fr.u.dx / s, d: -fr.u.dy / s, tx: fr.c.x, ty: fr.c.y))
                let isHovered = hovered.map { $0.face == i && $0.u == 0 && $0.v == 0 } ?? false
                let text = Text(f.label)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(isHovered ? Color.white : Color.primary.opacity(dark ? 0.85 : 0.7))
                c2.draw(text, at: .zero, anchor: .center)
            }
            ctx.stroke(outline, with: .color(edge), lineWidth: 0.8)
        }
    }
}
