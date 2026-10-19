import Foundation

/// One run of a repository script with live output. Only one at a time (scripts share working copies).
@Observable @MainActor
final class Job {
    let title: String
    private(set) var log = ""
    private(set) var running = true
    private(set) var exitCode: Int32 = 0
    private var process: Process?

    var succeeded: Bool { !running && exitCode == 0 }
    /// Last meaningful line, for the panel.
    var lastLine: String {
        log.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
    }

    init(title: String) { self.title = title }

    func start(_ script: String, _ args: [String], in repo: URL, onExit: @escaping @MainActor (Job) -> Void) {
        let p = Process()
        p.executableURL = repo.appendingPathComponent(script)
        p.arguments = args
        p.currentDirectoryURL = repo
        p.environment = Shell.environment(["SIXAXIS_WARTUNG": "1"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self.log += text }
        }
        p.terminationHandler = { proc in  // keeps the job alive until the script has ended
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() { self.log += String(decoding: rest, as: UTF8.self) }
                self.exitCode = proc.terminationStatus
                self.running = false
                onExit(self)
            }
        }
        do {
            try p.run()
            process = p
            log = "▶ \(script) \(args.joined(separator: " "))\n"
        } catch {
            log = "✗ \(error.localizedDescription)\n"
            exitCode = 1
            running = false
            onExit(self)
        }
    }

    /// Stops the script and everything it started (it runs in its own process group, see SIXAXIS_WARTUNG).
    func cancel() {
        guard running, let pid = process?.processIdentifier else { return }
        kill(-pid, SIGTERM)
        log += "\n■ abgebrochen\n"
    }
}

enum Shell {
    /// Apps started from the Dock get a minimal PATH; gh, python3 and claude live in Homebrew and ~/.local/bin.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       env["PATH"] ?? ""].joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        return env.merging(extra) { $1 }
    }

    /// Runs a script to completion and returns stdout (used for the status JSON).
    static func output(_ script: String, _ args: [String], in repo: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = repo.appendingPathComponent(script)
            p.arguments = args
            p.currentDirectoryURL = repo
            p.environment = environment()
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { cont.resume(throwing: error); return }
            // Read before waiting, so a large output cannot fill the pipe and block the script.
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: ShellError(message: text.isEmpty ? "Fehler \(p.terminationStatus)" : text))
                }
            }
        }
    }
}

struct ShellError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
