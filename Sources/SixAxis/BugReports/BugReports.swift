import AppKit
import Foundation

/// State of the in-app bug-report chat: GitHub sign-in, permission from the 'reporters' list, the user's
/// reports and the conversation of the selected one. Network access happens only while the feature is
/// switched on and used.
@MainActor @Observable
final class BugReports {
    static let shared = BugReports()

    enum Account: Equatable {
        case signedOut
        case waitingForCode(code: String, url: URL)
        case checking
        case signedIn(login: String, chat: Bool, autofix: Bool)
        case failed(String)
    }

    private(set) var account: Account = .signedOut
    private(set) var reports: [IssueSummary] = []
    /// Selected report (nil = writing a new one).
    var selected: Int?
    private(set) var conversation: [IssueComment] = []
    private(set) var similar: [IssueSummary] = []
    private(set) var busy = false
    var error: String?
    var draftTitle = ""
    var draftText = ""
    var reply = ""

    private var client = GitHubClient(token: GitHubKeychain.load())
    private var signInTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    var isConfigured: Bool { !GitHubClient.clientID.isEmpty }
    /// Switched on and signed in before: "Fehler melden" opens the chat (which then verifies the permission).
    var isReady: Bool { AppSettings.shared.bugReportsEnabled && client.token != nil }
    var login: String? { if case let .signedIn(l, _, _) = account { return l }; return nil }
    /// The chat is available: switched on, signed in and listed in 'reporters'.
    var canUseChat: Bool {
        guard AppSettings.shared.bugReportsEnabled, case .signedIn(_, true, _) = account else { return false }
        return true
    }

    // MARK: Account

    /// At launch (feature on and a stored token): who am I, am I allowed?
    func restore() async {
        guard AppSettings.shared.bugReportsEnabled, client.token != nil, case .signedOut = account else { return }
        await verify()
    }

    func signIn() {
        guard isConfigured else { account = .failed(String(localized: "Fehlerberichte sind in diesem Build noch nicht eingerichtet")); return }
        signInTask?.cancel()
        signInTask = Task {
            do {
                let code = try await GitHubClient.requestDeviceCode()
                account = .waitingForCode(code: code.userCode, url: code.verificationURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                if !Editor.isAutomatedRun { NSWorkspace.shared.open(code.verificationURL) }
                let token = try await GitHubClient.pollToken(code)
                GitHubKeychain.save(token)
                client.token = token
                await verify()
            } catch is CancellationError {
                account = .signedOut
            } catch {
                account = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        account = .signedOut
    }

    func signOut() {
        signInTask?.cancel()
        GitHubKeychain.delete()
        client.token = nil
        account = .signedOut
        reports = []
        conversation = []
        selected = nil
    }

    /// Reads the user and the allowlist from the main branch.
    func verify() async {
        account = .checking
        do {
            let login = try await client.currentUser()
            let config = try await client.automationConfig()
            account = .signedIn(login: login, chat: config.allowsChat(login), autofix: config.autofixes(login))
            if config.allowsChat(login) { await refresh() }
        } catch {
            account = .failed(error.localizedDescription)
        }
    }

    // MARK: Reports

    func refresh() async {
        guard let login else { return }
        do {
            reports = try await client.myIssues(login).filter { $0.body.contains(GitHubClient.reportMarker) || $0.labels.contains("fehler") }
            if let n = selected { await open(n) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ number: Int?) async {
        selected = number
        conversation = []
        guard let number else { return }
        do { conversation = try await client.comments(number) } catch { self.error = error.localizedDescription }
    }

    /// Similar known reports while typing (debounced GitHub search, no AI).
    func draftChanged() {
        searchTask?.cancel()
        let text = draftTitle + " " + draftText
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            similar = (try? await client.searchIssues(text)) ?? []
        }
    }

    /// Creates the report as a GitHub issue (with version and Mac info and the app marker).
    @discardableResult
    func send() async -> Bool {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { error = String(localized: "Bitte Titel und Beschreibung eingeben"); return false }
        busy = true
        defer { busy = false }
        let body = """
        \(text)

        ---
        **Umgebung:** \(Branding.environmentInfo)
        \(GitHubClient.reportMarker)
        """
        do {
            let issue = try await client.createIssue(title: title, body: body)
            draftTitle = ""
            draftText = ""
            similar = []
            reports.insert(issue, at: 0)
            await open(issue.number)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func sendReply() async {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = selected, !text.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.addComment(n, body: text)
            reply = ""
            conversation = try await client.comments(n)
        } catch {
            self.error = error.localizedDescription
        }
    }

    var selectedReport: IssueSummary? { reports.first { $0.number == selected } }
}
