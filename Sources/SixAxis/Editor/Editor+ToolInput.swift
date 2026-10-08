import Foundation
import simd
import SixAxisCore

/// One value field shown next to the rubber band while drawing (Fusion's on-canvas inputs).
struct ToolInputSpec {
    let label: String
    let kind: ValueKind
}

/// Typed values while drawing: after the first click the fields appear, Tab cycles, ↩ creates the geometry.
/// A field with a valid value is "locked" and overrides the mouse; empty fields follow the cursor.
extension Editor {
    var toolInputSpecs: [ToolInputSpec] {
        guard sketchId != nil, !toolPoints.isEmpty else { return [] }
        switch sketchTool {
        case .line: return [ToolInputSpec(label: "Länge", kind: .length), ToolInputSpec(label: "Winkel", kind: .angle)]
        case .rectangle, .centerRectangle: return [ToolInputSpec(label: "Breite", kind: .length), ToolInputSpec(label: "Höhe", kind: .length)]
        case .circle: return [ToolInputSpec(label: "⌀", kind: .length)]
        default: return []
        }
    }

    /// Parsed value of a field, or nil if empty/invalid (then the mouse decides).
    func toolInputValue(_ i: Int) -> Double? {
        let specs = toolInputSpecs
        guard i < specs.count, i < toolInputs.count else { return nil }
        let text = toolInputs[i].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let v = try? evaluator.value(text, kind: specs[i].kind) else { return nil }
        if specs[i].kind == .length && v <= 0 { return nil }
        return v
    }

    func toolInputIsInvalid(_ i: Int) -> Bool {
        i < toolInputs.count && !toolInputs[i].trimmingCharacters(in: .whitespaces).isEmpty && toolInputValue(i) == nil
    }

    /// Typed expression for a locked length field (kept as text so parameters like "breite" stay linked).
    func lockedInputText(_ i: Int) -> String? {
        guard toolInputValue(i) != nil, toolInputSpecs[i].kind == .length else { return nil }
        return toolInputs[i].trimmingCharacters(in: .whitespaces)
    }

    var hasLockedInput: Bool { toolInputSpecs.indices.contains { toolInputValue($0) != nil } }

    /// Applies typed values to the cursor position.
    func effectiveToolEnd(_ cursor: Vec2) -> Vec2 {
        guard let p0 = toolPoints.first?.position else { return cursor }
        let d = cursor - p0
        func sign(_ v: Double) -> Double { v < 0 ? -1 : 1 }
        switch sketchTool {
        case .line:
            var dir = simd_length(d) > 1e-12 ? simd_normalize(d) : Vec2(1, 0)
            if let a = toolInputValue(1) { dir = Vec2(cos(a * .pi / 180), sin(a * .pi / 180)) }
            let len = toolInputValue(0) ?? (toolInputValue(1) != nil ? max(simd_dot(d, dir), 0) : simd_length(d))
            return p0 + dir * len
        case .rectangle:
            let w = toolInputValue(0) ?? abs(d.x), h = toolInputValue(1) ?? abs(d.y)
            return p0 + Vec2(sign(d.x) * w, sign(d.y) * h)
        case .centerRectangle:
            let w = toolInputValue(0).map { $0 / 2 } ?? abs(d.x), h = toolInputValue(1).map { $0 / 2 } ?? abs(d.y)
            return p0 + Vec2(sign(d.x) * w, sign(d.y) * h)
        case .circle:
            guard let dia = toolInputValue(0) else { return cursor }
            let dir = simd_length(d) > 1e-12 ? simd_normalize(d) : Vec2(1, 0)
            return p0 + dir * dia / 2
        default:
            return cursor
        }
    }

    /// Typed values win over snapping: a locked end point never snaps to other geometry.
    func lockedSnap(_ s: SnapTarget) -> SnapTarget {
        hasLockedInput ? SnapTarget(position: effectiveToolEnd(s.position)) : s
    }

    /// Current values shown as placeholders (what the mouse would create).
    var toolLiveValues: [Double] {
        guard let p0 = toolPoints.first?.position, let c = cursor?.position else { return [] }
        let e = effectiveToolEnd(c)
        let d = e - p0
        switch sketchTool {
        case .line:
            var a = atan2(d.y, d.x) * 180 / .pi
            if a < 0 { a += 360 }
            return [simd_length(d), a]
        case .rectangle: return [abs(d.x), abs(d.y)]
        case .centerRectangle: return [2 * abs(d.x), 2 * abs(d.y)]
        case .circle: return [2 * simd_length(d)]
        default: return []
        }
    }

    /// Sketch-space distance that puts a new dimension label about 28 pt away from its geometry.
    var dimensionOffsetDistance: Double { 28 * Double(camera.worldPerPoint) }

    // MARK: Focus & commit

    func resetToolInputs() {
        toolInputs = ["", ""]
        if toolInputSpecs.isEmpty {
            if toolInputFocus != nil {
                toolInputFocus = nil
                focusViewport()
            }
        } else {
            toolInputFocus = 0
        }
    }

    func focusNextToolInput(backwards: Bool = false) {
        let n = toolInputSpecs.count
        guard n > 0 else { return }
        let i = toolInputFocus ?? 0
        toolInputFocus = (i + (backwards ? n - 1 : 1)) % n
    }

    /// ↩ in a field: create the geometry with typed values; empty fields use the mouse.
    func commitToolInputs() {
        guard let p0 = toolPoints.first?.position else { return }
        if (0..<toolInputSpecs.count).contains(where: toolInputIsInvalid) {
            showToast("Ungültiger Wert")
            return
        }
        let cursorPos = cursor?.position ?? p0 + Vec2(1, 1)
        let end = SnapTarget(position: effectiveToolEnd(cursorPos))
        let before = toolPoints
        switch sketchTool {
        case .line: createLine(to: end)
        case .rectangle, .centerRectangle: createRectangle(to: end)
        case .circle: createCircle(to: end)
        default: return
        }
        if toolPoints != before { resetToolInputs() }
        requestRedraw()
    }

    func cancelToolInputs() {
        cancelSketchTool()
        toolInputFocus = nil
        focusViewport()
    }
}
