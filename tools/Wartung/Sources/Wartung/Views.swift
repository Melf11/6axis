import AppKit
import SwiftUI

@main
struct WartungApp: App {
    @State private var model = Wartung.shared

    init() {
        // `Wartung --selftest`: load the status like the panel does, print a summary, quit.
        // `Wartung --selftest-job [cancel]`: one script run through Job (live log, exit code, optional cancel).
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-job") {
            let cancel = CommandLine.arguments.dropFirst(i + 1).first == "cancel"
            Task { @MainActor in
                let j = Job(title: "Test")
                j.start("scripts/release.py", ["--verify", "v2.0.3"], in: Wartung.shared.repo) { job in
                    print(job.log)
                    print("exit=\(job.exitCode)")
                    exit(0)
                }
                if cancel { try? await Task.sleep(for: .seconds(3)); j.cancel() }
            }
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in
                let m = Wartung.shared
                await m.refresh()
                while m.loading || (m.status == nil && m.error == nil) { try? await Task.sleep(for: .milliseconds(200)) }
                if let s = m.status {
                    print("ok repo=\(s.repo) bugs=\(s.bugs.count) prs=\(s.prs.count) last=\(s.release.last) changes=\(s.release.changes.count)")
                    exit(0)
                }
                print("error: \(m.error ?? "?")")
                exit(1)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environment(model)
        } label: {
            // Ladybug with the number of new reports; filled while a script runs.
            let count = model.newBugs.count
            Image(systemName: model.busy ? "ladybug.fill" : "ladybug")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)

        Window("Protokoll", id: "log") { LogView().environment(model) }
            .defaultSize(width: 720, height: 480)
        Window("Veröffentlichen", id: "publish") { PublishView().environment(model) }
            .windowResizability(.contentSize)
    }
}

// MARK: Panel

