import AppKit
import SwiftUI
import SixAxisCore

/// On-canvas value box shown while drawing. Tab/⇧Tab cycle fields, ↩ creates, Esc cancels.
struct ToolInputBox: View {
    @Bindable var editor: Editor
    let index: Int
    let spec: ToolInputSpec
    let live: Double?

    var body: some View {
        let focused = editor.toolInputFocus == index
        let locked = editor.toolInputValue(index) != nil
        let invalid = editor.toolInputIsInvalid(index)
        HStack(spacing: 4) {
            Text(spec.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ToolInputField(
                text: Binding(
                    get: { index < editor.toolInputs.count ? editor.toolInputs[index] : "" },
                    set: { v in
                        while editor.toolInputs.count <= index { editor.toolInputs.append("") }
                        editor.toolInputs[index] = v
                        editor.requestRedraw()
                    }),
                placeholder: live.map { formatValue($0, kind: spec.kind) } ?? "",
                focused: focused,
                index: index,
                onFocus: { editor.toolInputFocus = index },
                onTab: { editor.focusNextToolInput(backwards: $0); return editor.toolInputFocus },
                onEnter: { editor.commitToolInputs() },
                onEscape: { editor.cancelToolInputs() })
                .frame(width: 74, height: 18)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(invalid ? Color.red : (focused ? Color.accentColor : Color.primary.opacity(0.2)), lineWidth: focused || invalid ? 1.5 : 0.8))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .fixedSize()
    }
}

/// NSTextField wrapper so Tab, ↩ and Esc can be intercepted reliably.
struct ToolInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focused: Bool
    let index: Int
    let onFocus: () -> Void
    /// Moves the editor's focus and returns the new field index.
    let onTab: (_ backwards: Bool) -> Int?
    let onEnter: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = FocusReportingTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        f.alignment = .right
        f.lineBreakMode = .byClipping
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.onBecomeFirstResponder = { context.coordinator.parent.onFocus() }
        Self.registry[index] = WeakField(field: f)
        return f
    }

    /// Live fields by index, so Tab can move focus synchronously (no keystroke lands in the old field).
    nonisolated(unsafe) static var registry: [Int: WeakField] = [:]

    struct WeakField { weak var field: NSTextField? }

    static func focus(_ index: Int) {
        guard let f = registry[index]?.field, let w = f.window else { return }
        w.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        Self.registry[index] = WeakField(field: f)
        if f.stringValue != text { f.stringValue = text }
        f.placeholderString = placeholder
        let isEditing = f.currentEditor() != nil && f.window?.firstResponder === f.currentEditor()
        if focused && !isEditing {
            // Defer: the field may not be in a window yet during the first update.
            DispatchQueue.main.async {
                guard let w = f.window, f.currentEditor() == nil || w.firstResponder !== f.currentEditor() else { return }
                w.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ToolInputField
        init(_ p: ToolInputField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertTab(_:)):
                if let i = parent.onTab(false) { ToolInputField.focus(i) }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if let i = parent.onTab(true) { ToolInputField.focus(i) }
                return true
            case #selector(NSResponder.insertNewline(_:)): parent.onEnter(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            default: return false
            }
        }
    }
}

/// Reports when the user clicks into the field so the editor's focus index follows.
final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }
}
