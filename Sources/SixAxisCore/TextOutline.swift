import CoreGraphics
import CoreText
import Foundation
import simd

/// Glyph outlines of a text line (CoreText), as sketch segments. The text height is the cap height:
/// a capital letter is exactly `height` tall, which is what woodworkers and makers measure.
public enum TextOutline {
    public static let defaultFont = "Helvetica-Bold"

    /// Closed contours (each a list of segments) with the baseline start at `origin`.
    public static func contours(_ text: String, height: Double, font: String?, origin: Vec2) -> [[Segment2D]] {
        guard !text.isEmpty, height > 0 else { return [] }
        let probe = CTFontCreateWithName((font ?? defaultFont) as CFString, 100, nil)
        let capRatio = max(CTFontGetCapHeight(probe), 1) / 100
        let ctFont = CTFontCreateWithName((font ?? defaultFont) as CFString, CGFloat(height) / capRatio, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont])
        let line = CTLineCreateWithAttributedString(attributed)
        var out: [[Segment2D]] = []
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (g, pos) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(runFont, g, nil) else { continue }
                let shift = origin + Vec2(Double(pos.x), Double(pos.y))
                out += contours(of: path, shift: shift)
            }
        }
        return out
    }

    static func contours(of path: CGPath, shift: Vec2) -> [[Segment2D]] {
        var result: [[Segment2D]] = []
        var current: [Segment2D] = []
        var start = Vec2.zero, last = Vec2.zero
        func v(_ p: CGPoint) -> Vec2 { Vec2(Double(p.x), Double(p.y)) + shift }
        func close() {
            if simd_distance(last, start) > 1e-9 { current.append(.line(last, start)) }
            if !current.isEmpty { result.append(current) }
            current = []
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if !current.isEmpty { close() }
                start = v(e.points[0]); last = start
            case .addLineToPoint:
                let p = v(e.points[0])
                if simd_distance(p, last) > 1e-9 { current.append(.line(last, p)) }
                last = p
            case .addQuadCurveToPoint:
                // Quadratic → cubic Bézier.
                let c = v(e.points[0]), p = v(e.points[1])
                current.append(.bezier(last, last + (c - last) * (2.0 / 3), p + (c - p) * (2.0 / 3), p))
                last = p
            case .addCurveToPoint:
                let p = v(e.points[2])
                current.append(.bezier(last, v(e.points[0]), v(e.points[1]), p))
                last = p
            case .closeSubpath:
                close()
                last = start
            @unknown default:
                break
            }
        }
        if !current.isEmpty { close() }
        return result
    }

    /// Sampled contours for drawing and picking.
    public static func polylines(_ contours: [[Segment2D]], perCurve k: Int = 8) -> [[Vec2]] {
        contours.map { segs in
            var pts: [Vec2] = []
            for s in segs {
                switch s {
                case let .line(a, b):
                    if pts.isEmpty { pts.append(a) }
                    pts.append(b)
                case let .bezier(p0, p1, p2, p3):
                    if pts.isEmpty { pts.append(p0) }
                    for j in 1...k { pts.append(Spline.point((p0, p1, p2, p3), Double(j) / Double(k))) }
                default:
                    break
                }
            }
            return pts
        }
    }
}
