import SwiftUI
import SixAxisCore

/// Parametric history at the bottom, with Fusion-style playback controls and rollback marker.
struct TimelineBar: View {
    @Bindable var editor: Editor
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                IconButton(symbol: "backward.end.fill", help: "Zum Anfang", size: 24) { editor.moveMarker(to: 0) }
                IconButton(symbol: "backward.frame.fill", help: "Schritt zurück", size: 24) { editor.moveMarker(to: editor.doc.activeCount - 1) }
                IconButton(symbol: "forward.frame.fill", help: "Schritt vor", size: 24) { editor.moveMarker(to: editor.doc.activeCount + 1) }
                IconButton(symbol: "forward.end.fill", help: "Zum Ende", size: 24) { editor.moveMarker(to: editor.doc.features.count) }
            }
            .disabled(editor.command != nil || editor.sketchId != nil)

            Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 26)

            if editor.doc.features.isEmpty {
                Text("Zeitleiste – hier erscheinen deine Konstruktionsschritte")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(Array(editor.doc.features.enumerated()), id: \.element.id) { index, f in
                                chip(f, index: index)
                                    .id(f.id)
                                if index + 1 == editor.doc.activeCount && editor.doc.activeCount < editor.doc.features.count {
                                    marker
                                }
                            }
                            if editor.doc.activeCount == editor.doc.features.count { marker }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: 560)
                    .onChange(of: editor.doc.features.count) {
                        if let last = editor.doc.features.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .floatingPanel(radius: 12)
    }

    private var marker: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4, height: 30)
            .padding(.horizontal, 2)
            .help("Zeitleistenmarkierung")
    }

    private func chip(_ f: Feature, index: Int) -> some View {
        let active = index < editor.doc.activeCount
        let error = editor.state.errors[f.id]
        let editing = editor.command?.featureId == f.id || editor.sketchId == f.id
        let selected = editor.timelineSelection == f.id
        return ZStack(alignment: .bottomTrailing) {
            Image(systemName: f.kind.symbol)
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(for: f.kind))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(editing ? Color.accentColor.opacity(0.25) : (selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(error != nil ? Color.red : (selected ? Color.accentColor : .clear), lineWidth: 1.5))
            if error != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white, .red)
                    .offset(x: 2, y: 2)
            }
        }
        .opacity(active ? (f.suppressed ? 0.35 : 1) : 0.3)
        .help(error.map { "\(f.name) – Fehler: \($0)" } ?? f.name)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editor.editFeature(f.id) }
        .onTapGesture { editor.timelineSelection = selected ? nil : f.id }
        .contextMenu {
            Text(f.name)
            Button("Bearbeiten") { editor.editFeature(f.id) }
            Button("Zeitleiste bis hierher") { editor.moveMarker(to: index + 1) }
            Button(f.suppressed ? "Aktivieren" : "Unterdrücken") { editor.toggleSuppressed(f.id) }
            Divider()
            Button("Löschen", role: .destructive) { editor.deleteFeature(f.id) }
        }
    }

    private func color(for kind: FeatureKind) -> Color {
        switch kind {
        case .sketch: return .orange
        case .extrude, .revolve: return .accentColor
        case .fillet, .chamfer, .shell: return .purple
        case .importStep: return .teal
        }
    }
}
