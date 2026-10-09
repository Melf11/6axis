import AppKit
import MetalKit
import SwiftUI

/// The Metal viewport. Translates raw input into editor actions and camera navigation.
///
/// Navigation (Fusion-like, Mac-friendly):
/// - Trackpad: two-finger swipe orbits (pans inside a sketch), ⇧ + swipe pans, pinch zooms.
/// - Mouse: right-drag orbits, middle-drag pans (⇧ + middle orbits), wheel zooms at the cursor.
/// - ⌥ + left-drag orbits everywhere.
final class ViewportNSView: MTKView {
    let editor: Editor
    private var renderer: Renderer?
    private var builtVersion = -1
    private var builtDark = false
    private var builtScale: CGFloat = 0
    private var builtSettings = -1
    private var sceneBuilder: SceneBuilder?
    private var lastDrag: CGPoint?
    private var rightDragged = false
    private var builtGridVersion = -1
    /// Hover picking renders the ID buffer and waits for the GPU – too slow for every scroll event,
    /// so it runs once the gesture pauses.
    private var hoverWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    init(editor: Editor) {
        self.editor = editor
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = Renderer.sampleCount
        clearColor = MTLClearColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1)
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 120
        if let device, let r = Renderer(device: device) {
            renderer = r
            delegate = r
            r.frameProvider = { [weak self] in self?.frameState() ?? Renderer.FrameState(camera: Camera(), hoverId: 0, selection: [], dark: false, animating: false) }
        }
        editor.requestRedraw = { [weak self] in self?.needsDisplay = true }
        editor.snapshotProvider = { [weak self] in self?.snapshotWindow() }
        editor.focusViewport = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
        }
        editor.pickProvider = { [weak self] pt, radius in
            guard let self, let renderer = self.renderer else { return [] }
            self.syncScene()
            let s = self.window?.backingScaleFactor ?? 2
            return renderer.pick(at: CGPoint(x: pt.x * s, y: pt.y * s), drawableSize: self.drawableSize, radius: Int(radius * s))
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        editor.camera.viewSize = newSize
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        editor.darkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: Scene sync

    private func syncScene() {
        let scale = window?.backingScaleFactor ?? 2
        let rev = AppSettings.shared.revision
        let full = editor.sceneVersion != builtVersion || editor.darkMode != builtDark || scale != builtScale || rev != builtSettings
        if full || editor.gridVersion != builtGridVersion {
            var g = SceneBuilder(editor: editor, scale: scale)
            g.buildGrid()
            renderer?.uploadGrid(g.scene.lines)
            builtGridVersion = editor.gridVersion
        }
        guard full else { return }
        builtSettings = rev
        var b = SceneBuilder(editor: editor, scale: scale)
        b.build()
        renderer?.upload(b.scene)
        editor.pickTable = b.picks
        editor.pickIds = b.ids
        sceneBuilder = b
        builtVersion = editor.sceneVersion
        builtDark = editor.darkMode
        builtScale = scale
    }

    private func frameState() -> Renderer.FrameState {
        let animating = editor.stepAnimation()
        if editor.camera.viewSize != bounds.size { editor.camera.viewSize = bounds.size }
        syncScene()
        let (hover, sel) = sceneBuilder?.highlightIds(selection: editor.selection, hover: editor.hover) ?? (0, [])
        return Renderer.FrameState(camera: editor.camera, hoverId: hover, selection: sel, dark: editor.darkMode, animating: animating)
    }

    /// Window snapshot: Metal viewport plus the SwiftUI chrome on top.
    func snapshotWindow() -> NSImage? {
        guard let renderer, let window, let content = window.contentView else { return nil }
        let scale = window.backingScaleFactor
        let size = content.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let vpFrame = convert(bounds, to: content)
        guard let viewport = renderer.snapshot(width: Int(bounds.width * scale), height: Int(bounds.height * scale)),
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.draw(viewport, in: vpFrame)
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        _ = (w, h)
        return image
    }

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseMoved(with event: NSEvent) {
        editor.updateHover(at: point(event))
    }

    override func mouseExited(with event: NSEvent) {
        if editor.hover != nil { editor.hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the canvas takes keyboard focus back from on-canvas input fields.
        editor.toolInputFocus = nil
        window?.makeFirstResponder(self)
        lastDrag = point(event)
        if event.modifierFlags.contains(.option) { return }
        editor.mouseDown(at: point(event), modifiers: event.modifierFlags, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        defer { lastDrag = p }
        guard let last = lastDrag else { return }
        if event.modifierFlags.contains(.option) {
            editor.orbit(dx: p.x - last.x, dy: p.y - last.y)
            return
        }
        if !editor.mouseDragged(to: p) {
            if editor.sketchId != nil {
                editor.pan(dx: p.x - last.x, dy: p.y - last.y)
            } else {
                editor.orbit(dx: p.x - last.x, dy: p.y - last.y)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
        if event.modifierFlags.contains(.option) { editor.dragState = nil; return }
        editor.mouseUp(at: point(event), modifiers: event.modifierFlags, clickCount: event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        lastDrag = point(event)
        rightDragged = false
    }

    override func rightMouseDragged(with event: NSEvent) {
        let p = point(event)
        if let last = lastDrag {
            if hypot(p.x - last.x, p.y - last.y) > 0 { rightDragged = true }
            editor.orbit(dx: p.x - last.x, dy: p.y - last.y)
        }
        lastDrag = p
    }

    override func rightMouseUp(with event: NSEvent) {
        if !rightDragged { editor.rightClick(at: point(event)) }
        lastDrag = nil
    }

    override func otherMouseDown(with event: NSEvent) { lastDrag = point(event) }

    override func otherMouseDragged(with event: NSEvent) {
        let p = point(event)
        if let last = lastDrag {
            if event.modifierFlags.contains(.shift) {
                editor.orbit(dx: p.x - last.x, dy: p.y - last.y)
            } else {
                editor.pan(dx: p.x - last.x, dy: p.y - last.y)
            }
        }
        lastDrag = p
    }

    override func scrollWheel(with event: NSEvent) {
        let p = point(event)
        let settings = AppSettings.shared
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        // macOS already flipped the deltas for "natural scrolling"; undo that if the user wants physical directions.
        if settings.ignoreNaturalScrolling && event.isDirectionInvertedFromDevice {
            dx = -dx
            dy = -dy
        }
        if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.command) {
                let sign: CGFloat = settings.invertWheelZoom ? -1 : 1
                editor.zoom(factor: 1 - sign * dy * 0.01 * settings.zoomSpeed, at: p)
            } else {
                // Base action from settings; ⇧ toggles; sketches swap so two fingers pan by default.
                var orbit = settings.trackpadSwipe == .orbit
                if event.modifierFlags.contains(.shift) { orbit.toggle() }
                if editor.sketchId != nil { orbit.toggle() }
                if orbit {
                    let sign: CGFloat = settings.invertTrackpadOrbit ? -1 : 1
                    editor.orbit(dx: -dx * 1.4 * sign, dy: -dy * 1.4 * sign)
                } else {
                    let sign: CGFloat = settings.invertTrackpadPan ? -1 : 1
                    editor.pan(dx: dx * sign, dy: dy * sign)
                }
            }
        } else {
            let sign: CGFloat = settings.invertWheelZoom ? -1 : 1
            editor.zoom(factor: pow(1.12, -dy * sign * settings.zoomSpeed), at: p)
        }
        scheduleHover(at: p)
    }

    private func scheduleHover(at p: CGPoint) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.editor.updateHover(at: p) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func magnify(with event: NSEvent) {
        let m = event.magnification * AppSettings.shared.zoomSpeed
        editor.zoom(factor: 1 / (1 + m), at: point(event))
        scheduleHover(at: point(event))
    }

    override func smartMagnify(with event: NSEvent) {
        editor.fitAll()
    }

    // MARK: Keyboard

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if editor.sketchId != nil { editor.updateHover(at: editor.lastMouse) }
    }

    override func keyDown(with event: NSEvent) {
        if !editor.handleKey(event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags) {
            super.keyDown(with: event)
        }
    }
}

struct ViewportView: NSViewRepresentable {
    let editor: Editor

    func makeNSView(context: Context) -> ViewportNSView { ViewportNSView(editor: editor) }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        _ = AppSettings.shared.revision   // redraw when preferences change
        view.needsDisplay = true
    }
}
