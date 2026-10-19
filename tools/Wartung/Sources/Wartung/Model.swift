import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// State of the menu bar app: what is open on GitHub, and the one script that may be running.
@Observable @MainActor
final class Wartung {
    static let shared = Wartung()

    private(set) var status: Status?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var updated: Date?
    private(set) var job: Job?

    var repo: URL {
        didSet { UserDefaults.standard.set(repo.path, forKey: "repo"); Task { await refresh() } }
    }

    /// New bug reports: open, not yet worked on.
    var newBugs: [Status.Bug] { status?.bugs.filter { ["bereit", "wartet auf Freigabe"].contains($0.state) } ?? [] }
    var readyBugs: [Status.Bug] { status?.bugs.filter(\.ready) ?? [] }
    var busy: Bool { job?.running == true }

    private var timer: Timer?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "repo")
        let built = Bundle.main.object(forInfoDictionaryKey: "WartungRepo") as? String
        repo = URL(fileURLWithPath: saved ?? built ?? FileManager.default.homeDirectoryForCurrentUser.path)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
            Task { @MainActor in await Wartung.shared.refresh() }
        }
        Task { await refresh() }
    }

    var scriptsFound: Bool {
        FileManager.default.isExecutableFile(atPath: repo.appendingPathComponent("scripts/release.py").path)
    }

    // MARK: Status

    func refresh(ifOlderThan seconds: TimeInterval) async {
        if let updated, Date().timeIntervalSince(updated) < seconds { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        guard scriptsFound else { error = "Im gewählten Ordner fehlt scripts/release.py – Projektordner wählen."; return }
        loading = true
        defer { loading = false }
        do {
            let data = try await Shell.output("scripts/release.py", ["--status-json"], in: repo)
            let s = try JSONDecoder().decode(Status.self, from: data)
            announce(s)
            status = s
            error = nil
            updated = Date()
        } catch {
            self.error = (error as? ShellError)?.message ?? error.localizedDescription
        }
    }

    /// Notification for bug reports this Mac has not seen yet (the very first load only remembers them).
    private func announce(_ s: Status) {
        let key = "seenBugs"
        let seen = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
        let firstRun = UserDefaults.standard.object(forKey: key) == nil
        for bug in s.bugs where !seen.contains(bug.number) && !firstRun {
            notify("Neuer Fehlerbericht #\(bug.number)", "\(bug.title) – von @\(bug.author)")
        }
        UserDefaults.standard.set(Array(seen.union(s.bugs.map(\.number))), forKey: key)
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Actions (all through the scripts)

    func run(_ title: String, _ script: String, _ args: [String], done: String? = nil) {
        guard !busy else { return }
        let j = Job(title: title)
        job = j
        j.start(script, args, in: repo) { [weak self] job in
            self?.notify(job.succeeded ? "✓ \(done ?? title)" : "✗ \(title) fehlgeschlagen", job.lastLine)
            Task { await self?.refresh() }
        }
    }

    func fixAll() { run("Fehler beheben (\(readyBugs.count))", "scripts/bugfix.py", ["--max", "\(readyBugs.count)"], done: "Fehlerbehebung fertig") }
    func fix(_ b: Status.Bug) { run("#\(b.number) beheben", "scripts/bugfix.py", ["--issue", "\(b.number)"], done: "#\(b.number) bearbeitet") }

    func approve(_ b: Status.Bug) {
        guard Confirm.ask("#\(b.number) für die automatische Behebung freigeben?",
                          "„\(b.title)“ von @\(b.author)\n\nClaude bearbeitet den Bericht dann beim nächsten Lauf auf diesem Mac. "
                          + "Nur freigeben, wenn du dem Melder vertraust – Tests führen den geänderten Code hier aus.",
                          button: "Freigeben") else { return }
        run("#\(b.number) freigeben", "scripts/bugfix.py", ["--approve", "\(b.number)"])
    }

    func tryOut(_ pr: Status.PullRequest) {
        run("#\(pr.number) ausprobieren", "scripts/release.py", ["--try", "\(pr.number)"], done: "Test-App #\(pr.number) ist offen")
    }

    func merge(_ pr: Status.PullRequest) {
        var text = "„\(pr.title)“\n\(pr.files) Dateien, +\(pr.additions) −\(pr.deletions). Gemergt wird genau der angezeigte Stand."
        if !pr.warnings.isEmpty { text += "\n\nHinweise:\n" + pr.warnings.map { "• \($0)" }.joined(separator: "\n") }
        guard Confirm.ask("#\(pr.number) nach main mergen?", text,
                          button: pr.warnings.isEmpty ? "Mergen" : "Trotz Hinweisen mergen", destructive: !pr.warnings.isEmpty) else { return }
        var args = ["--merge", "\(pr.number)", "--head", pr.head]
        if !pr.warnings.isEmpty { args.append("--accept-warnings") }
        run("#\(pr.number) mergen", "scripts/release.py", args, done: "#\(pr.number) gemergt")
    }

    func discard(_ pr: Status.PullRequest) {
        guard let reason = Confirm.askText("#\(pr.number) verwerfen?",
                                           "Der Pull Request wird geschlossen, das Issue bekommt „braucht-mensch“. Begründung (öffentlich):",
                                           default: "Die automatische Korrektur passt so nicht.", button: "Verwerfen") else { return }
        run("#\(pr.number) verwerfen", "scripts/release.py", ["--close", "\(pr.number)", "--reason", reason])
    }

    func publish(tag: String, text: String, check: Bool, notifyReporters: Bool) {
        guard let head = status?.release.head else { return }
        var args = ["--publish", tag, "--head", head, "--text", text]
        if check { args.append("--check") }
        if notifyReporters { args.append("--notify") }
        run("\(tag) veröffentlichen", "scripts/release.py", args, done: "\(tag) veröffentlicht und geprüft")
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = repo
        panel.message = "Den 6axis-Projektordner wählen (mit scripts/release.py)"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { repo = url }
    }

    // MARK: Login item

    var startsAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { self.error = "Anmeldeobjekt: \(error.localizedDescription)" }
        }
    }
}

/// Modal questions; reliable from a menu bar panel.
enum Confirm {
    @MainActor static func ask(_ title: String, _ text: String, button: String, destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: button).hasDestructiveAction = destructive
        a.addButton(withTitle: "Abbrechen")
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }

    @MainActor static func askText(_ title: String, _ text: String, default value: String, button: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: "Abbrechen")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let reason = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? value : reason
    }
}
