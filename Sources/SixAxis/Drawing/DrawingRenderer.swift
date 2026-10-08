import AppKit
import CoreText
import SixAxisCore
import simd

/// Draws a `DrawingPage` with Core Graphics. Used for the window, PDF export and printing,
/// so what you see is exactly what you print.
enum DrawingRenderer {
    /// Draws the page into `cg`, whose user space is in points with y pointing up and the
    /// sheet's bottom-left corner at the origin. `pointsPerMM` maps paper millimetres to points.
    static func draw(_ page: DrawingPage, in cg: CGContext, pointsPerMM k: CGFloat, ink: CGColor = .black,
                     highlight: [String: CGColor] = [:]) {
        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setStrokeColor(ink)
        cg.setFillColor(ink)

        // Paper.
        cg.setFillColor(CGColor(gray: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: page.sheet.width * k, height: page.sheet.height * k))
        cg.setFillColor(ink)

        for line in page.lines where line.points.count >= 2 {
            let color = line.group.flatMap { highlight[$0] }
            cg.setStrokeColor(color ?? ink)
            cg.setLineWidth(CGFloat(line.style.width) * k * (color != nil ? 1.6 : 1))
            if let dash = line.style.dash {
                cg.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) * k })
                cg.setLineCap(.butt)
            } else {
                cg.setLineDash(phase: 0, lengths: [])
                cg.setLineCap(.round)
            }
            cg.beginPath()
            cg.move(to: point(line.points[0], k))
            for p in line.points.dropFirst() { cg.addLine(to: point(p, k)) }
            cg.strokePath()
        }
        cg.setLineDash(phase: 0, lengths: [])

        // ISO 129 arrowheads: 3 mm long, 15° half-angle, filled.
        cg.setStrokeColor(ink)
        for a in page.arrows {
            cg.setFillColor(a.group.flatMap { highlight[$0] } ?? ink)
            let u = simd_normalize(a.direction)
            let n = Vec2(-u.y, u.x)
            let back = a.tip - u * 3
            let half = 3 * tan(15 * Double.pi / 180)
            cg.beginPath()
            cg.move(to: point(a.tip, k))
            cg.addLine(to: point(back + n * half, k))
            cg.addLine(to: point(back - n * half, k))
            cg.closePath()
            cg.fillPath()
        }

        for t in page.texts { drawText(t, in: cg, k: k, color: t.group.flatMap { highlight[$0] } ?? ink) }
        cg.restoreGState()
    }

    private static func point(_ p: Vec2, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }

    /// Text height is the capital height in mm (ISO 3098); font size derived from the cap-height ratio.
    private static func drawText(_ t: DrawingText, in cg: CGContext, k: CGFloat, color: CGColor) {
        guard !t.text.isEmpty else { return }
        let base = t.bold ? NSFont.systemFont(ofSize: 10, weight: .semibold) : NSFont.systemFont(ofSize: 10)
        let size = CGFloat(t.height) * k / (base.capHeight / base.pointSize)
        let font = t.bold ? NSFont.systemFont(ofSize: size, weight: .semibold) : NSFont.systemFont(ofSize: size)
        let attr = NSAttributedString(string: t.text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .black,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let dx: CGFloat
        switch t.anchor {
        case .left: dx = 0
        case .center: dx = -width / 2
        case .right: dx = -width
        }
        cg.saveGState()
        cg.translateBy(x: t.position.x * k, y: t.position.y * k)
        cg.rotate(by: CGFloat(t.angle))
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: dx, y: 0)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    // MARK: Export

    static func pointsPerMM() -> CGFloat { 72 / 25.4 }

    /// Writes a vector PDF at true scale (1 mm on paper = 1 mm in the PDF), one PDF page per sheet.
    static func writePDF(_ pages: [DrawingPage], to url: URL, title: String) throws {
        guard let first = pages.first else { return }
        let k = pointsPerMM()
        var box = CGRect(x: 0, y: 0, width: first.sheet.width * k, height: first.sheet.height * k)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "6axis"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw NSError(domain: "6axis", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "PDF konnte nicht erstellt werden")])
        }
        for page in pages {
            var media = CGRect(x: 0, y: 0, width: page.sheet.width * k, height: page.sheet.height * k)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            draw(page, in: ctx, pointsPerMM: k)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func writePDF(_ page: DrawingPage, to url: URL, title: String) throws {
        try writePDF([page], to: url, title: title)
    }
}

/// Printable view: all sheets stacked vertically, one printed page each, at true scale.
final class DrawingPrintView: NSView {
    let pages: [DrawingPage]
    private let pageSize: NSSize

    init(pages: [DrawingPage]) {
        self.pages = pages
        let k = DrawingRenderer.pointsPerMM()
        let w = (pages.map(\.sheet.width).max() ?? 297) * k, h = (pages.map(\.sheet.height).max() ?? 210) * k
        pageSize = NSSize(width: w, height: h)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h * CGFloat(max(pages.count, 1))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        // Page 1 is the topmost slice of the (unflipped) view.
        NSRect(x: 0, y: CGFloat(pages.count - page) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        for (i, page) in pages.enumerated() {
            cg.saveGState()
            cg.translateBy(x: 0, y: CGFloat(pages.count - 1 - i) * pageSize.height)
            DrawingRenderer.draw(page, in: cg, pointsPerMM: DrawingRenderer.pointsPerMM())
            cg.restoreGState()
        }
    }
}
