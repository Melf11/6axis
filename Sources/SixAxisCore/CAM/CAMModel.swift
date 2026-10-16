import Foundation
import simd

// 2.0 "Fräsen", stage 1: 2.5D machining of plate parts – setup, tools, operations (see docs/cam.md).

public enum ToolKind: String, Codable, CaseIterable, Hashable, Sendable {
    case flat, ball, vbit, drill

    public var displayName: String {
        switch self {
        case .flat: return String(localized: "Schaftfräser")
        case .ball: return String(localized: "Kugelfräser")
        case .vbit: return String(localized: "V-Nutfräser")
        case .drill: return String(localized: "Bohrer")
        }
    }
}

public struct CAMTool: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var number: Int
    public var name: String
    public var kind: ToolKind
    public var diameter: Double
    /// Cutting length (deeper cuts are flagged).
    public var fluteLength: Double
    public var rpm: Double
    /// mm/min
    public var feed: Double
    public var plunge: Double
    /// Depth per pass (mm) and side step for pockets (fraction of the diameter).
    public var stepdown: Double
    public var stepover: Double

    public init(id: UUID = UUID(), number: Int, name: String, kind: ToolKind, diameter: Double, fluteLength: Double,
                rpm: Double, feed: Double, plunge: Double, stepdown: Double, stepover: Double = 0.45) {
        self.id = id
        self.number = number
        self.name = name
        self.kind = kind
        self.diameter = diameter
        self.fluteLength = fluteLength
        self.rpm = rpm
        self.feed = feed
        self.plunge = plunge
        self.stepdown = stepdown
        self.stepover = stepover
    }

    /// Typical cutters for wood (softwood/plywood/MDF) on a hobby router.
    public static let woodDefaults: [CAMTool] = [
        CAMTool(number: 1, name: String(localized: "Schaftfräser Ø3"), kind: .flat, diameter: 3, fluteLength: 12, rpm: 20000, feed: 900, plunge: 300, stepdown: 1.5),
        CAMTool(number: 2, name: String(localized: "Schaftfräser Ø6"), kind: .flat, diameter: 6, fluteLength: 22, rpm: 18000, feed: 1500, plunge: 400, stepdown: 3),
        CAMTool(number: 3, name: String(localized: "Schaftfräser Ø8"), kind: .flat, diameter: 8, fluteLength: 25, rpm: 16000, feed: 1800, plunge: 450, stepdown: 4),
        CAMTool(number: 4, name: String(localized: "Bohrer Ø5"), kind: .drill, diameter: 5, fluteLength: 30, rpm: 6000, feed: 600, plunge: 300, stepdown: 5),
        CAMTool(number: 5, name: String(localized: "Bohrer Ø8"), kind: .drill, diameter: 8, fluteLength: 35, rpm: 5000, feed: 600, plunge: 300, stepdown: 5),
        CAMTool(number: 6, name: String(localized: "V-Nut 90°"), kind: .vbit, diameter: 12, fluteLength: 6, rpm: 18000, feed: 1200, plunge: 300, stepdown: 1),
    ]
}

/// Where X0 Y0 Z0 of the program lies on the stock.
public enum WorkOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case frontLeftTop, backLeftTop, centerTop, frontLeftBottom

    public var displayName: String {
        switch self {
        case .frontLeftTop: return String(localized: "Ecke vorne links, Oberseite")
        case .backLeftTop: return String(localized: "Ecke hinten links, Oberseite")
        case .centerTop: return String(localized: "Mitte, Oberseite")
        case .frontLeftBottom: return String(localized: "Ecke vorne links, Unterseite (Tisch)")
        }
    }
}

public enum PostProcessor: String, Codable, CaseIterable, Hashable, Sendable {
    case grbl, linuxcnc, mach3

    public var displayName: String {
        switch self {
        case .grbl: return "GRBL / grblHAL / FluidNC"
        case .linuxcnc: return "LinuxCNC"
        case .mach3: return "Mach3 / Mach4"
        }
    }
}

public enum ContourSide: String, Codable, CaseIterable, Hashable, Sendable {
    case outside, inside, on

    public var displayName: String {
        switch self {
        case .outside: return String(localized: "Außen")
        case .inside: return String(localized: "Innen")
        case .on: return String(localized: "Auf Linie")
        }
    }
}

public enum CAMOperationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case contour, pocket, drill

    public var displayName: String {
        switch self {
        case .contour: return String(localized: "Kontur")
        case .pocket: return String(localized: "Tasche")
        case .drill: return String(localized: "Bohren")
        }
    }

    public var symbol: String {
        switch self {
        case .contour: return "scribble"
        case .pocket: return "square.dashed.inset.filled"
        case .drill: return "circle.dotted"
        }
    }
}

public struct CAMOperation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: CAMOperationKind
    public var enabled: Bool = true
    /// Contour: top faces of the parts; pocket: pocket bottom faces; drill: faces of holes (or a part's top face = all its holes).
    public var faces: [BodyFaceRef] = []
    public var tool: UUID?
    public var side: ContourSide = .outside
    /// Contour: cut this far below the part's bottom (through the material into the spoil board).
    public var overcut: String = "0.3 mm"
    /// Holding tabs (contours): count per loop, width and height.
    public var tabs: Int = 4
    public var tabWidth: String = "8 mm"
    public var tabHeight: String = "3 mm"
    /// Climb (Gleichlauf) or conventional milling.
    public var climb: Bool = true

    public init(id: UUID = UUID(), name: String, kind: CAMOperationKind) {
        self.id = id
        self.name = name
        self.kind = kind
        if kind != .contour { tabs = 0 }
    }
}

public struct CAMSetup: Codable, Hashable, Sendable {
    public var origin: WorkOrigin = .frontLeftTop
    /// Extra stock around and above the parts.
    public var margin: String = "10 mm"
    public var topExtra: String = "0 mm"
    /// Safe height above the stock top for rapid moves (mm).
    public var safeZ: String = "10 mm"
    public var post: PostProcessor = .grbl
    public var tools: [CAMTool] = CAMTool.woodDefaults
    public var operations: [CAMOperation] = []
    /// Bodies to machine (empty = all visible).
    public var bodies: [UUID] = []
    public init() {}
}
