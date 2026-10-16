import SwiftUI

/// Settings tab "Fehlerberichte": switch, GitHub sign-in and what the account may do.
struct BugReportSettings: View {
    @Bindable var s = AppSettings.shared
    @Bindable var reports = BugReports.shared

    var body: some View {
        Form {
            Section {
                Toggle("Fehlerberichte in 6axis aktivieren", isOn: $s.bugReportsEnabled)
                if s.bugReportsEnabled { account }
            } footer: {
                Text("Fehler direkt aus 6axis melden und Rückfragen beantworten. Dafür meldest du dich mit deinem GitHub-Konto an; der Inhaber von 6axis legt fest, wer die Funktion nutzen darf und wessen Berichte automatisch bearbeitet werden. Berichte sind öffentlich auf GitHub sichtbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await reports.restore() }
    }

    @ViewBuilder private var account: some View {
        switch reports.account {
        case .signedOut:
            Button("Mit GitHub anmelden …") { reports.signIn() }
                .disabled(!reports.isConfigured)
            if !reports.isConfigured {
                Text("In diesem Build noch nicht eingerichtet.").font(.caption).foregroundStyle(.secondary)
            }
        case let .waitingForCode(code, url):
            LabeledContent("Code") {
                Text(code).font(.system(size: 18, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            }
            Text("Der Code ist kopiert. Füge ihn auf GitHub ein und bestätige – 6axis wartet hier auf die Freigabe.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("GitHub öffnen") { NSWorkspace.shared.open(url) }
                Button("Abbrechen") { reports.cancelSignIn() }
            }
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Prüfe Berechtigung …") }
        case let .signedIn(login, chat, autofix):
            LabeledContent("Angemeldet als", value: "@\(login)")
            Label(chat ? String(localized: "Du darfst Fehler aus 6axis melden") : String(localized: "Für dein Konto ist der Fehlerbericht-Chat nicht freigeschaltet"),
                  systemImage: chat ? "checkmark.circle.fill" : "lock.fill")
                .foregroundStyle(chat ? Color.green : Color.secondary)
            if chat {
                Label(autofix ? String(localized: "Deine Berichte werden automatisch bearbeitet") : String(localized: "Deine Berichte werden nach Freigabe bearbeitet"),
                      systemImage: autofix ? "wand.and.stars" : "hourglass")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Erneut prüfen") { Task { await reports.verify() } }
                Button("Abmelden") { reports.signOut() }
            }
        case let .failed(message):
            Text(message).foregroundStyle(.red)
            Button("Mit GitHub anmelden …") { reports.signIn() }
        }
    }
}

/// The bug-report chat window: my reports on the left, the conversation on the right.
struct BugReportWindow: View {
    @Bindable var reports = BugReports.shared

    var body: some View {
        Group {
            if reports.canUseChat {
                HSplitView {
                    list.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    detail.frame(minWidth: 380)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Der Fehlerbericht-Chat ist für dein Konto nicht freigeschaltet.")
                    Text("Aktiviere ihn unter Einstellungen → Fehlerberichte und melde dich mit GitHub an.")
                        .font(.caption).foregroundStyle(.secondary)
                    SettingsLink { Text("Einstellungen öffnen") }
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .task { await reports.restore(); await reports.refresh() }
        .alert("Fehlerbericht", isPresented: Binding(get: { reports.error != nil }, set: { if !$0 { reports.error = nil } })) {
            Button("OK") { reports.error = nil }
        } message: { Text(reports.error ?? "") }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await reports.open(nil) }
            } label: {
                Label("Neuer Bericht", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            List(selection: Binding(get: { reports.selected }, set: { n in Task { await reports.open(n) } })) {
                Section("Meine Berichte") {
                    ForEach(reports.reports) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).lineLimit(2)
                            Text("#\(r.number) · \(r.status)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Optional(r.number))
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var detail: some View {
        if let r = reports.selectedReport {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.system(size: 14, weight: .semibold))
                        Text("#\(r.number) · \(r.status)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = r.url { Link(String(localized: "Auf GitHub"), destination: url).font(.caption) }
                }
                .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        bubble(author: r.author, text: r.body.replacingOccurrences(of: GitHubClient.reportMarker, with: "").trimmingCharacters(in: .whitespacesAndNewlines))
                        ForEach(reports.conversation) { c in bubble(author: c.author, text: c.body) }
                    }
                    .padding(12)
                }
                Divider()
                HStack(alignment: .bottom) {
                    TextField("Antwort schreiben …", text: $reports.reply, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button("Senden") { Task { await reports.sendReply() } }
                        .disabled(reports.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reports.busy)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(10)
            }
        } else {
            newReport
        }
    }

    private func bubble(author: String, text: String) -> some View {
        let mine = author == reports.login
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            Text(mine ? String(localized: "Du") : "@\(author)").font(.caption2).foregroundStyle(.secondary)
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .textSelection(.enabled)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var newReport: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neuer Fehlerbericht").font(.system(size: 14, weight: .semibold))
            TextField("Kurz: Was ist das Problem?", text: $reports.draftTitle)
                .textFieldStyle(.roundedBorder)
                .onChange(of: reports.draftTitle) { reports.draftChanged() }
            TextEditor(text: $reports.draftText)
                .font(.system(size: 13))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .onChange(of: reports.draftText) { reports.draftChanged() }
            Text("Was hast du gemacht, was hast du erwartet, was ist passiert? Version und Mac werden automatisch angehängt.")
                .font(.caption).foregroundStyle(.secondary)
            if !reports.similar.isEmpty {
                Text("Ähnliche bekannte Fehler – ist es einer davon?").font(.caption.weight(.semibold))
                ForEach(reports.similar) { s in
                    if let url = s.url {
                        Link("#\(s.number) \(s.title) · \(s.status)", destination: url).font(.caption)
                    }
                }
            }
            Spacer()
            HStack {
                Text(Branding.environmentInfo).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if reports.busy { ProgressView().controlSize(.small) }
                Button("Bericht senden") { Task { await reports.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(reports.busy)
            }
        }
        .padding(16)
    }
}