struct Panel: View {
    @Environment(Wartung.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let job = model.job { JobBar(job: job) { open("log") } }
            if let s = model.status {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        bugs(s)
                        Divider()
                        pulls(s)
                        Divider()
                        release(s)
                    }
                }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            } else if model.loading {
                ProgressView("Lade von GitHub …").frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            Text("6axis Wartung").font(.headline)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            if let updated = model.updated {
                Text(updated, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Aktualisieren")
        }
    }

    // MARK: Sections

    @ViewBuilder private func bugs(_ s: Status) -> some View {
        Section("Fehlerberichte", count: s.bugs.count) {
            if s.bugs.isEmpty { Empty("Keine offenen Fehlerberichte.") }
            ForEach(s.bugs) { b in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Link("#\(b.number) \(b.title)", destination: b.url).lineLimit(2)
                        Text("@\(b.author) · \(b.state)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if b.ready {
                        Button("Beheben") { model.fix(b) }.disabled(model.busy)
                    } else if b.state == "wartet auf Freigabe" {
                        Button("Freigeben …") { model.approve(b) }.disabled(model.busy)
                    }
                }
            }
            if model.readyBugs.count > 1 {
                Button("Alle \(model.readyBugs.count) beheben") { model.fixAll() }.disabled(model.busy)
            }
        }
    }

    @ViewBuilder private func pulls(_ s: Status) -> some View {
        Section("Pull Requests", count: s.prs.count) {
            if s.prs.isEmpty { Empty("Keine offenen Pull Requests.") }
            ForEach(s.prs) { pr in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        CI(state: pr.ci)
                        Link("#\(pr.number) \(pr.title)", destination: pr.url).lineLimit(2)
                    }
                    Text("@\(pr.author) · behebt \(pr.issues.map { "#\($0)" }.joined(separator: ", ").ifEmpty("–")) · "
                         + "\(pr.files) Dateien, +\(pr.additions) −\(pr.deletions)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(pr.blockers, id: \.self) { Label($0, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red) }
                    ForEach(pr.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("Änderungen") { NSWorkspace.shared.open(pr.url.appendingPathComponent("files")) }
                        Button("Ausprobieren") { model.tryOut(pr) }.disabled(model.busy)
                            .help("App mit genau dieser Korrektur bauen und öffnen")
                        Spacer()
                        Button("Verwerfen …") { model.discard(pr) }.disabled(model.busy)
                        Button("Mergen …") { model.merge(pr) }.disabled(model.busy || !pr.blockers.isEmpty)
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func release(_ s: Status) -> some View {
        Section("Release", count: nil) {
            if s.release.changes.isEmpty {
                Empty("Alles veröffentlicht (\(s.release.last)).")
            } else {
                Text("Seit \(s.release.last) noch nicht veröffentlicht:").font(.caption).foregroundStyle(.secondary)
                ForEach(s.release.changes.prefix(6), id: \.self) { Text("• \($0)").font(.caption).lineLimit(1) }
                if s.release.changes.count > 6 { Text("… und \(s.release.changes.count - 6) weitere").font(.caption).foregroundStyle(.secondary) }
                Button("Veröffentlichen …") { open("publish") }.disabled(model.busy)
            }
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Projektordner wählen …") { model.chooseRepo() }
                Text(model.repo.path)
                Divider()
                Toggle("Bei Anmeldung starten", isOn: Binding(get: { model.startsAtLogin }, set: { model.startsAtLogin = $0 }))
                Button("Protokoll zeigen") { open("log") }.disabled(model.job == nil)
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button("Beenden") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}

private struct Section<Content: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var content: Content

    init(_ title: String, count: Int?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                if let count, count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

private struct Empty: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

private struct CI: View {
    var state: String
    var body: some View {
        switch state {
        case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("CI grün")
        case "fehlgeschlagen": Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("CI rot")
        case "läuft": Image(systemName: "clock").foregroundStyle(.orange).help("CI läuft")
        default: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("keine CI")
        }
    }
}

private struct JobBar: View {
    var job: Job
    var showLog: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if job.running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: job.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(job.succeeded ? .green : .red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.callout)
                Text(job.lastLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Protokoll", action: showLog).controlSize(.small)
            if job.running { Button("Abbrechen") { job.cancel() }.controlSize(.small) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Windows

struct LogView: View {
    @Environment(Wartung.self) private var model

    var body: some View {
        if let job = model.job {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(job.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: job.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .navigationTitle("Protokoll – \(job.title)")
        } else {
            Text("Noch nichts gelaufen.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PublishView: View {
    @Environment(Wartung.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var kind = "patch"
    @State private var text = "Fehlerbehebungen"
    @State private var check = true
    @State private var notifyReporters = true

    var body: some View {
        if let r = model.status?.release, !r.changes.isEmpty {
            Form {
                Picker("Version", selection: $kind) {
                    Text("\(r.next["patch"] ?? "") Fehlerbehebung").tag("patch")
                    Text("\(r.next["minor"] ?? "") neue Funktionen").tag("minor")
                    Text("\(r.next["major"] ?? "") große Änderung").tag("major")
                }
                .pickerStyle(.radioGroup)
                TextField("Kurzbeschreibung", text: $text, prompt: Text("deutsch, steht im Tag"))
                Toggle("Vorher genau diesen Stand auf dem Mac prüfen (≈ 10 Minuten)", isOn: $check)
                Toggle("Melder benachrichtigen („Behoben in …“)", isOn: $notifyReporters)
                LabeledContent("Änderungen seit \(r.last)") {
                    VStack(alignment: .leading) {
                        ForEach(r.changes.prefix(12), id: \.self) { Text("• \($0)").lineLimit(1) }
                    }
                    .font(.caption)
                }
                HStack {
                    Spacer()
                    Button("Abbrechen") { dismissWindow(id: "publish") }
                    Button("\(r.next[kind] ?? "") veröffentlichen …") {
                        let tag = r.next[kind] ?? ""
                        guard Confirm.ask("\(tag) jetzt veröffentlichen?",
                                          "Danach bekommen alle das Update angeboten. GitHub baut und signiert (15–25 Minuten), "
                                          + "anschließend werden die Dateien geprüft. Du bekommst eine Mitteilung.",
                                          button: "Veröffentlichen") else { return }
                        model.publish(tag: tag, text: text.isEmpty ? "Fehlerbehebungen" : text, check: check, notifyReporters: notifyReporters)
                        dismissWindow(id: "publish")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                }
            }
            .formStyle(.grouped)
            .frame(width: 480)
        } else {
            Text("Nichts zu veröffentlichen.").foregroundStyle(.secondary).padding(40)
        }
    }
}

private extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
