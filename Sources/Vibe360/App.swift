import AppKit
import SwiftUI
import VibeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: Editor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppSettings.shared.applyAppearance()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (editor?.confirmDiscard() ?? true) ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { editor?.open(url: url) }
    }
}

@main
struct Vibe360App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var editor = Editor()

    var body: some Scene {
        Window("Vibe360", id: "main") {
            MainView(editor: editor)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    appDelegate.editor = editor
                    DemoScript.runIfRequested(editor)
                }
                .navigationTitle(editor.documentTitle)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(editor: editor) }

        Settings {
            SettingsView()
        }
    }
}

struct AppCommands: Commands {
    let editor: Editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Design") { editor.newDocument() }.keyboardShortcut("n")
            Button("Öffnen …") { editor.open() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Sichern") { editor.save() }.keyboardShortcut("s")
            Button("Sichern unter …") { editor.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("STEP importieren …") { editor.importSTEP() }.keyboardShortcut("i")
            Menu("Exportieren") {
                Button("STL (3D-Druck) …") { editor.exportSTL() }.keyboardShortcut("e")
                Button("STEP …") { editor.exportSTEP() }
            }
            Button("Im Slicer öffnen") { editor.openInSlicer() }.keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Widerrufen") { editor.undo() }.keyboardShortcut("z").disabled(!editor.canUndo && editor.command == nil)
            Button("Wiederholen") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
        }
        CommandMenu("Darstellung") {
            Button("Alles einpassen") { editor.fitAll() }.keyboardShortcut("0")
            Button("Ausgangsansicht") { editor.homeView() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Ansicht von vorne") { editor.setView(direction: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1)) }.keyboardShortcut("1")
            Button("Ansicht von oben") { editor.setView(direction: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0)) }.keyboardShortcut("2")
            Button("Ansicht von rechts") { editor.setView(direction: SIMD3(-1, 0, 0), up: SIMD3(0, 0, 1)) }.keyboardShortcut("3")
            Divider()
            Toggle("Orthografisch", isOn: Binding(get: { editor.camera.orthographic }, set: { _ in editor.toggleProjection() }))
            Toggle("Ursprungsebenen", isOn: Binding(get: { editor.showOriginPlanes }, set: { editor.showOriginPlanes = $0; editor.sceneVersion &+= 1 }))
            Toggle("Browser", isOn: Binding(get: { editor.browserVisible }, set: { editor.browserVisible = $0 }))
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
        CommandMenu("Konstruktion") {
            Button("Befehlssuche …") { editor.showCommandPalette = true }.keyboardShortcut("k")
            Button("Parameter …") { editor.showParameters = true }.keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}
