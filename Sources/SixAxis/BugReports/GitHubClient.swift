import Foundation
import Security

/// Minimal GitHub REST client for the bug-report chat: device-flow sign-in, the allowlist file, and the
/// user's issues and comments. Endpoints can be redirected to a local mock for tests
/// (SIXAXIS_GITHUB_API / SIXAXIS_GITHUB_LOGIN, automated runs only).
struct GitHubClient {
    static let repository = "Melf11/6axis"
    /// Marker in issues created by the app; the triage workflow recognises reports by it.
    static let reportMarker = "<!-- 6axis-bug-report -->"

    var token: String?

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var api: URL {
        if Editor.isAutomatedRun, let s = env["SIXAXIS_GITHUB_API"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com")!
    }
    static var login: URL {
        if Editor.isAutomatedRun, let s = env["SIXAXIS_GITHUB_LOGIN"], let u = URL(string: s) { return u }
        return URL(string: "https://github.com")!
    }
    /// Public client id of the "6axis" OAuth app (device flow needs no secret).
    static var clientID: String {
        if Editor.isAutomatedRun, let s = env["SIXAXIS_GITHUB_CLIENT_ID"] { return s }
        return (Bundle.main.object(forInfoDictionaryKey: "SixAxisGitHubClientID") as? String ?? "").trimmingCharacters(in: .whitespaces)
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil,
                         accept: String = "application/vnd.github+json") async throws -> Data {
        var c = URLComponents(url: Self.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { throw APIError(message: String(localized: "Die GitHub-Anmeldung ist abgelaufen – bitte neu anmelden.")) }
            throw APIError(message: String(localized: "GitHub antwortet mit Fehler \(status)"))
        }
        return data
    }

    private func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }

    // MARK: Device flow

    struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: Int
        let expiresIn: Int
    }

    static func requestDeviceCode() async throws -> DeviceCode {
        var r = URLRequest(url: login.appendingPathComponent("login/device/code"), timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("client_id=\(clientID)&scope=public_repo".utf8)
        let (data, _) = try await URLSession.shared.data(for: r)
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = o["device_code"] as? String, let user = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw APIError(message: String(localized: "GitHub-Anmeldung konnte nicht gestartet werden"))
        }
        return DeviceCode(deviceCode: code, userCode: user, verificationURL: uri,
                          interval: o["interval"] as? Int ?? 5, expiresIn: o["expires_in"] as? Int ?? 900)
    }

    /// Polls until the user confirmed the code on github.com (or it expired / was denied).
    static func pollToken(_ code: DeviceCode) async throws -> String {
        var interval = max(1, code.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()
            var r = URLRequest(url: login.appendingPathComponent("login/oauth/access_token"), timeoutInterval: 20)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data("client_id=\(clientID)&device_code=\(code.deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".utf8)
            let (data, _) = try await URLSession.shared.data(for: r)
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let token = o["access_token"] as? String { return token }
            switch o["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw APIError(message: String(localized: "Anmeldung auf GitHub abgelehnt"))
            case "expired_token": throw APIError(message: String(localized: "Der Code ist abgelaufen – bitte erneut anmelden"))
            default: throw APIError(message: String(localized: "GitHub-Anmeldung fehlgeschlagen"))
            }
        }
        throw APIError(message: String(localized: "Der Code ist abgelaufen – bitte erneut anmelden"))
    }

    // MARK: Data

    func currentUser() async throws -> String {
        guard let o = try json(try await request("GET", "user")) as? [String: Any], let login = o["login"] as? String else {
            throw APIError(message: String(localized: "GitHub-Konto konnte nicht gelesen werden"))
        }
        return login
    }

    /// The allowlist file from the main branch.
    func automationConfig() async throws -> BugAutomationConfig {
        let data = try await request("GET", "repos/\(Self.repository)/contents/.github/bug-automation.yml",
                                     query: [URLQueryItem(name: "ref", value: "main")], accept: "application/vnd.github.raw")
        return BugAutomationConfig(text: String(decoding: data, as: UTF8.self))
    }

    func searchIssues(_ text: String) async throws -> [IssueSummary] {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }.prefix(6).joined(separator: " ")
        guard !words.isEmpty else { return [] }
        let data = try await request("GET", "search/issues",
                                     query: [URLQueryItem(name: "q", value: "repo:\(Self.repository) is:issue \(words)"),
                                             URLQueryItem(name: "per_page", value: "5")])
        let items = (try json(data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap(IssueSummary.init)
    }

    func myIssues(_ login: String) async throws -> [IssueSummary] {
        let data = try await request("GET", "repos/\(Self.repository)/issues",
                                     query: [URLQueryItem(name: "creator", value: login), URLQueryItem(name: "state", value: "all"),
                                             URLQueryItem(name: "per_page", value: "50")])
        return ((try json(data)) as? [[String: Any]] ?? []).filter { $0["pull_request"] == nil }.compactMap(IssueSummary.init)
    }

    func createIssue(title: String, body: String) async throws -> IssueSummary {
        let data = try await request("POST", "repos/\(Self.repository)/issues", body: ["title": title, "body": body])
        guard let o = try json(data) as? [String: Any], let issue = IssueSummary(o) else {
            throw APIError(message: String(localized: "Bericht konnte nicht angelegt werden"))
        }
        return issue
    }

    func comments(_ number: Int) async throws -> [IssueComment] {
        let data = try await request("GET", "repos/\(Self.repository)/issues/\(number)/comments",
                                     query: [URLQueryItem(name: "per_page", value: "100")])
        return ((try json(data)) as? [[String: Any]] ?? []).compactMap(IssueComment.init)
    }

    func addComment(_ number: Int, body: String) async throws {
        _ = try await request("POST", "repos/\(Self.repository)/issues/\(number)/comments", body: ["body": body])
    }
}

