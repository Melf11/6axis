import SwiftUI

/// Panel styling. Automated UI checks set SIXAXIS_FAST_SNAPSHOTS: window snapshots render blur and
/// shadows on the CPU (seconds per image), so panels become opaque and shadowless there.
enum PanelStyle {
    static let fast = ProcessInfo.processInfo.environment["SIXAXIS_FAST_SNAPSHOTS"] != nil
    static var fill: AnyShapeStyle {
        fast ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    }
    static var shadowOpacity: Double { fast ? 0 : 0.12 }
}

/// Shared look: translucent floating panels over the full-bleed viewport.
struct FloatingPanel: ViewModifier {
    var radius: CGFloat = 12
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(PanelStyle.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(PanelStyle.shadowOpacity), radius: PanelStyle.fast ? 0 : 14, y: 4)
    }
}

extension View {
    func floatingPanel(radius: CGFloat = 12, padding: CGFloat = 0) -> some View {
        modifier(FloatingPanel(radius: radius, padding: padding))
    }
}

/// Large ribbon button: icon above a short label, like Fusion's toolbar.
struct ToolButton: View {
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var active = false
    var tint: Color? = nil
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? Color.white : (tint ?? .primary))
                    .frame(width: 34, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? Color.accentColor : (hovering ? Color.primary.opacity(0.08) : .clear)))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 3)
            .frame(minWidth: 44)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(shortcut.map { String(localized: "\(title) (\($0))") } ?? title)
    }
}

/// Small square icon button.
struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct GroupLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

struct RibbonDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 44).padding(.horizontal, 4)
    }
}
