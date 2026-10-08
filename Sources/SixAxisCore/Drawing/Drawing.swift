import Foundation
import simd

// MARK: - Settings (persisted in the document)

/// Drawing settings stored with the design. All fields optional-friendly for older files.
public struct DrawingSettings: Codable, Hashable, Sendable {
    public enum SheetChoice: String, Codable, CaseIterable, Sendable {
        case auto, a4, a3, a2
        public var title: String {
            switch self {
            case .auto: return String(localized: "Automatisch")
            case .a4: return String(localized: "A4 quer")
            case .a3: return String(localized: "A3 quer")
            case .a2: return String(localized: "A2 quer")
            }
        }
    }

    public var sheet: SheetChoice = .auto
    /// Scale denominator/numerator as "1:5", "2:1"; nil = automatic.
    public var scale: String? = nil
    public var showHidden = true
    public var showDimensions = true
    public var showIso = true
    /// Stage 4: several bodies → balloons, parts/cut list and part sheets.
    public var showBalloons = true
    public var showPartsList = true
    public var showPartSheets = true
    /// Stage 5: left view as section A–A at model X = `sectionX` (nil = centre).
    public var sectionLeft = false
    public var sectionX: Double? = nil
    public var details: [DetailView] = []
    public var title = ""
    public var drawingNumber = ""
    public var author = ""
    public var material = ""

    // Manual edits (stage 3). Keyed by stable dimension/view ids, so they survive model changes.
    public var hiddenDimensions: Set<String> = []
    public var dimensionOffsets: [String: DimensionOffset] = [:]
    public var viewOffsets: [String: Vec2] = [:]
    public var customDimensions: [CustomDimension] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case sheet, scale, showHidden, showDimensions, showIso, showBalloons, showPartsList, showPartSheets
        case sectionLeft, sectionX, details
        case title, drawingNumber, author, material
        case hiddenDimensions, dimensionOffsets, viewOffsets, customDimensions
    }

    /// Every field is optional on decode so files from older versions keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DrawingSettings()
        sheet = try c.decodeIfPresent(SheetChoice.self, forKey: .sheet) ?? d.sheet
        scale = try c.decodeIfPresent(String.self, forKey: .scale)
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden) ?? d.showHidden
        showDimensions = try c.decodeIfPresent(Bool.self, forKey: .showDimensions) ?? d.showDimensions
        showIso = try c.decodeIfPresent(Bool.self, forKey: .showIso) ?? d.showIso
        showBalloons = try c.decodeIfPresent(Bool.self, forKey: .showBalloons) ?? d.showBalloons
        showPartsList = try c.decodeIfPresent(Bool.self, forKey: .showPartsList) ?? d.showPartsList
        showPartSheets = try c.decodeIfPresent(Bool.self, forKey: .showPartSheets) ?? d.showPartSheets
        sectionLeft = try c.decodeIfPresent(Bool.self, forKey: .sectionLeft) ?? false
        sectionX = try c.decodeIfPresent(Double.self, forKey: .sectionX)
        details = try c.decodeIfPresent([DetailView].self, forKey: .details) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        drawingNumber = try c.decodeIfPresent(String.self, forKey: .drawingNumber) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        material = try c.decodeIfPresent(String.self, forKey: .material) ?? ""
        hiddenDimensions = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenDimensions) ?? []
        dimensionOffsets = try c.decodeIfPresent([String: DimensionOffset].self, forKey: .dimensionOffsets) ?? [:]
        viewOffsets = try c.decodeIfPresent([String: Vec2].self, forKey: .viewOffsets) ?? [:]
        customDimensions = try c.decodeIfPresent([CustomDimension].self, forKey: .customDimensions) ?? []
    }

    public var hasManualEdits: Bool {
        !hiddenDimensions.isEmpty || !dimensionOffsets.isEmpty || !viewOffsets.isEmpty || !customDimensions.isEmpty || !details.isEmpty
    }
}

/// User adjustment of an automatic dimension, in paper millimetres.
public struct DimensionOffset: Codable, Hashable, Sendable {
    /// Moves the dimension line away from (+) or towards (−) the view.
    public var distance: Double = 0
    /// Moves the value along the dimension line.
    public var along: Double = 0
    public init(distance: Double = 0, along: Double = 0) {
        self.distance = distance
        self.along = along
    }
}

/// Enlarged detail ("Einzelheit Z") of a circular region of a view.
public struct DetailView: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var letter: String
    /// Id of the source view, e.g. "front" or "p2.front".
    public var view: String
    /// Centre and radius in the source view's model coordinates (mm).
    public var center: Vec2
    public var radius: Double
    /// Enlargement relative to the source view's scale.
    public var factor: Double

    public init(id: UUID = UUID(), letter: String, view: String, center: Vec2, radius: Double, factor: Double) {
        self.id = id
        self.letter = letter
        self.view = view
        self.center = center
        self.radius = radius
        self.factor = factor
    }

    public var viewId: String { "detail.\(id.uuidString)" }
    public var markId: String { "detail.\(id.uuidString).mark" }
}

/// A dimension added by the user between two snap points of a view.
public struct CustomDimension: Codable, Hashable, Identifiable, Sendable {
    public enum Orientation: String, Codable, Sendable { case horizontal, vertical, aligned }
    public var id: UUID
    public var view: String
    /// End points in view coordinates (model millimetres in the projection plane).
    public var a: Vec2
    public var b: Vec2
    public var orientation: Orientation
    /// Signed distance of the dimension line from point `a`, in paper mm, along the dimension's normal.
    public var offset: Double

