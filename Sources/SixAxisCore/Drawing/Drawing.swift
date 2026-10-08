import Foundation
import simd

// MARK: - Settings (persisted in the document)

/// Drawing settings stored with the design. All fields optional-friendly for older files.
public struct DrawingSettings: Codable, Hashable, Sendable {
    public enum SheetChoice: String, Codable, CaseIterable, Sendable {
        case auto, a4, a3, a2
        public var title: String {
            switch self {
            case .auto: return "Automatisch"
            case .a4: return "A4 quer"
            case .a3: return "A3 quer"
            case .a2: return "A2 quer"
            }
        }
    }

    public var sheet: SheetChoice = .auto
    /// Scale denominator/numerator as "1:5", "2:1"; nil = automatic.
    public var scale: String? = nil
    public var showHidden = true
    public var showDimensions = true
    public var showIso = true
    public var title = ""
    public var drawingNumber = ""
    public var author = ""
    public var material = ""

    public init() {}
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

    public var width: Double {
        switch self {
        case .frame: return 0.7
        case .visible: return 0.5
        case .iso: return 0.35
        case .hidden, .center, .thin: return 0.25
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
}

public struct DrawingText: Sendable {
    public enum Anchor: Sendable { case center, left, right }
    public var text: String
    public var position: Vec2      // baseline anchor point
    public var height: Double      // character height in mm
    public var angle: Double = 0   // radians, counter-clockwise
    public var anchor: Anchor = .center
    public var bold = false
}

/// Filled arrowhead, ISO 129: 15° half-angle, length 3 mm.
public struct DrawingArrow: Sendable {
    public var tip: Vec2
    public var direction: Vec2     // unit vector pointing into the tip
}

public struct DrawingPage: Sendable {
    public var sheet: Sheet
    public var scale: DrawingScale
    public var lines: [DrawingLine] = []
    public var texts: [DrawingText] = []
    public var arrows: [DrawingArrow] = []
    public var isEmpty = true

    public init(sheet: Sheet, scale: DrawingScale) {
        self.sheet = sheet
        self.scale = scale
    }
}
