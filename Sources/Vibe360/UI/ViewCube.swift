import simd
import SwiftUI

/// Orientation cube in the top-right corner. Click a face to look at it, drag to orbit.
struct ViewCube: View {
    @Bindable var editor: Editor
    @State private var hovered: Int?
    @State private var lastDrag: CGSize = .zero

    private struct Face {
        let normal: SIMD3<Float>
        let up: SIMD3<Float>
        let label: String
    }

    // Z-up world. "Vorne" looks along +Y (camera at -Y).
    private let faces: [Face] = [
        Face(normal: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0), label: "OBEN"),
        Face(normal: SIMD3(0, 0, -1), up: SIMD3(0, -1, 0), label: "UNTEN"),
        Face(normal: SIMD3(0, -1, 0), up: SIMD3(0, 0, 1), label: "VORNE"),
        Face(normal: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), label: "HINTEN"),
        Face(normal: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1), label: "RECHTS"),
        Face(normal: SIMD3(-1, 0, 0), up: SIMD3(0, 0, 1), label: "LINKS"),
    ]

    private let size: CGFloat = 96

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Canvas { ctx, sz in draw(ctx, sz) }
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                let d = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                                editor.orbit(dx: d.width * 2, dy: d.height * 2)
                                lastDrag = v.translation
                            }
                            .onEnded { _ in lastDrag = .zero }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(p): hovered = face(at: p)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { p in
                        if let i = face(at: p) {
                            let f = faces[i]
                            editor.setView(direction: -f.normal, up: f.up)
                        }
                    }
            }
            HStack(spacing: 2) {
                IconButton(symbol: "house", help: "Ausgangsansicht", size: 24) { editor.homeView() }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Alles einpassen (⌘0)", size: 24) { editor.fitAll() }
                IconButton(symbol: editor.camera.orthographic ? "cube" : "perspective", help: editor.camera.orthographic ? "Orthografisch (O)" : "Perspektive (O)",
                           active: editor.camera.orthographic, size: 24) { editor.toggleProjection() }
            }
            .padding(3)
            .floatingPanel(radius: 9)
        }
    }

    /// Cube vertices in view space (orthographic, rotation only).
    private func viewRotation() -> simd_float3x3 {
        let c = editor.camera
        return simd_float3x3(rows: [c.right, c.up, -c.forward])
    }

    private func corners(_ f: Face) -> [SIMD3<Float>] {
        let n = f.normal
        let u = f.up
        let r = simd_cross(u, n)
        return [n - r - u, n + r - u, n + r + u, n - r + u].map { $0 * 0.5 }
    }

    private func screen(_ p: SIMD3<Float>, _ m: simd_float3x3) -> CGPoint {
        let v = m * p
        let s = Float(size) * 0.42
        return CGPoint(x: CGFloat(v.x * s) + size / 2, y: size / 2 - CGFloat(v.y * s))
    }

    private func visibleFaces() -> [(Int, Float)] {
        let m = viewRotation()
        return faces.enumerated().compactMap { i, f in
            let z = (m * f.normal).z
            return z > 0.02 ? (i, z) : nil
        }.sorted { $0.1 < $1.1 }
    }

    private func face(at p: CGPoint) -> Int? {
        let m = viewRotation()
        for (i, _) in visibleFaces().reversed() {
            let poly = corners(faces[i]).map { screen($0, m) }
            var path = Path()
            path.addLines(poly)
            path.closeSubpath()
            if path.contains(p) { return i }
        }
        return nil
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize) {
        let m = viewRotation()
        let dark = editor.darkMode
        for (i, z) in visibleFaces() {
            let f = faces[i]
            let poly = corners(f).map { screen($0, m) }
            var path = Path()
            path.addLines(poly)
            path.closeSubpath()
            let shade = 0.78 + 0.2 * Double(z)
            let base = dark ? Color(white: 0.30 * shade + 0.05) : Color(white: 0.80 * shade + 0.18)
            ctx.fill(path, with: .color(hovered == i ? Color.accentColor.opacity(0.75) : base))
            ctx.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 0.8)
            if z > 0.35 {
                let center = screen(f.normal * 0.5, m)
                var text = ctx.resolve(Text(f.label).font(.system(size: 8, weight: .bold)))
                text.shading = .color(hovered == i ? .white : .primary.opacity(0.75))
                var c2 = ctx
                // Rotate the label with the face's up vector so it reads naturally.
                let upS = screen(f.normal * 0.5 + f.up * 0.3, m)
                let angle = atan2(upS.x - center.x, -(upS.y - center.y))
                c2.translateBy(x: center.x, y: center.y)
                c2.rotate(by: .radians(Double(angle)))
                c2.scaleBy(x: 1, y: max(0.4, CGFloat(z)))
                c2.draw(text, at: .zero)
            }
        }
        // Axis triad at the cube corner.
        let origin = screen(SIMD3(-0.5, -0.5, -0.5), m)
        let axes: [(SIMD3<Float>, Color)] = [(SIMD3(1, 0, 0), .red), (SIMD3(0, 1, 0), .green), (SIMD3(0, 0, 1), .blue)]
        for (a, color) in axes {
            var p = Path()
            p.move(to: origin)
            p.addLine(to: screen(SIMD3(-0.5, -0.5, -0.5) + a * 0.55, m))
            ctx.stroke(p, with: .color(color.opacity(0.9)), lineWidth: 2)
        }
    }
}
