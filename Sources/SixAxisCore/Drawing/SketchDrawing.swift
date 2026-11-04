import Foundation
import simd

/// A sketch as a drawing sheet, complete enough to plan from without 6axis: every line with its length, every
/// circle and arc with its size, the overall dimensions, and each closed area with its area and perimeter.
public enum SketchDrawing {
    private static let margin = 10.0
    private static let titleHeight = 14.0
    /// Room around the sketch for its overall dimensions and labels.
    private static let clearance = 16.0
    private static let textHeight = 2.5

    /// nil when the sketch has nothing to draw.
    public static func page(_ build: SketchBuild, title: String, date: Date = Date()) -> DrawingPage? {
        let sk = build.sketch
        let curves = sk.curves.map { (curve: $0, lines: sk.polylines($0, segments: 96)) }
        let solid = curves.filter { !$0.curve.construction }
        let points = (solid.isEmpty ? curves : solid).flatMap { $0.lines.flatMap { $0 } }
        guard let first = points.first else { return nil }
        let lo = points.reduce(first, simd_min), hi = points.reduce(first, simd_max)
        let size = hi - lo

        let upright = size.y > size.x
        let sheet = upright ? Sheet(name: "A4", width: Sheet.a4.height, height: Sheet.a4.width) : Sheet.a4
        let room = Vec2(sheet.width - 2 * margin - 2 * clearance, sheet.height - 2 * margin - titleHeight - 2 * clearance)
        let scale = fittingScale(size, room)
        var page = DrawingPage(sheet: sheet, scale: scale)
        page.name = title
        page.isEmpty = false
        let s = scale.factor
        let center = Vec2(sheet.width / 2, margin + titleHeight + clearance + room.y / 2)
        let middle = (lo + hi) / 2
        func paper(_ p: Vec2) -> Vec2 { center + (p - middle) * s }

        for (curve, lines) in curves {
            for line in lines where line.count >= 2 {
                page.lines.append(DrawingLine(points: line.map(paper), style: curve.construction ? .hidden : .visible))
            }
            if !curve.construction { addLabel(&page, curve, sk, paper) }
        }
        addAreas(&page, build, paper)
        addOverall(&page, paper(lo), paper(hi), size)
        addOrigin(&page, paper(.zero), inside: paper(lo), paper(hi))
        addFrameAndTitle(&page, title: title, sketchSize: size, date: date)
        return page
    }

    /// The largest ISO scale that fits, or an exact one for very large sketches.
    private static func fittingScale(_ size: Vec2, _ room: Vec2) -> DrawingScale {
        let needed = min(room.x / max(size.x, 1e-9), room.y / max(size.y, 1e-9))
        if let iso = DrawingScale.all.first(where: { $0.factor <= needed }) { return iso }
        let n = (1 / needed).rounded(.up)
        return DrawingScale(factor: 1 / n, label: "1:\(Int(n))")
    }

    private static func addLabel(_ page: inout DrawingPage, _ curve: SketchCurve, _ sk: Sketch, _ paper: (Vec2) -> Vec2) {
        switch curve.geometry {
        case let .line(a, b):
            guard let pa = sk.point(a), let pb = sk.point(b) else { return }
            alongLine(&page, formatValue(simd_distance(pa, pb)), paper(pa), paper(pb))
        case .circle:
            guard let c = sk.center(of: curve) else { return }
            let size = 2 * sk.radius(of: curve)
            let text = curve.polygon.map { String(localized: "\($0.sides)-Eck, Schlüsselweite \(formatValue(size))") } ?? "Ø " + formatValue(size)
            page.texts.append(DrawingText(text: text, position: paper(c) - Vec2(0, textHeight * 2), height: textHeight))
        case .arc:
            let line = sk.polyline(curve, segments: 32)
            guard line.count >= 2 else { return }
            let mid = paper(line[line.count / 2])
            page.texts.append(DrawingText(text: "R " + formatValue(sk.radius(of: curve)), position: mid + Vec2(1.5, 1.5), height: textHeight, anchor: .left))
        case .spline:
            let line = sk.polyline(curve, segments: 32)
            guard line.count >= 2 else { return }
            let mid = paper(line[line.count / 2])
            page.texts.append(DrawingText(text: "L " + formatValue(sk.length(of: curve)), position: mid + Vec2(1.5, 1.5), height: textHeight, anchor: .left))
        case .text:
            break
        }
    }

    /// A text beside a line, turned with it and readable from below or from the right.
    private static func alongLine(_ page: inout DrawingPage, _ text: String, _ a: Vec2, _ b: Vec2) {
        let d = b - a
        guard simd_length(d) > 1e-9 else { return }
        var angle = atan2(d.y, d.x)
        if angle > .pi / 2 + 1e-6 { angle -= .pi } else if angle <= -.pi / 2 + 1e-6 { angle += .pi }
        let up = Vec2(-sin(angle), cos(angle))
        page.texts.append(DrawingText(text: text, position: (a + b) / 2 + up * 1.2, height: textHeight, angle: angle))
    }

