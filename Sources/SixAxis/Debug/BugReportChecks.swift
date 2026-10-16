import AppKit
import Foundation

/// Drives the bug-report chat against the mock GitHub server (scripts/mock_github.py).
@MainActor
enum BugReportChecks {
    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print(ok ? "CHECK ok \(name)" : "CHECK FAIL \(name): \(detail())")
    }

    static func wait(_ seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    static func run(_ editor: Editor, expectChat: Bool, snapshots: String?) async {
        let r = BugReports.shared
        AppSettings.shared.bugReportsEnabled = true
        r.signIn()
        await wait(3) { if case .waitingForCode = r.account { return true }; return false }
        if case let .waitingForCode(code, _) = r.account {
            check("device code shown and copied", code == "ABCD-1234" && NSPasteboard.general.string(forType: .string) == code)
        }
        await wait(15) { if case .signedIn = r.account { return true }; if case .failed = r.account { return true }; return false }
        guard case let .signedIn(login, chat, autofix) = r.account else {
            check("signed in", false, "\(r.account)")
            return
        }
        check("signed in", true)
        check("chat permission from reporters list", chat == expectChat, "@\(login) chat=\(chat)")
        guard expectChat else {
            check("chat unavailable for unlisted account", !r.canUseChat)
            return
        }
        check("autofix flag from autofix list", autofix == (login == "Melf11"))
        // Similar reports while typing.
        r.draftTitle = "Spline trimmen klappt nicht"
        r.draftText = "Wenn ich einen Spline trimmen will passiert nichts"
        r.draftChanged()
        await wait(3) { !r.similar.isEmpty }
        check("similar reports suggested", r.similar.contains { $0.number == 1 })
        // Send.
        let sent = await r.send()
        check("report sent", sent && r.reports.first?.title == "Spline trimmen klappt nicht")
        let body = r.selectedReport?.body ?? ""
        check("report carries marker and environment", body.contains(GitHubClient.reportMarker) && body.contains("6axis "))
        check("triage reply shown", r.conversation.contains { $0.author == "github-actions[bot]" })
        r.reply = "Version 1.1.2"
        await r.sendReply()
        check("reply sent", r.conversation.last?.body == "Version 1.1.2" && r.reply.isEmpty)
        if let dir = snapshots {
            editor.openBugReportWindow()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let w = NSApp.windows.first(where: { $0.title == String(localized: "Fehlerberichte") }), let v = w.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("bugreport-chat.png"))
            }
        }
        r.signOut()
        check("sign out clears account", r.login == nil && GitHubKeychain.load() == nil)
    }
}
