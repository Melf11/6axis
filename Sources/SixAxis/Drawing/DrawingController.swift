import AppKit
import Foundation
import Observation
import SixAxisCore

/// Keeps the technical drawing in sync with the model. Generation runs on a background queue,
/// debounced, and only while the drawing window is open.
@Observable
final class DrawingController {
    private(set) var pages: [DrawingPage] = []
    private(set) var isUpdating = false

    var page: DrawingPage? { pages.first }
    var isOpen = false

    @ObservationIgnored private let generator = DrawingGenerator()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.6axis.drawing", qos: .userInitiated)
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var pending: DispatchWorkItem?

    /// Requests a refresh shortly after the last change (keeps typing and dragging fluid).
    func schedule(_ editor: Editor, delay: TimeInterval = 0.25) {
        guard isOpen else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.regenerate(editor)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func regenerate(_ editor: Editor) {
        // While a feature dialog shows a preview, keep the drawing of the committed model.
        if editor.command != nil, page != nil { return }
        let input = Self.input(editor)
        token += 1
        let current = token
        isUpdating = true
        let generator = self.generator
        queue.async { [weak self] in
            let pages = generator.generatePages(input)
            DispatchQueue.main.async {
                guard let self, current == self.token else { return }
                self.pages = pages
                self.isUpdating = false
            }
        }
    }

    /// Visible bodies with their browser names.
    static func input(_ editor: Editor) -> DrawingGenerator.Input {
        let parts = editor.state.orderedBodies.filter { editor.doc.isBodyVisible($0.id) }
            .map { DrawingGenerator.Part(name: editor.doc.bodyName($0.id), shape: $0.shape) }
        return DrawingGenerator.Input(parts: parts, settings: editor.doc.drawing ?? DrawingSettings(),
                                      fallbackTitle: editor.fileURL?.deletingPathExtension().lastPathComponent ?? "Unbenannt")
    }

    /// Live preview of a user dimension being placed on page `index`.
    func preview(_ c: CustomDimension, page index: Int) -> DrawingPage? {
        pages.indices.contains(index) ? generator.adding(c, to: pages[index]) : nil
    }

    /// Synchronous generation (export, printing, tests).
    func generateAllNow(_ editor: Editor) -> [DrawingPage] { generator.generatePages(Self.input(editor)) }
    func generateNow(_ editor: Editor) -> DrawingPage { generateAllNow(editor)[0] }
}

extension Editor {
    var drawingSettings: DrawingSettings { doc.drawing ?? DrawingSettings() }

    /// Live change while dragging: no undo step yet (see `finishDrawingEdit`).
    func setDrawingSettingsLive(_ change: (inout DrawingSettings) -> Void) {
        var s = drawingSettings
        change(&s)
        guard s != drawingSettings else { return }
        doc.drawing = s
    }

    /// Records one undo step for a finished drag that started at `snapshot`.
    func finishDrawingEdit(from snapshot: CADDocument) {
        guard doc != snapshot else { return }
        pushUndo(snapshot)
        scheduleAutosave()
    }

    /// Undoable change of the drawing settings (stored in the document).
    func updateDrawingSettings(_ change: (inout DrawingSettings) -> Void) {
        var s = drawingSettings
        change(&s)
        guard s != drawingSettings else { return }
        commit { $0.drawing = s }
    }

    func exportDrawingPDF() {
        let pages = drawing.generateAllNow(self)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = drawingSettings.title.isEmpty ? (fileURL?.deletingPathExtension().lastPathComponent ?? "Zeichnung") : drawingSettings.title
        panel.nameFieldStringValue = base + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DrawingRenderer.writePDF(pages, to: url, title: base)
            showToast(pages.count == 1 ? "PDF exportiert: \(url.lastPathComponent)" : "PDF mit \(pages.count) Blättern exportiert")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func printDrawing() {
        let pages = drawing.generateAllNow(self)
        guard let page = pages.first else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let k = DrawingRenderer.pointsPerMM()
        info.paperSize = NSSize(width: page.sheet.width * k, height: page.sheet.height * k)
        info.orientation = .landscape
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let op = NSPrintOperation(view: DrawingPrintView(pages: pages), printInfo: info)
        op.jobTitle = drawingSettings.title.isEmpty ? "Zeichnung" : drawingSettings.title
        op.run()
    }
}
