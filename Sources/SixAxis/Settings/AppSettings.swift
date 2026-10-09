import AppKit
import Foundation
import Observation

/// User preferences, persisted in UserDefaults. Read anywhere via `AppSettings.shared`.
@Observable
final class AppSettings {
    /// Automated runs (SIXAXIS_* variables) use fresh, isolated defaults: reproducible results that
    /// don't depend on – and never change – the user's preferences.
    static let shared: AppSettings = {
        guard Editor.isAutomatedRun, let suite = UserDefaults(suiteName: "app.6axis.automated") else { return AppSettings() }
        suite.removePersistentDomain(forName: "app.6axis.automated")
        return AppSettings(defaults: suite)
    }()

    enum SwipeAction: String, CaseIterable, Identifiable {
        case orbit, pan
        var id: String { rawValue }
        var title: String { self == .orbit ? String(localized: "Drehen") : String(localized: "Verschieben") }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return String(localized: "Wie System")
            case .light: return String(localized: "Hell")
            case .dark: return String(localized: "Dunkel")
            }
        }
    }

    enum Shading: String, CaseIterable, Identifiable {
        case studio, simple
        var id: String { rawValue }
        var title: String { self == .studio ? String(localized: "Studio") : String(localized: "Einfach") }
    }

    enum STLQuality: String, CaseIterable, Identifiable {
        case coarse, normal, fine
        var id: String { rawValue }
        var title: String {
            switch self {
            case .coarse: return String(localized: "Grob (kleine Dateien)")
            case .normal: return String(localized: "Normal")
            case .fine: return String(localized: "Fein (glatte Rundungen)")
            }
        }
        /// Multiplier on the size-based chord tolerance.
        var factor: Double {
            switch self {
            case .coarse: return 4
            case .normal: return 1
            case .fine: return 0.3
            }
        }
    }

    enum Material: String, CaseIterable, Identifiable {
        case pla, petg, abs, asa, tpu, nylon, resin, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pla: return "PLA"
            case .petg: return "PETG"
            case .abs: return "ABS"
            case .asa: return "ASA"
            case .tpu: return "TPU"
            case .nylon: return String(localized: "Nylon (PA)")
            case .resin: return String(localized: "Resin")
            case .custom: return String(localized: "Eigene Dichte")
            }
        }
        /// g/cm³
        var density: Double {
            switch self {
            case .pla: return 1.24
            case .petg: return 1.27
            case .abs: return 1.04
            case .asa: return 1.07
            case .tpu: return 1.21
            case .nylon: return 1.14
            case .resin: return 1.15
            case .custom: return 1.0
            }
        }
    }

    // MARK: Navigation

    /// Undo macOS "natural scrolling" inside the 3D view only.
    var ignoreNaturalScrolling: Bool { didSet { save() } }
    var invertWheelZoom: Bool { didSet { save() } }
    var invertTrackpadOrbit: Bool { didSet { save() } }
    var invertTrackpadPan: Bool { didSet { save() } }
    var trackpadSwipe: SwipeAction { didSet { save() } }
    var zoomToCursor: Bool { didSet { save() } }
    var orbitSpeed: Double { didSet { save() } }
    var zoomSpeed: Double { didSet { save() } }

    // MARK: Display

    var appearance: Appearance { didSet { save(); applyAppearance() } }
    var showGrid: Bool { didSet { save() } }
    var defaultOrthographic: Bool { didSet { save() } }
    var shading: Shading { didSet { save() } }
    var showEdges: Bool { didSet { save() } }
    /// Body edge width in points.
    var edgeWidth: Double { didSet { save() } }
    var groundShadow: Bool { didSet { save() } }
    /// Snap sketch points to the grid (⌘ = free).
    var snapToGrid: Bool { didSet { save() } }

    // MARK: 3D printing

    var stlQuality: STLQuality { didSet { save() } }
    var material: Material { didSet { save() } }
    var customDensity: Double { didSet { save() } }
    /// Bundle identifier of the preferred slicer; empty = automatic.
    var preferredSlicer: String { didSet { save() } }

    // MARK: Updates

    var checkForUpdates: Bool { didSet { save() } }
    /// Tag of a release the user chose to skip ("v1.2.0").
    var skippedVersion: String { didSet { save() } }
    var lastUpdateCheck: Date { didSet { save() } }

    /// Bumped on every change so the viewport can rebuild when display settings change.
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        func double(_ k: String, _ d: Double) -> Double { defaults.object(forKey: k) as? Double ?? d }
        func string(_ k: String, _ d: String) -> String { defaults.string(forKey: k) ?? d }
        ignoreNaturalScrolling = bool("nav.ignoreNatural", false)
        invertWheelZoom = bool("nav.invertWheelZoom", false)
        invertTrackpadOrbit = bool("nav.invertOrbit", false)
        invertTrackpadPan = bool("nav.invertPan", false)
        trackpadSwipe = SwipeAction(rawValue: string("nav.swipe", "orbit")) ?? .orbit
        zoomToCursor = bool("nav.zoomToCursor", true)
        orbitSpeed = double("nav.orbitSpeed", 1)
        zoomSpeed = double("nav.zoomSpeed", 1)
        appearance = Appearance(rawValue: string("display.appearance", "system")) ?? .system
        showGrid = bool("display.grid", true)
        defaultOrthographic = bool("display.ortho", false)
        snapToGrid = bool("sketch.snapToGrid", true)
        shading = Shading(rawValue: string("display.shading", "studio")) ?? .studio
        showEdges = bool("display.edges", true)
        edgeWidth = double("display.edgeWidth", 1.4)
        groundShadow = bool("display.groundShadow", true)
        stlQuality = STLQuality(rawValue: string("print.stlQuality", "normal")) ?? .normal
        material = Material(rawValue: string("print.material", "pla")) ?? .pla
        customDensity = double("print.customDensity", 1.2)
        preferredSlicer = string("print.slicer", "")
        checkForUpdates = bool("update.check", true)
        skippedVersion = string("update.skipped", "")
        lastUpdateCheck = defaults.object(forKey: "update.lastCheck") as? Date ?? .distantPast
        loading = false
    }

    private func save() {
        guard !loading else { return }
        revision += 1
        let d = defaults
        d.set(ignoreNaturalScrolling, forKey: "nav.ignoreNatural")
        d.set(invertWheelZoom, forKey: "nav.invertWheelZoom")
        d.set(invertTrackpadOrbit, forKey: "nav.invertOrbit")
        d.set(invertTrackpadPan, forKey: "nav.invertPan")
        d.set(trackpadSwipe.rawValue, forKey: "nav.swipe")
        d.set(zoomToCursor, forKey: "nav.zoomToCursor")
        d.set(orbitSpeed, forKey: "nav.orbitSpeed")
        d.set(zoomSpeed, forKey: "nav.zoomSpeed")
        d.set(appearance.rawValue, forKey: "display.appearance")
        d.set(showGrid, forKey: "display.grid")
        d.set(defaultOrthographic, forKey: "display.ortho")
        d.set(snapToGrid, forKey: "sketch.snapToGrid")
        d.set(shading.rawValue, forKey: "display.shading")
        d.set(showEdges, forKey: "display.edges")
        d.set(edgeWidth, forKey: "display.edgeWidth")
        d.set(groundShadow, forKey: "display.groundShadow")
        d.set(stlQuality.rawValue, forKey: "print.stlQuality")
        d.set(material.rawValue, forKey: "print.material")
        d.set(customDensity, forKey: "print.customDensity")
        d.set(preferredSlicer, forKey: "print.slicer")
        d.set(checkForUpdates, forKey: "update.check")
        d.set(skippedVersion, forKey: "update.skipped")
        d.set(lastUpdateCheck, forKey: "update.lastCheck")
    }

    func resetNavigation() {
        ignoreNaturalScrolling = false
        invertWheelZoom = false
        invertTrackpadOrbit = false
        invertTrackpadPan = false
        trackpadSwipe = .orbit
        zoomToCursor = true
        orbitSpeed = 1
        zoomSpeed = 1
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var density: Double { material == .custom ? customDensity : material.density }

    /// Whether macOS currently uses natural scrolling (shown as a hint in the settings).
    static var systemUsesNaturalScrolling: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
    }

    // MARK: Slicers

    struct Slicer: Identifiable {
        let id: String   // bundle identifier
        let name: String
    }

    static let knownSlicers: [Slicer] = [
        Slicer(id: "com.bambulab.bambu-studio", name: "Bambu Studio"),
        Slicer(id: "com.prusa3d.slic3r", name: "PrusaSlicer"),
        Slicer(id: "com.prusa3d.PrusaSlicer", name: "PrusaSlicer"),
        Slicer(id: "com.softfever3d.orca-slicer", name: "OrcaSlicer"),
        Slicer(id: "nl.ultimaker.cura", name: "UltiMaker Cura"),
        Slicer(id: "com.superslicer.SuperSlicer", name: "SuperSlicer"),
        Slicer(id: "com.elegoo.elegooslicer", name: "ElegooSlicer"),
        Slicer(id: "com.creality.print", name: "Creality Print"),
    ]

    static var installedSlicers: [Slicer] {
        knownSlicers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
}
