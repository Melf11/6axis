import Foundation
import simd

/// Example designs shipped with the app (menu Ablage → Beispiele) and stored in `Examples/`.
/// They are built in code so they stay valid when the file format evolves; `ExampleTests` checks
/// that each one builds without errors and regenerates the files on request.
public enum Examples {
    public struct Example: Sendable {
        public let fileName: String
        public let title: String
        public let document: CADDocument
    }

    public static var all: [Example] {
        [
            Example(fileName: "Korpus", title: "Korpus mit Fachboden (Holz)", document: hideSketches(cabinet())),
            Example(fileName: "Schneidebrett", title: "Schneidebrett (Holz)", document: hideSketches(cuttingBoard())),
            Example(fileName: "Aufbewahrungsbox", title: "Aufbewahrungsbox (3D-Druck)", document: hideSketches(storageBox())),
        ]
    }

    /// Sketches are consumed by their extrusions; hide them so the model reads cleanly.
    static func hideSketches(_ doc: CADDocument) -> CADDocument {
        var d = doc
        d.hiddenSketches = Set(d.features.filter { $0.kind.sketch != nil }.map(\.id))
        return d
    }

    // MARK: - Korpus

    /// Cabinet 500 × 600 with sides, bottom, top, shelf, 8 mm back panel and two dowel holes.
    /// Depth is the parameter `tiefe`; the shelf is set back by 20 mm.
    public static func cabinet() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            UserParameter(name: "tiefe", expression: "300 mm", comment: "Korpustiefe ohne Rückwand"),
            UserParameter(name: "rueckversatz", expression: "20 mm", comment: "Fachboden hinten zurückgesetzt"),
        ]
        func board(_ name: String, x: ClosedRange<Double>, z: ClosedRange<Double>, depth: String,
                   material: String = "Eiche massiv", grain: GrainDirection = .length) {
            let (s, e) = rectangle(.xz, name: name, x: x, y: z, distance: depth)
            doc.features += [s, e]
            doc.bodies[e.id] = BodyMeta(name: name, material: material, grain: grain)
        }
        board("Seite links", x: 0...19, z: 0...600, depth: "tiefe")
        board("Seite rechts", x: 481...500, z: 0...600, depth: "tiefe")
        board("Boden", x: 19...481, z: 0...19, depth: "tiefe")
        board("Deckel", x: 19...481, z: 581...600, depth: "tiefe")
        board("Fachboden", x: 19...481, z: 290...309, depth: "tiefe - rueckversatz")
        // The XZ plane faces -Y: boards grow to the front, the back panel goes behind (negative distance).
        board("Rückwand", x: 0...500, z: 0...600, depth: "-8 mm", material: "Birke Multiplex", grain: .none)

        var sk = Sketch(plane: .xy)
        sk.addCircle(center: sk.addPoint(Vec2(100, -150)), radius: 4)
        sk.addCircle(center: sk.addPoint(Vec2(400, -150)), radius: 4)
        let holes = Feature(name: "Skizze Dübellöcher", kind: .sketch(sk))
        var cut = ExtrudeFeature()
        cut.profiles = [ProfileRef(sketch: holes.id, sample: Vec2(100, -150)), ProfileRef(sketch: holes.id, sample: Vec2(400, -150))]
        cut.distance = "700 mm"
        cut.operation = .cut
        doc.features += [holes, Feature(name: "Dübellöcher Ø8", kind: .extrude(cut))]

        var drawing = DrawingSettings()
        drawing.title = "Korpus"
        drawing.material = "Eiche 19 mm"
        doc.drawing = drawing
        return doc
    }

    // MARK: - Schneidebrett

    /// Cutting board 400 × 250 with R20 corners, a Ø30 hanging hole and 2 mm chamfered top edges.
    public static func cuttingBoard() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            UserParameter(name: "dicke", expression: "25 mm", comment: "Brettstärke"),
            UserParameter(name: "eckradius", expression: "20 mm", comment: ""),
        ]
        var (sketch, extrude) = rectangle(.xy, name: "Brett", x: 0...400, y: 0...250, distance: "dicke")
        guard case var .sketch(sk) = sketch.kind else { return doc }
        sk.addCircle(center: sk.addPoint(Vec2(360, 210)), radius: 15)
        sketch.kind = .sketch(sk)
        extrude.name = "Brett"
        doc.features = [sketch, extrude]
        doc.bodies[extrude.id] = BodyMeta(name: "Schneidebrett", material: "Eiche massiv", grain: .length)

        // The four vertical outer corners (not the seam line of the hanging hole).
        appendFillet(&doc, body: extrude.id, radius: "eckradius") { e in
            e.kind == .line && abs(e.end.z - e.start.z) > 1
                && (abs(e.midpoint.x) < 1 || abs(e.midpoint.x - 400) < 1) && (abs(e.midpoint.y) < 1 || abs(e.midpoint.y - 250) < 1)
        }
        // Top outline only (straight edges and corner arcs), not the hanging hole.
        appendChamfer(&doc, body: extrude.id, distance: "2 mm") { e in
            e.midpoint.z > 24 && simd_length(Vec2(e.midpoint.x - 360, e.midpoint.y - 210)) > 20
        }
        var drawing = DrawingSettings()
        drawing.title = "Schneidebrett"
        drawing.material = "Eiche 25 mm"
        doc.drawing = drawing
        return doc
    }

    // MARK: - Aufbewahrungsbox

    /// Open box 120 × 80 × 50 for 3D printing: rounded vertical edges, 2 mm walls.
    public static func storageBox() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            UserParameter(name: "hoehe", expression: "50 mm", comment: ""),
            UserParameter(name: "wand", expression: "2 mm", comment: "Wandstärke, Vielfaches der Düse (0,4)"),
            UserParameter(name: "radius", expression: "10 mm", comment: "Eckradius außen"),
        ]
        let (sketch, extrude) = rectangle(.xy, name: "Box", x: -60...60, y: -40...40, distance: "hoehe")
        doc.features = [sketch, extrude]
        doc.bodies[extrude.id] = BodyMeta(name: "Box", material: "PLA")
        appendFillet(&doc, body: extrude.id, radius: "radius") { e in e.kind == .line && abs(e.end.z - e.start.z) > 1 }

        // Remove the top face and hollow out.
        if let body = ModelBuilder().build(doc).bodies[extrude.id],
           let top = body.faceInfos.compactMap({ $0 }).filter({ $0.isPlanar && $0.normal.z > 0.99 }).max(by: { $0.centroid.z < $1.centroid.z }),
           let ref = body.faceRef(top.index) {
            var shell = ShellFeature()
            shell.faces = [BodyFaceRef(body: extrude.id, face: ref)]
            shell.thickness = "wand"
            doc.features.append(Feature(name: "Wandstärke", kind: .shell(shell)))
        }
        return doc
    }

    // MARK: - Helpers

    /// Closed, fully constrained rectangle sketch plus an extrusion of it as a new body.
    static func rectangle(_ plane: PlaneRef, name: String, x: ClosedRange<Double>, y: ClosedRange<Double>,
                          distance: String) -> (sketch: Feature, extrude: Feature) {
        var sk = Sketch(plane: plane)
        let p = [sk.addPoint(Vec2(x.lowerBound, y.lowerBound)), sk.addPoint(Vec2(x.upperBound, y.lowerBound)),
                 sk.addPoint(Vec2(x.upperBound, y.upperBound)), sk.addPoint(Vec2(x.lowerBound, y.upperBound))]
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.horizontal(line: l[0]))
        sk.addConstraint(.vertical(line: l[1]))
        sk.addConstraint(.horizontal(line: l[2]))
        sk.addConstraint(.vertical(line: l[3]))
        let fmt = { (v: Double) in String(format: "%g mm", v) }
        sk.addConstraint(.length(line: l[0], value: fmt(x.upperBound - x.lowerBound)), labelOffset: Vec2(0, -12))
        sk.addConstraint(.length(line: l[1], value: fmt(y.upperBound - y.lowerBound)), labelOffset: Vec2(12, 0))
        let s = Feature(name: "Skizze \(name)", kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2((x.lowerBound + x.upperBound) / 2, (y.lowerBound + y.upperBound) / 2))]
        ex.distance = distance
        ex.operation = .newBody
        return (s, Feature(name: name, kind: .extrude(ex)))
    }

    static func appendFillet(_ doc: inout CADDocument, body id: UUID, radius: String, where keep: (EdgeInfo) -> Bool) {
        guard let body = ModelBuilder().build(doc).bodies[id] else { return }
        var f = FilletFeature()
        f.radius = radius
        f.edges = body.edgeInfos.compactMap { $0 }.filter(keep).compactMap { info in body.edgeRef(info.index).map { BodyEdgeRef(body: id, edge: $0) } }
        doc.features.append(Feature(name: "Abrundung", kind: .fillet(f)))
    }

    static func appendChamfer(_ doc: inout CADDocument, body id: UUID, distance: String, where keep: (EdgeInfo) -> Bool) {
        guard let body = ModelBuilder().build(doc).bodies[id] else { return }
        var c = ChamferFeature()
        c.distance = distance
        c.edges = body.edgeInfos.compactMap { $0 }.filter(keep).compactMap { info in body.edgeRef(info.index).map { BodyEdgeRef(body: id, edge: $0) } }
        doc.features.append(Feature(name: "Fase", kind: .chamfer(c)))
    }
}

/// Typical densities (g/cm³) for the material names used in the body material sheet.
public enum MaterialDensity {
    static let table: [(String, Double)] = [
        ("eiche", 0.71), ("buche", 0.72), ("ahorn", 0.65), ("nussbaum", 0.64), ("kiefer", 0.52), ("fichte", 0.47),
        ("lärche", 0.59), ("birke multiplex", 0.68), ("buche multiplex", 0.75), ("sperrholz", 0.60),
        ("tischlerplatte", 0.48), ("mdf", 0.75), ("spanplatte", 0.65), ("osb", 0.62), ("hpl", 1.40),
        ("pla", 1.24), ("petg", 1.27), ("abs", 1.04), ("asa", 1.07), ("tpu", 1.21), ("nylon", 1.14), ("resin", 1.15),
        ("aluminium", 2.70), ("stahl", 7.85), ("edelstahl", 7.90), ("messing", 8.50),
    ]

    /// Density for a free-text material name ("Eiche massiv" → 0.71), nil if unknown.
    public static func lookup(_ name: String) -> Double? {
        let n = name.lowercased()
        // Longest key first so "buche multiplex" wins over "buche".
        return table.sorted { $0.0.count > $1.0.count }.first { n.contains($0.0) }?.1
    }
}