struct IssueSummary: Identifiable, Equatable {
    let number: Int
    let title: String
    let body: String
    let state: String
    let labels: [String]
    let author: String
    let url: URL?
    var id: Int { number }

    init?(_ o: [String: Any]) {
        guard let n = o["number"] as? Int, let t = o["title"] as? String else { return nil }
        number = n
        title = t
        body = o["body"] as? String ?? ""
        state = o["state"] as? String ?? "open"
        labels = (o["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        author = (o["user"] as? [String: Any])?["login"] as? String ?? ""
        url = (o["html_url"] as? String).flatMap(URL.init(string:))
    }

    /// Plain-language status for the chat list.
    var status: String {
        if state == "closed" { return labels.contains("duplikat") ? String(localized: "Duplikat") : String(localized: "Erledigt") }
        if labels.contains("fix-bereit") { return String(localized: "Korrektur liegt bereit") }
        if labels.contains("in-arbeit") { return String(localized: "In Arbeit") }
        if labels.contains("braucht-info") { return String(localized: "Rückfrage") }
        if labels.contains("bereit") { return String(localized: "Wird bearbeitet") }
        return String(localized: "Neu")
    }
}

struct IssueComment: Identifiable, Equatable {
    let id: Int
    let author: String
    let body: String
    let date: Date?

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? Int else { return nil }
        self.id = id
        author = (o["user"] as? [String: Any])?["login"] as? String ?? ""
        body = o["body"] as? String ?? ""
        date = (o["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// The lists in .github/bug-automation.yml (same small format the workflow script reads).
struct BugAutomationConfig: Equatable {
    var reporters: [String] = []
    var autofix: [String] = []

    init(text: String) {
        var key: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if line.first == " " || line.first == "\t", trimmed.hasPrefix("- "), let key {
                let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "'\"")))
                if key == "reporters" { reporters.append(name) }
                if key == "autofix" { autofix.append(name) }
            } else if let colon = trimmed.firstIndex(of: ":") {
                key = String(trimmed[..<colon])
            }
        }
    }

    func allowsChat(_ login: String) -> Bool { reporters.contains { $0.caseInsensitiveCompare(login) == .orderedSame } }
    func autofixes(_ login: String) -> Bool { autofix.contains { $0.caseInsensitiveCompare(login) == .orderedSame } }
}

/// The user's GitHub token in the macOS keychain (only this app).
enum GitHubKeychain {
    private static let service = "app.6axis.github"

    static func load() -> String? {
        if Editor.isAutomatedRun { return testToken }
        var item: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        if Editor.isAutomatedRun { testToken = token; return }
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "github", kSecValueData as String: Data(token.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        if Editor.isAutomatedRun { testToken = nil; return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }

    /// Automated runs never touch the real keychain.
    nonisolated(unsafe) private static var testToken: String?
}