    public init(id: UUID = UUID(), view: String, a: Vec2, b: Vec2, orientation: Orientation, offset: Double) {
        self.id = id
        self.view = view
        self.a = a
        self.b = b
        self.orientation = orientation
        self.offset = offset
    }

    public var key: String { "custom.\(id.uuidString)" }
}

// MARK: - Paper model (millimetres on paper, origin bottom-left, y up)

public struct Sheet: Hashable, Sendable {
    public let name: String
    public let width: Double
    public let height: Double

    public static let a4 = Sheet(name: "A4", width: 297, height: 210)
    public static let a3 = Sheet(name: "A3", width: 420, height: 297)
    public static let a2 = Sheet(name: "A2", width: 594, height: 420)
}

/// ISO 5455 scales, largest first.
public struct DrawingScale: Hashable, Sendable {
    public let factor: Double
    public let label: String

    public static let all: [DrawingScale] = [
        .init(factor: 5, label: "5:1"), .init(factor: 2, label: "2:1"), .init(factor: 1, label: "1:1"),
        .init(factor: 0.5, label: "1:2"), .init(factor: 0.2, label: "1:5"), .init(factor: 0.1, label: "1:10"),
        .init(factor: 0.05, label: "1:20"), .init(factor: 0.02, label: "1:50"), .init(factor: 0.01, label: "1:100"),
    ]

    public static func named(_ label: String) -> DrawingScale? { all.first { $0.label == label } }
}

/// ISO 128 line types.
public enum LineStyle: Sendable {
    case frame        // 0.7 continuous
    case visible      // 0.5 continuous
    case hidden       // 0.25 dashed
    case center       // 0.25 dash-dot
    case thin         // 0.25 continuous (dimension, extension, leader, title block)
    case iso          // 0.35 continuous (pictorial view)
    case hatch        // 0.18 continuous (section hatching, ISO 128-50)

    public var width: Double {
        switch self {
        case .frame: return 0.7
        case .visible: return 0.5
        case .iso: return 0.35
        case .hidden, .center, .thin: return 0.25
        case .hatch: return 0.18
        }
    }

    /// Dash pattern in paper mm (nil = continuous).
    public var dash: [Double]? {
        switch self {
        case .hidden: return [3, 1]
        case .center: return [8, 1.2, 0.6, 1.2]
        default: return nil
        }
    }
}

public struct DrawingLine: Sendable {
    public var points: [Vec2]
    public var style: LineStyle
    /// Id of the dimension this primitive belongs to (for hover/selection), nil for geometry.
    public var group: String? = nil
}

public struct DrawingText: Sendable {
    public enum Anchor: Sendable { case center, left, right }
    public var text: String
    public var position: Vec2      // baseline anchor point
    public var height: Double      // character height in mm
    public var angle: Double = 0   // radians, counter-clockwise
    public var anchor: Anchor = .center
    public var bold = false
    public var group: String? = nil
}

/// Filled arrowhead, ISO 129: 15° half-angle, length 3 mm.
public struct DrawingArrow: Sendable {
    public var tip: Vec2
    public var direction: Vec2     // unit vector pointing into the tip
    public var group: String? = nil
}

// MARK: - Interaction metadata

/// A dimension as placed on the sheet, for hit testing and dragging in the editor.
public struct PlacedDimension: Sendable, Identifiable {
    public var id: String
    public var text: String
    /// Segments (paper mm) that count as "on the dimension" for clicks.
    public var segments: [(Vec2, Vec2)]
    public var textCenter: Vec2
    /// Unit vector in which the dimension line moves away from its view.
    public var normal: Vec2
    /// Unit vector along the dimension line.
    public var along: Vec2
    public var isCustom: Bool
    /// Extra numeric payload (e.g. the section plane's model X).
    public var value: Double = 0
}

/// A projected view on the sheet.
public struct PlacedView: Sendable, Identifiable {
    public enum Constraint: Sendable { case all, horizontal, vertical, free }
    public var id: String
    public var title: String
    public var min: Vec2
    public var max: Vec2
    /// Paper position of the view's model-space minimum and the factor model → paper.
    public var origin: Vec2
    public var modelMin: Vec2
    public var scale: Double
    public var constraint: Constraint

    public func toPaper(_ p: Vec2) -> Vec2 { origin + (p - modelMin) * scale }
    public func toModel(_ p: Vec2) -> Vec2 { modelMin + (p - origin) / scale }
}

/// A point usable as dimension anchor (vertex or circle centre), in paper and view coordinates.
public struct DrawingSnapPoint: Sendable {
    public var view: String
    public var paper: Vec2
    public var model: Vec2
}

public struct DrawingPage: Sendable {
    /// Tab name in the editor, e.g. "Gesamtansicht" or "Einzelteile 1".
    public var name = String(localized: "Gesamtansicht")
    public var sheet: Sheet
    public var scale: DrawingScale
    /// Text for the title block's scale field (part sheets may mix scales).
    public var scaleText: String?
    public var lines: [DrawingLine] = []
    public var texts: [DrawingText] = []
    public var arrows: [DrawingArrow] = []
    public var dimensions: [PlacedDimension] = []
    public var views: [PlacedView] = []
    public var snapPoints: [DrawingSnapPoint] = []
    public var isEmpty = true
    /// Areas taken by leader labels (paper mm), used to keep callouts from overlapping.
    var leaderAreas: [(min: Vec2, max: Vec2)] = []
    var leaderLines: [(Vec2, Vec2)] = []

    public init(sheet: Sheet, scale: DrawingScale) {
        self.sheet = sheet
        self.scale = scale
    }
}
