import SwiftUI
import SixAxisCore

struct MainView: View {
    @Bindable var editor: Editor

    var body: some View {
        ZStack {
            ViewportView(editor: editor)
            ViewportOverlay(editor: editor)

            // Chrome
            VStack(spacing: 0) {
                TopBar(editor: editor)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        if editor.browserVisible {
                            BrowserPanel(editor: editor)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        } else {
                            IconButton(symbol: "sidebar.left", help: "Browser einblenden") { editor.browserVisible = true }
                                .floatingPanel(radius: 8, padding: 2)
                        }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 12) {
                        ViewCube(editor: editor)
                        CommandPanel(editor: editor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Spacer(minLength: 0)
                BottomBar(editor: editor)
            }
            .animation(.snappy(duration: 0.22), value: editor.command?.kind)
            .animation(.snappy(duration: 0.22), value: editor.browserVisible)

            if editor.doc.features.isEmpty && editor.sketchId == nil && editor.command == nil {
                WelcomeCard(editor: editor)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let toast = editor.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .floatingPanel(radius: 18)
                        .padding(.bottom, 96)
                        .onTapGesture { editor.toast = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let p = editor.markingMenu {
                MarkingMenu(editor: editor, center: p)
            }

            if editor.showCommandPalette {
                Color.black.opacity(0.08)
                    .onTapGesture { editor.showCommandPalette = false }
                VStack {
                    CommandPalette(editor: editor).padding(.top, 120)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.2), value: editor.toast)
        .animation(.snappy(duration: 0.25), value: editor.doc.features.isEmpty)
        .animation(.snappy(duration: 0.15), value: editor.showCommandPalette)
        .animation(.snappy(duration: 0.15), value: editor.markingMenu)
        .sheet(isPresented: $editor.showParameters) { ParametersSheet(editor: editor) }
    }
}

/// Title row (under the traffic lights) and the ribbon.
private struct TopBar: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 70, height: 1)   // traffic lights
                LogoImage(size: 20)
                    .help("Über 6axis")
                    .onTapGesture { Branding.showAboutPanel() }
                Text(editor.fileURL?.deletingPathExtension().lastPathComponent ?? "Unbenannt")
                    .font(.system(size: 13, weight: .semibold))
                if editor.isDirty {
                    Circle().fill(.secondary).frame(width: 6, height: 6).help("Ungesicherte Änderungen")
                }
                Spacer()
                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.uturn.backward", help: "Widerrufen (⌘Z)") { editor.undo() }
                        .disabled(!editor.canUndo && editor.command == nil)
                    IconButton(symbol: "arrow.uturn.forward", help: "Wiederholen (⇧⌘Z)") { editor.redo() }
                        .disabled(!editor.canRedo)
                    IconButton(symbol: "square.and.arrow.down.on.square", help: "Sichern (⌘S)") { editor.save() }
                    IconButton(symbol: "magnifyingglass", help: "Befehlssuche (S)") { editor.showCommandPalette = true }
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Einstellungen (⌘,)")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .padding(.top, 6)

            Ribbon(editor: editor)
        }
    }
}

/// Status prompt, timeline and physical properties.
private struct BottomBar: View {
    @Bindable var editor: Editor

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if editor.sketchId != nil, let s = editor.lastSolve {
                    HStack(spacing: 6) {
                        Image(systemName: s.isFullyConstrained ? "lock.fill" : (s.converged ? "lock.open" : "exclamationmark.triangle.fill"))
                        Text(s.isFullyConstrained ? "Vollständig bestimmt" :
                                (s.converged ? "\(s.degreesOfFreedom) Freiheitsgrad\(s.degreesOfFreedom == 1 ? "" : "e")" : "Widersprüchlich"))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(s.isFullyConstrained ? Color.green : (s.converged ? Color.secondary : Color.red))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .floatingPanel(radius: 12)
                }
                Text(prompt)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .floatingPanel(radius: 12)
            }
            .frame(maxWidth: 440, alignment: .leading)

            Spacer(minLength: 0)
            TimelineBar(editor: editor)
            Spacer(minLength: 0)

            physicalInfo
                .frame(maxWidth: 320, alignment: .trailing)
        }
        .padding(12)
    }

    @ViewBuilder
    private var physicalInfo: some View {
        if let p = editor.physicalSummary {
            let cm3 = p.volume / 1000
            let settings = AppSettings.shared
            let material = settings.material == .custom ? "" : " " + settings.material.title
            VStack(alignment: .trailing, spacing: 2) {
                Text(p.title).font(.system(size: 11, weight: .semibold))
                Text(String(format: "%.2f cm³ · ≈ %.1f g", cm3, cm3 * settings.density) + material)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .floatingPanel(radius: 10)
            .help(String(format: "Oberfläche: %.1f cm²", p.area / 100))
        }
    }

    private var prompt: String {
        if let cmd = editor.command {
            switch cmd.kind {
            case .sketchPlane: return "Ebene oder ebene Fläche für die Skizze wählen"
            case .extrude: return "Profile oder Flächen wählen · Pfeil ziehen · ↩ bestätigt"
            case .revolve: return cmd.activeInput == 1 ? "Drehachse wählen (Linie, Kante oder Achse)" : "Profile wählen"
            case .fillet, .chamfer: return "Kanten wählen · ↩ bestätigt"
            case .shell: return "Flächen wählen, die offen sein sollen"
            }
        }
        if editor.sketchId != nil {
            let n = editor.toolPoints.count
            switch editor.sketchTool {
            case .select: return "Ziehen zum Verschieben · L Linie · R Rechteck · C Kreis · D Bemaßung"
            case .line: return n == 0 ? "Startpunkt klicken · ⌘ = frei setzen" : "Nächsten Punkt klicken · Tab für Maße · Esc beendet"
            case .rectangle: return n == 0 ? "Erste Ecke klicken · ⌘ = frei setzen" : "Gegenüberliegende Ecke klicken oder Maße eintippen"
            case .centerRectangle: return n == 0 ? "Mittelpunkt klicken" : "Ecke klicken"
            case .circle: return n == 0 ? "Mittelpunkt klicken · ⌘ = frei setzen" : "Radius klicken oder Durchmesser eintippen"
            case .arc: return n == 0 ? "Startpunkt klicken" : (n == 1 ? "Endpunkt klicken" : "Punkt auf dem Bogen klicken")
            case .dimension:
                if editor.dimensionSecond != nil { return "Bemaßung platzieren" }
                return editor.dimensionFirst == nil ? "Linie, Kreis oder Punkt wählen" : "Zweites Objekt wählen oder Bemaßung platzieren"
            case let .constraint(ct): return "\(ct.name): Objekte wählen"
            }
        }
        return editor.state.bodyOrder.isEmpty
            ? "Starte mit „Skizze“ (oder drücke L, R, C) · S öffnet die Befehlssuche"
            : "Wähle Geometrie · Rechtsklick für Schnellmenü · S für Befehlssuche"
    }
}
