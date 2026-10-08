import AppKit
import SwiftUI

/// App logo access. Inside the .app bundle this is AppIcon.icns; when run via `swift run`
/// the icon is loaded from Resources/Logo.png in the source tree.
enum Branding {
    static func installAppIconIfNeeded() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil else { return }
        let png = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Logo.png")
        if let img = NSImage(contentsOf: png) { NSApp.applicationIconImage = img }
    }

    static var logo: NSImage { NSApp.applicationIconImage ?? NSImage() }

    static let repository = "https://github.com/Melf11/6axis"
    static let website = "https://melf11.github.io/6axis/"

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    /// Opens a pre-filled GitHub issue in the browser – only on explicit click, no telemetry.
    static func openFeedback(kind: String = "bug") {
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let info = "6axis \(version) · macOS \(os) · \(String(cString: model))"
        var c = URLComponents(string: repository + "/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "template", value: kind == "bug" ? "fehler.yml" : "idee.yml"),
            URLQueryItem(name: "umgebung", value: info),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    static func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "Freies, natives CAD für Konstruktion und 3D-Druck – vollständig offline.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "Open Source unter der MIT-Lizenz. Geometriekernel: Open CASCADE Technology (LGPL 2.1).\nLizenzen der enthaltenen Bibliotheken: 6axis.app/Contents/Resources/Licenses\ngithub.com/Melf11/6axis",
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "6axis",
            .applicationIcon: logo,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Small logo for toolbars and titles.
struct LogoImage: View {
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: Branding.logo)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Shown on an empty design: logo, greeting and the two most useful first steps.
struct WelcomeCard: View {
    @Bindable var editor: Editor

    var body: some View {
        VStack(spacing: 14) {
            LogoImage(size: 88)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            VStack(spacing: 4) {
                Text("Willkommen bei 6axis")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Starte mit einer Skizze – oder drücke S, um jeden Befehl zu finden.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    editor.beginCommand(.sketchPlane)
                } label: {
                    Label("Skizze erstellen", systemImage: "pencil.and.outline")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    editor.open()
                } label: {
                    Label("Öffnen …", systemImage: "folder")
                }
                Button {
                    editor.importSTEP()
                } label: {
                    Label("STEP importieren", systemImage: "square.and.arrow.down")
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .floatingPanel(radius: 20)
    }
}
