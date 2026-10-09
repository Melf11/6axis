import SwiftUI
import SixAxisCore

/// Small pill in the title bar when a newer version exists.
struct UpdateBadge: View {
    @Bindable var updater = Updater.shared

    var body: some View {
        if let release = updater.release {
            Button { updater.showSheet = true } label: {
                Label(String(localized: "Update \(release.version.description)"), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Eine neue Version von 6axis ist verfügbar"))
        }
    }
}

/// Update dialog: release notes, install with progress, skip/later.
struct UpdateSheet: View {
    @Bindable var updater = Updater.shared
    let editor: Editor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LogoImage(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(String(localized: "Installiert: \(updater.current?.description ?? "–")"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            content
            buttons
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        switch updater.phase {
        case .checking: return String(localized: "Suche nach Updates …")
        case .upToDate: return String(localized: "6axis ist auf dem neuesten Stand")
        case .failed: return String(localized: "Update")
        default:
            if let r = updater.release { return String(localized: "6axis \(r.version.description) ist verfügbar") }
            return String(localized: "Update")
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .checking:
            ProgressView().controlSize(.small)
        case let .downloading(p):
            ProgressView(value: p) { Text("Lade Update …") }
        case .installing:
            ProgressView { Text("Prüfe Signatur und installiere …") }
        case let .failed(message):
            Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            notes
        default:
            notes
            if updater.release != nil && !updater.canInstallAutomatically {
                Text("Dieses Release ist nicht signiert und kann nicht automatisch installiert werden. Lade es bitte von der Release-Seite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if let r = updater.release, !r.notes.isEmpty {
            ScrollView {
                Text(markdown(r.notes))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 220)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            if updater.release != nil, !updater.isBusy {
                Button("Diese Version überspringen") { updater.skipThisVersion(); dismiss() }
            }
            Spacer()
            if updater.isBusy {
                EmptyView()
            } else if updater.release != nil {
                Button("Später") { dismiss() }.keyboardShortcut(.cancelAction)
                if updater.canInstallAutomatically {
                    Button("Installieren und neu starten") { Task { await updater.install(editor: editor) } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Release-Seite öffnen") { updater.openReleasePage(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// GitHub release notes are Markdown; headings become bold lines, lists keep their bullets.
    private func markdown(_ full: String) -> AttributedString {
        // In the app only the changes matter (the release page also explains download and first start).
        var text = full
        if let start = full.range(of: "## Änderungen") ?? full.range(of: "## Changes") {
            let rest = full[start.lowerBound...]
            let next = rest.dropFirst(3).range(of: "\n## ")
            text = String(next.map { rest[..<$0.lowerBound] } ?? rest)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            if l.hasPrefix("#") { l = "**" + l.drop(while: { $0 == "#" || $0 == " " }) + "**" }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            return l
        }
        let joined = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(joined)
    }
}

/// Settings tab "Updates".
struct UpdateSettings: View {
    @Bindable var s = AppSettings.shared
    @Bindable var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Toggle("Automatisch nach Updates suchen", isOn: $s.checkForUpdates)
                LabeledContent("Installierte Version", value: updater.current?.description ?? "–")
                LabeledContent("Zuletzt gesucht") {
                    Text(s.lastUpdateCheck == .distantPast ? String(localized: "noch nie") : s.lastUpdateCheck.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Jetzt nach Updates suchen") { Task { await updater.check(userInitiated: true) } }
            } footer: {
                Text("6axis fragt höchstens einmal am Tag bei GitHub nach einer neuen Version. Dabei werden keine Daten über dich oder deine Konstruktionen übertragen. Updates werden nur installiert, wenn ihre digitale Signatur stimmt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
