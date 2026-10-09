import SwiftUI

/// Preferences window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            NavigationSettings()
                .tabItem { Label("Navigation", systemImage: "rotate.3d") }
            DisplaySettings()
                .tabItem { Label("Darstellung", systemImage: "paintbrush") }
            PrintSettings()
                .tabItem { Label("3D-Druck", systemImage: "printer") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
    }
}

struct NavigationSettings: View {
    @Bindable var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $s.ignoreNaturalScrolling) {
                    Text("„Natürliches Scrollen“ im 3D-Fenster ignorieren")
                    Text(AppSettings.systemUsesNaturalScrolling
                         ? String(localized: "Dein Mac nutzt natürliches Scrollen. Aktivieren, damit Zoomen und Drehen der physischen Bewegung folgen – wie bei einer klassischen Maus.")
                         : String(localized: "Dein Mac nutzt klassisches Scrollen; diese Option hat dann keine Wirkung."))
                }
            } header: {
                Text("Scrollrichtung")
            }

            Section("Maus") {
                Toggle("Zoomrichtung des Mausrads umkehren", isOn: $s.invertWheelZoom)
                Toggle("Zum Mauszeiger zoomen", isOn: $s.zoomToCursor)
                LabeledContent("Rechte Taste ziehen") { Text("Drehen").foregroundStyle(.secondary) }
                LabeledContent("Mittlere Taste ziehen") { Text("Verschieben (⇧ = Drehen)").foregroundStyle(.secondary) }
            }

            Section("Trackpad") {
                Picker("Zwei-Finger-Wischen", selection: $s.trackpadSwipe) {
                    ForEach(AppSettings.SwipeAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Mit ⇧ wird jeweils die andere Aktion ausgeführt. In Skizzen ist es umgekehrt, damit die Draufsicht erhalten bleibt.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Drehrichtung umkehren", isOn: $s.invertTrackpadOrbit)
                Toggle("Verschieberichtung umkehren", isOn: $s.invertTrackpadPan)
                LabeledContent("Pinch") { Text("Zoomen").foregroundStyle(.secondary) }
            }

            Section("Geschwindigkeit") {
                speedSlider(String(localized: "Drehen"), value: $s.orbitSpeed)
                speedSlider(String(localized: "Zoomen"), value: $s.zoomSpeed)
            }

            HStack {
                Spacer()
                Button("Standardwerte") { s.resetNavigation() }
            }
        }
        .formStyle(.grouped)
    }

    private func speedSlider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: value, in: 0.3...3)
                Image(systemName: "hare").foregroundStyle(.secondary)
                Text(String(format: "%.1f×", value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

struct DisplaySettings: View {
    @Bindable var s = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Erscheinungsbild", selection: $s.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Körper") {
                Picker("Schattierung", selection: $s.shading) {
                    ForEach(AppSettings.Shading.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Bodenschatten", isOn: $s.groundShadow)
                Toggle("Kanten anzeigen", isOn: $s.showEdges)
                LabeledContent("Kantenstärke") {
                    HStack {
                        Slider(value: $s.edgeWidth, in: 0.5...4)
                        Text(String(format: "%.1f pt", s.edgeWidth))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!s.showEdges)
            }
            Section("Ansichtsfenster") {
                Toggle("Raster anzeigen", isOn: $s.showGrid)
                Toggle("Neue Designs orthografisch anzeigen", isOn: $s.defaultOrthographic)
            }
            Section {
                Toggle("Punkte am Raster ausrichten", isOn: $s.snapToGrid)
            } header: {
                Text("Skizze")
            } footer: {
                Text("Mit gedrückter ⌘-Taste setzt du Punkte jederzeit frei. Vorhandene Punkte und Linien haben immer Vorrang.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PrintSettings: View {
    @Bindable var s = AppSettings.shared

    var body: some View {
        Form {
            Section("Export") {
                Picker("STL-Qualität", selection: $s.stlQuality) {
                    ForEach(AppSettings.STLQuality.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Material", selection: $s.material) {
                    ForEach(AppSettings.Material.allCases) { m in
                        Text(m == .custom ? m.title : "\(m.title) – \(String(format: "%.2f", m.density)) g/cm³").tag(m)
                    }
                }
                if s.material == .custom {
                    LabeledContent("Dichte") {
                        TextField("", value: $s.customDensity, format: .number.precision(.fractionLength(2)))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("g/cm³")
                    }
                }
            } header: {
                Text("Gewichtsschätzung")
            } footer: {
                Text("Wird unten rechts für das Volumen der Auswahl angezeigt (bei 100 % Füllung).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Slicer") {
                Picker("„Im Slicer öffnen“ mit", selection: $s.preferredSlicer) {
                    Text("Automatisch").tag("")
                    ForEach(AppSettings.installedSlicers) { Text($0.name).tag($0.id) }
                }
                if AppSettings.installedSlicers.isEmpty {
                    Text("Kein bekannter Slicer gefunden. STL-Dateien werden mit der Standard-App geöffnet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
