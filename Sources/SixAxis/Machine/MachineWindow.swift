import SwiftUI
import SixAxisCore

/// The machine window: connect, position, jog, set up, run jobs – with an always visible STOP.
struct MachineWindow: View {
    @Bindable var session = MachineSession.shared
    let editor: Editor
    @State private var startChecked = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    dro
                    jogPad
                    setupButtons
                }
                .frame(width: 330)
                Divider()
                job.frame(maxWidth: .infinity)
            }
            .padding(16)
            .disabled(!session.connected)
            if let m = session.snapshot.message {
                Divider()
                Label(m, systemImage: session.snapshot.alarm != nil ? "exclamationmark.octagon.fill" : "info.circle")
                    .foregroundStyle(session.snapshot.alarm != nil ? .red : .secondary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true; session.refreshPorts() }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .space, .escape]) { press in
            handle(press.key)
        }
        .alert("Sicherheit", isPresented: $session.showSafetyNotice) {
            Button("Verstanden") { UserDefaults.standard.set(true, forKey: "machine.safetyNoticeShown") }
        } message: {
            Text("6axis ersetzt keinen Not-Aus. Die Fräse braucht einen echten Not-Aus-Schalter, der Motoren und Spindel stromlos macht. Erste Programme immer „in der Luft“ testen (Z hoch genullt).")
        }
        .sheet(isPresented: $session.confirmStart) { startSheet }
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .space, .escape:
            if session.running || session.state == .run || session.state == .jog { session.controller.stop(); return .handled }
            return key == .space ? .handled : .ignored
        case .upArrow: session.jog(0, 1, 0)
        case .downArrow: session.jog(0, -1, 0)
        case .leftArrow: session.jog(-1, 0, 0)
        case .rightArrow: session.jog(1, 0, 0)
        case .pageUp: session.jog(0, 0, 1)
        case .pageDown: session.jog(0, 0, -1)
        default: return .ignored
        }
        return .handled
    }

    // MARK: Connection

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Picker("Anschluss", selection: $session.selectedPort) {
                Text("Simulator").tag("")
                ForEach(session.ports, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
            }
            .frame(width: 260)
            .disabled(session.connected)
            Button { session.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                .help("Anschlüsse neu suchen").disabled(session.connected)
            if session.connected {
                Button("Trennen") { session.disconnect() }
            } else {
                Button("Verbinden") { session.connect() }.buttonStyle(.borderedProminent)
            }
            Text(session.snapshot.firmware).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            statusBadge
            Button {
                session.controller.stop()
            } label: {
                Label("STOPP", systemImage: "stop.fill").font(.system(size: 14, weight: .bold)).padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!session.connected)
            .help("Sofort anhalten (Leertaste)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var statusBadge: some View {
        let s = session.state
        let color: Color = !session.connected ? .gray : (s == .alarm ? .red : (s == .run || s == .jog || s == .home ? .green : (s == .hold ? .orange : .blue)))
        return Text(session.connected ? s.displayName : String(localized: "Nicht verbunden"))
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: Position

    private var dro: some View {
        let w = session.snapshot.status.work, m = session.snapshot.status.machine
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(["X", "Y", "Z"].enumerated()), id: \.offset) { i, axis in
                HStack(spacing: 10) {
                    Text(axis).font(.system(size: 20, weight: .bold)).frame(width: 22)
                    Text(String(format: "%9.3f", w[i])).font(.system(size: 26, weight: .medium, design: .monospaced))
                    Text(String(format: "%.3f", m[i])).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .help("Maschinenkoordinate")
                    Spacer()
                    Button("0") { session.controller.zero(x: i == 0, y: i == 1, z: i == 2) }
                        .help("\(axis) an dieser Stelle nullen")
                        .disabled(session.running)
                }
            }
            Button("Alle nullen") { session.controller.zero(x: true, y: true, z: true) }.disabled(session.running)
        }
    }

    // MARK: Jog

    private var jogPad: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow { Color.clear.frame(width: 44, height: 36); jogButton("arrow.up", 0, 1, 0); Color.clear.frame(width: 44, height: 36) }
                    GridRow { jogButton("arrow.left", -1, 0, 0); Image(systemName: "move.3d").foregroundStyle(.tertiary).frame(width: 44); jogButton("arrow.right", 1, 0, 0) }
                    GridRow { Color.clear.frame(width: 44, height: 36); jogButton("arrow.down", 0, -1, 0); Color.clear.frame(width: 44, height: 36) }
                }
                VStack(spacing: 4) {
                    jogButton("arrow.up.to.line", 0, 0, 1)
                    Text("Z").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    jogButton("arrow.down.to.line", 0, 0, -1)
                }
            }
            Picker("Schritt", selection: $session.jogStep) {
                ForEach([0.1, 1, 10, 50], id: \.self) { Text(formatValue($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Pfeiltasten verfahren X/Y, Bild ↑/↓ verfährt Z, Leertaste stoppt. Gamepad: linker Stick X/Y, Schultertasten Z.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(session.running)
    }

    private func jogButton(_ symbol: String, _ x: Double, _ y: Double, _ z: Double) -> some View {
        Button { session.jog(x, y, z) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered)
    }

    private var setupButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { session.controller.home() } label: { Label("Referenzfahrt", systemImage: "house") }
                if session.snapshot.alarm != nil || session.state == .alarm {
                    Button { session.controller.unlock() } label: { Label("Entsperren", systemImage: "lock.open") }
                }
                Button { session.controller.park(x: -10, y: -10) } label: { Label("Parken", systemImage: "parkingsign") }
            }
            HStack(spacing: 4) {
                Button { session.goTo() } label: { Label("Anfahren", systemImage: "scope") }
                    .help("Werkstückposition anfahren – leere Felder bleiben, wie sie sind")
                ForEach([("X", \MachineSession.gotoX), ("Y", \MachineSession.gotoY), ("Z", \MachineSession.gotoZ)], id: \.0) { axis, kp in
                    Text(axis).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("–", text: Binding(get: { session[keyPath: kp] }, set: { session[keyPath: kp] = $0 }))
                        .frame(width: 52).onSubmit { session.goTo() }
                }
            }
            HStack {
                Button { session.controller.probeZ(thickness: session.plateThickness) } label: { Label("Z antasten", systemImage: "arrow.down.to.line.compact") }
                Text("Platte").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("", value: $session.plateThickness, format: .number.precision(.fractionLength(0...2))).frame(width: 56)
                Text("mm").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button { session.controller.spindle(on: true, rpm: 18000) } label: { Label("Spindel an", systemImage: "fanblades") }
                Button { session.controller.spindle(on: false, rpm: 0) } label: { Label("Aus", systemImage: "fanblades.slash") }
            }
        }
        .disabled(session.running)
    }

    // MARK: Job

    private var job: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Programm").font(.system(size: 13, weight: .semibold))
            HStack {
                Button { session.loadFromMilling(editor) } label: { Label("Aus „Fräsen“ übernehmen", systemImage: "gearshape.2") }
                Button { session.openFile() } label: { Label("G-Code öffnen …", systemImage: "doc") }
            }
            .disabled(session.running)
            if session.program != nil {
                Text(session.programName).font(.system(size: 12, weight: .medium))
                ProgressView(value: Double(session.snapshot.jobDone), total: Double(max(session.snapshot.jobLines, 1)))
                HStack {
                    Text("Zeile \(session.snapshot.jobDone) von \(session.snapshot.jobLines)").font(.system(size: 11, design: .monospaced))
                    Spacer()
                    if let r = session.remaining, session.running {
                        Text("noch ca. \(Int((r / 60).rounded(.up))) min").font(.system(size: 11))
                    }
                }
                .foregroundStyle(.secondary)
                HStack {
                    if session.running {
                        if session.state == .hold {
                            Button { session.controller.resume() } label: { Label("Fortsetzen", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                            Text("Angehalten – z. B. Werkzeugwechsel: neues Werkzeug einsetzen, Z antasten, dann fortsetzen.")
                                .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Button { session.controller.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        }
                    } else {
                        Button { startChecked = false; session.confirmStart = true } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.state != .idle)
                    }
                }
            } else {
                Text("Noch kein Programm geladen.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            Text("Korrektur während der Fahrt").font(.system(size: 12, weight: .semibold))
            overrideRow(String(localized: "Vorschub"), value: session.snapshot.status.overrides.x, minus: .feedMinus10, reset: .feed100, plus: .feedPlus10)
            overrideRow(String(localized: "Drehzahl"), value: session.snapshot.status.overrides.z, minus: .spindleMinus10, reset: .spindle100, plus: .spindlePlus10)
            Spacer()
        }
    }

    private func overrideRow(_ title: String, value: Int, minus: GRBL.RealTime, reset: GRBL.RealTime, plus: GRBL.RealTime) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading).font(.system(size: 12))
            Button("−10 %") { session.controller.override(feed: minus) }
            Button("\(value) %") { session.controller.override(feed: reset) }.help("Zurück auf 100 %")
            Button("+10 %") { session.controller.override(feed: plus) }
        }
        .controlSize(.small)
    }

    private var startSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Programm starten?").font(.system(size: 15, weight: .semibold))
            Text(session.programName).font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("Nullpunkt X/Y/Z gesetzt (Anzeige zeigt die Werkstückposition)", systemImage: "scope")
                Label("Richtiges Werkzeug eingesetzt und gespannt", systemImage: "wrench.adjustable")
                Label("Werkstück gespannt, Haltestege/Spannmittel nicht im Weg", systemImage: "square.grid.3x3")
                Label("Not-Aus erreichbar, Absaugung an", systemImage: "exclamationmark.octagon")
            }
            .font(.system(size: 12))
            Toggle("Geprüft – beim ersten Mal „in der Luft“ (Z hoch genullt) testen", isOn: $startChecked)
                .toggleStyle(.checkbox).font(.system(size: 12))
            HStack {
                Spacer()
                Button("Abbrechen") { session.confirmStart = false }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    session.confirmStart = false
                    session.start()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!startChecked)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