    private static func addAreas(_ page: inout DrawingPage, _ build: SketchBuild, _ paper: (Vec2) -> Vec2) {
        for (i, region) in build.regions.enumerated() {
            // A point known to lie inside: the centre of an L-shape lies outside it.
            let at = paper(build.profileRef(region).sample)
            let name = build.regions.count > 1 ? String(localized: "Fläche \(i + 1)") : String(localized: "Fläche")
            page.texts.append(DrawingText(text: name + ": " + String(format: "%.2f cm²", region.face.area / 100), position: at + Vec2(0, 0.8), height: textHeight, bold: true))
            page.texts.append(DrawingText(text: String(localized: "Umfang \(formatValue(region.face.perimeter))"), position: at - Vec2(0, 3), height: textHeight))
        }
    }

    private static func addOverall(_ page: inout DrawingPage, _ lo: Vec2, _ hi: Vec2, _ size: Vec2) {
        let offset = 9.0
        if size.x > 1e-9 {
            let y = lo.y - offset
            page.lines.append(DrawingLine(points: [Vec2(lo.x, lo.y - 1), Vec2(lo.x, y - 1.5)], style: .thin))
            page.lines.append(DrawingLine(points: [Vec2(hi.x, lo.y - 1), Vec2(hi.x, y - 1.5)], style: .thin))
            page.lines.append(DrawingLine(points: [Vec2(lo.x, y), Vec2(hi.x, y)], style: .thin))
            page.arrows.append(DrawingArrow(tip: Vec2(lo.x, y), direction: Vec2(-1, 0)))
            page.arrows.append(DrawingArrow(tip: Vec2(hi.x, y), direction: Vec2(1, 0)))
            page.texts.append(DrawingText(text: formatValue(size.x), position: Vec2((lo.x + hi.x) / 2, y + 1), height: 3, bold: true))
        }
        if size.y > 1e-9 {
            let x = lo.x - offset
            page.lines.append(DrawingLine(points: [Vec2(lo.x - 1, lo.y), Vec2(x - 1.5, lo.y)], style: .thin))
            page.lines.append(DrawingLine(points: [Vec2(lo.x - 1, hi.y), Vec2(x - 1.5, hi.y)], style: .thin))
            page.lines.append(DrawingLine(points: [Vec2(x, lo.y), Vec2(x, hi.y)], style: .thin))
            page.arrows.append(DrawingArrow(tip: Vec2(x, lo.y), direction: Vec2(0, -1)))
            page.arrows.append(DrawingArrow(tip: Vec2(x, hi.y), direction: Vec2(0, 1)))
            page.texts.append(DrawingText(text: formatValue(size.y), position: Vec2(x - 1, (lo.y + hi.y) / 2), height: 3, angle: .pi / 2, bold: true))
        }
    }

    /// Marks the sketch's origin when it lies on the sketch.
    private static func addOrigin(_ page: inout DrawingPage, _ o: Vec2, inside lo: Vec2, _ hi: Vec2) {
        guard o.x >= lo.x - 1e-6, o.y >= lo.y - 1e-6, o.x <= hi.x + 1e-6, o.y <= hi.y + 1e-6 else { return }
        page.lines.append(DrawingLine(points: [o - Vec2(2.5, 0), o + Vec2(2.5, 0)], style: .center))
        page.lines.append(DrawingLine(points: [o - Vec2(0, 2.5), o + Vec2(0, 2.5)], style: .center))
    }

    private static func addFrameAndTitle(_ page: inout DrawingPage, title: String, sketchSize: Vec2, date: Date) {
        let w = page.sheet.width, h = page.sheet.height
        let a = Vec2(margin, margin), b = Vec2(w - margin, h - margin)
        page.lines.append(DrawingLine(points: [a, Vec2(b.x, a.y), b, Vec2(a.x, b.y), a], style: .frame))
        let top = margin + titleHeight
        page.lines.append(DrawingLine(points: [Vec2(a.x, top), Vec2(b.x, top)], style: .thin))
        page.texts.append(DrawingText(text: title, position: Vec2(a.x + 3, top - 6), height: 4, anchor: .left, bold: true))
        let details = String(localized: "Maßstab \(page.scale.label) · Maße in mm · Skizze \(formatValue(sketchSize.x)) × \(formatValue(sketchSize.y))")
        page.texts.append(DrawingText(text: details, position: Vec2(a.x + 3, top - 11), height: textHeight, anchor: .left))
        let day = date.formatted(.iso8601.year().month().day())
        page.texts.append(DrawingText(text: String(localized: "6axis · \(day)"), position: Vec2(b.x - 3, top - 11), height: textHeight, anchor: .right))
    }
}
