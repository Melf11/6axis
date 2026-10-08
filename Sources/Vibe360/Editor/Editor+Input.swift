import AppKit
import Foundation
import simd
import VibeCore

extension Editor {
    // MARK: - Hover

    func updateHover(at pt: CGPoint) {
        lastMouse = pt
        let ids = pickProvider(pt, 7)
        let candidates = ids.compactMap { id -> Pick? in
            let i = Int(id) - 1
            return i >= 0 && i < pickTable.count ? pickTable[i] : nil
        }.filter(accepts)
        // ids are sorted nearest-first; prefer points over curves over faces.
        let best = candidates.enumerated().min { a, b in
            (a.element.priority, a.offset) < (b.element.priority, b.offset)
        }?.element
        let newHover = overlayHover ?? best
        if newHover != hover { hover = newHover }
        if sketchId != nil {
            let s = snap(at: pt)
            if s != cursor { cursor = s }
        }
        requestRedraw()
    }

    // MARK: - Mouse

    func mouseDown(at pt: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        markingMenu = nil
        updateHover(at: pt)
        dragState = DragState(start: pt, snapshot: doc, pick: hover,
                              startSketchPos: sketchPosition(at: pt), original: activeSketch)
    }

    /// Returns true if the drag was consumed (otherwise the view orbits).
    func mouseDragged(to pt: CGPoint) -> Bool {
        guard var ds = dragState else { return false }
        let dist = hypot(pt.x - ds.start.x, pt.y - ds.start.y)
        if !ds.moved && dist < 3 { return true }
        if sketchId != nil, sketchTool == .select, let p = ds.pick {
            switch p {
            case .sketchPoint, .sketchCurve:
                if !ds.moved { ds.moved = true; dragState = ds }
                sketchDrag(to: pt)
                return true
            default: break
            }
        }
        if sketchId != nil {
            // Pan in sketch mode keeps the view perpendicular to the sketch.
            ds.moved = true
            dragState = ds
            return false
        }
        ds.moved = true
        dragState = ds
        return false
    }

    func mouseUp(at pt: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        guard let ds = dragState else { return }
        dragState = nil
        if ds.moved {
            if sketchId != nil, ds.original != nil, doc != ds.snapshot, ds.pick != nil {
                pushUndo(ds.snapshot)
            }
            return
        }
        click(at: pt, modifiers: modifiers, clickCount: clickCount)
    }

    func click(at pt: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        if editingDimension != nil { editingDimension = nil }
        if sketchId != nil {
            sketchClick(at: pt, modifiers: modifiers, clickCount: clickCount)
            return
        }
        if command != nil {
            if let h = hover { commandClick(h) }
            return
        }
        guard let h = hover else {
            selection.removeAll()
            timelineSelection = nil
            requestRedraw()
            return
        }
        if clickCount == 2, case let .sketchCurve(sid, _) = h {
            editSketch(sid)
            return
        }
        if modifiers.contains(.shift) || modifiers.contains(.command) {
            if let i = selection.firstIndex(of: h) { selection.remove(at: i) } else { selection.append(h) }
        } else {
            selection = selection == [h] ? [] : [h]
        }
        requestRedraw()
    }

    func rightClick(at pt: CGPoint) {
        updateHover(at: pt)
        markingMenu = pt
    }

    // MARK: - Navigation

    func orbit(dx: CGFloat, dy: CGFloat) {
        cameraAnimation = nil
        camera.orbit(dx: Float(dx), dy: Float(dy))
        requestRedraw()
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        cameraAnimation = nil
        camera.pan(dx: Float(dx), dy: Float(dy))
        requestRedraw()
    }

    func zoom(factor: CGFloat, at pt: CGPoint?) {
        cameraAnimation = nil
        let decade = { floor(log10(max(self.camera.distance, 0.01) / 12)) }
        let before = decade()
        camera.zoom(factor: Float(factor), at: pt)
        if decade() != before { sceneVersion &+= 1 }   // grid density follows zoom
        requestRedraw()
    }

    // MARK: - Keyboard

    /// Fusion-style single-key shortcuts. Returns true if handled.
    func handleKey(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.command) { return false }
        switch keyCode {
        case 53: // Escape
            escape()
            return true
        case 51, 117: // Delete, forward delete
            deleteSelection()
            return true
        case 36, 76: // Return
            if command != nil { commitCommand(); return true }
            if sketchId != nil, sketchTool == .line { toolPoints.removeAll(); requestRedraw(); return true }
            return false
        default:
            break
        }
        switch chars.lowercased() {
        case "s": showCommandPalette = true
        case "l": setSketchTool(.line)
        case "r": setSketchTool(.rectangle)
        case "c": setSketchTool(.circle)
        case "a": setSketchTool(.arc)
        case "d": setSketchTool(.dimension)
        case "x": toggleConstruction()
        case "e", "q": beginCommand(.extrude)
        case "f": beginCommand(.fillet)
        case "h": setSketchTool(.constraint(.horizontal))
        case "v": setSketchTool(.constraint(.vertical))
        case "t": setSketchTool(.constraint(.tangent))
        case "p": setSketchTool(.constraint(.perpendicular))
        case "o": toggleProjection()
        case "6": homeView()
        case "0": fitAll()
        default: return false
        }
        return true
    }

    func escape() {
        markingMenu = nil
        if showCommandPalette { showCommandPalette = false; return }
        if editingDimension != nil { editingDimension = nil; return }
        if command != nil { cancelCommand(); return }
        if sketchId != nil {
            cancelSketchTool()
            return
        }
        selection.removeAll()
        timelineSelection = nil
        requestRedraw()
    }

    func deleteSelection() {
        if sketchId != nil { deleteSketchSelection(); return }
        if let t = timelineSelection { deleteFeature(t); timelineSelection = nil }
    }
}
