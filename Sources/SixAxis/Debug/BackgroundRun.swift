import AppKit

extension Editor {
    /// Automated runs stay out of the way: no Dock icon, no focus, invisible windows that let clicks
    /// pass through. SIXAXIS_VISIBLE=1 shows them (for watching a demo).
    static var runsInBackground: Bool {
        isAutomatedRun && ProcessInfo.processInfo.environment["SIXAXIS_VISIBLE"] == nil
    }
}

@MainActor
enum BackgroundRun {
    static func start() {
        NSApp.setActivationPolicy(.accessory)
        // Windows appear at any time (SwiftUI scenes, sheets, panels); catch each one after the event loop turn.
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideWindows() }
        }
        hideWindows()
    }

    static func hideWindows() {
        for w in NSApp.windows where w.alphaValue != 0 || !w.ignoresMouseEvents {
            // Fully transparent but still on screen, so Metal keeps rendering and snapshots work.
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.hasShadow = false
        }
    }
}
