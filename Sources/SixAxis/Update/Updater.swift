import AppKit
import Foundation
import SixAxisCore

/// Checks GitHub for a newer release and installs it in place.
///
/// - Check: `GET releases/latest` – once a day if enabled in the settings, or from the menu. Nothing about
///   the user is sent; it is a plain HTTPS request to GitHub.
/// - Install: downloads the release ZIP, verifies its Ed25519 signature against the public key built
///   into the app (Info.plist `SixAxisUpdatePublicKey`), unpacks it, checks bundle id and version, and
///   lets a small helper swap the app bundle after 6axis has quit, then relaunches it.
///   Without a valid signature nothing is installed – the release page opens instead.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Newer release than the running app (drives the badge in the title bar).
    private(set) var release: Update.Release?
    var showSheet = false
    /// Set right before quitting for the update, so quitting doesn't ask again.
    private(set) var isRelaunching = false

    let current = Update.Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")

    private let env = ProcessInfo.processInfo.environment
    private var feedURL: URL {
        if let s = env["SIXAXIS_UPDATE_FEED"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/Melf11/6axis/releases/latest")!
    }
    private var publicKey: String {
        if Editor.isAutomatedRun, let k = env["SIXAXIS_UPDATE_PUBLIC_KEY"] { return k }
        return Bundle.main.object(forInfoDictionaryKey: "SixAxisUpdatePublicKey") as? String ?? ""
    }
    var canInstallAutomatically: Bool { release?.archive != nil && release?.signature != nil && !publicKey.isEmpty }

    // MARK: Checking

    /// Called at launch: checks at most once a day, never in automated runs (unless a test feed is set).
    func checkIfDue() {
        let s = AppSettings.shared
        if Editor.isAutomatedRun && env["SIXAXIS_UPDATE_FEED"] == nil { return }
        guard s.checkForUpdates, Date().timeIntervalSince(s.lastUpdateCheck) > 20 * 3600 || env["SIXAXIS_UPDATE_FEED"] != nil else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard phase != .checking, !isBusy else { return }
        phase = .checking
        if userInitiated { showSheet = true }
        do {
            var req = URLRequest(url: feedURL, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("6axis/\(current?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw KernelError("GitHub antwortet mit Fehler \(http.statusCode)")
            }
            let latest = try Update.Release.parse(data)
            AppSettings.shared.lastUpdateCheck = Date()
            if let current, latest.version > current {
                release = latest
                phase = .available
                // Automatic checks stay quiet for a version the user chose to skip.
                if !userInitiated && AppSettings.shared.skippedVersion == latest.tag { release = nil; phase = .idle }
            } else {
                release = nil
                phase = .upToDate
            }
        } catch {
            phase = userInitiated ? .failed(String(localized: "Suche nach Updates fehlgeschlagen: \(error.localizedDescription)")) : .idle
        }
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    func skipThisVersion() {
        if let release { AppSettings.shared.skippedVersion = release.tag }
        release = nil
        phase = .idle
        showSheet = false
    }

    func openReleasePage() {
        NSWorkspace.shared.open(release?.page ?? URL(string: Branding.repository + "/releases/latest")!)
    }

    // MARK: Installing

    /// Downloads, verifies and stages the update, then quits and lets the helper swap and relaunch.
    func install(editor: Editor) async {
        guard let release, let archiveURL = release.archive, let signatureURL = release.signature, !publicKey.isEmpty else {
            openReleasePage()
            return
        }
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        if appURL.path.contains("/AppTranslocation/") {
            phase = .failed(String(localized: "Bitte ziehe 6axis zuerst in den Programme-Ordner und starte es von dort – dann kann es sich selbst aktualisieren."))
            return
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            phase = .failed(String(localized: "Keine Schreibrechte für „\(parent.path)“. Lade das Update bitte von der Release-Seite."))
            return
        }
        do {
            phase = .downloading(0)
            let archive = try await Downloader.fetch(archiveURL) { [weak self] p in
                Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(p) } }
            }
            let (sigData, _) = try await URLSession.shared.data(from: signatureURL)
            phase = .installing
            guard Update.verify(archive, signature: String(decoding: sigData, as: UTF8.self), publicKey: publicKey) else {
                throw KernelError("Die Signatur des Updates ist ungültig – es wurde nichts installiert.")
            }
            let staged = try stage(archive, expecting: release.version)
            guard editor.confirmDiscard() else { phase = .available; try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()); return }
            try launchSwapHelper(newApp: staged, oldApp: appURL)
            isRelaunching = true
            NSApp.terminate(nil)
        } catch {
            phase = .failed(String(localized: "Update fehlgeschlagen: \(error.localizedDescription)"))
        }
    }

    /// Unpacks the ZIP into a temporary folder and checks that it contains the expected app.
    private func stage(_ archive: Data, expecting version: Update.Version) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("6axis-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try archive.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw KernelError("Update konnte nicht entpackt werden") }
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: app)?.infoDictionary else { throw KernelError("Im Update ist keine App enthalten") }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw KernelError("Das Update gehört nicht zu 6axis") }
        guard let v = (info["CFBundleShortVersionString"] as? String).flatMap(Update.Version.init), v == version else {
            throw KernelError("Die Version im Update passt nicht zum Release")
        }
        return app
    }

    /// A detached shell helper waits until 6axis has quit, swaps the bundles (keeping the old one on
    /// failure) and relaunches the new version.
    private func launchSwapHelper(newApp: URL, oldApp: URL) throws {
        let backup = newApp.deletingLastPathComponent().appendingPathComponent("previous.app")
        let relaunch = env["SIXAXIS_UPDATE_NO_RELAUNCH"] == nil
        let script = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        for i in $(seq 1 600); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
        kill -0 $pid 2>/dev/null && exit 1
        mv "$OLD" "$BACKUP" || exit 1
        if mv "$NEW" "$OLD"; then
            xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
            rm -rf "$BACKUP"
        else
            mv "$BACKUP" "$OLD"
        fi
        \(relaunch ? "open \"$OLD\"" : "")
        rm -rf "$STAGE"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["OLD": oldApp.path, "NEW": newApp.path, "BACKUP": backup.path,
                         "STAGE": newApp.deletingLastPathComponent().path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

/// URLSession download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    private let progress: (Double) -> Void

    private init(progress: @escaping (Double) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, progress: @escaping (Double) -> Void) async throws -> Data {
        let d = Downloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: KernelError("Download fehlgeschlagen (\(http.statusCode))"))
        } else if let data = try? Data(contentsOf: location) {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: KernelError("Download fehlgeschlagen"))
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}
