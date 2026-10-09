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
            Example(fileName: "Korpus", title: String(localized: "Korpus mit Fachboden (Holz)"), document: hideSketches(cabinet())),
            Example(fileName: "Schneidebrett", title: String(localized: "Schneidebrett (Holz)"), document: hideSketches(cuttingBoard())),
            Example(fileName: "Aufbewahrungsbox", title: String(localized: "Aufbewahrungsbox (3D-Druck)"), document: hideSketches(storageBox())),
        ]
    }

    /// Sketches are consumed by their extrusions; hide them so the model reads cleanly.
    static func hideSketches(_ doc: CADDocument) -> CADDocument {
        var d = doc
        d.hiddenSketches = Set(d.features.filter { $0.kind.sketch != nil }.map(\.id))
        return d
    }

    // MARK: - Korpus

    /// Cabinet with sides, bottom, top, shelf, back panel and two dowel holes – every size is a parameter.
    public static func cabinet() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            UserParameter(name: "breite", expression: "500 mm", comment: String(localized: "Außenmaß")),
            UserParameter(name: "hoehe", expression: "600 mm", comment: String(localized: "Außenmaß")),
            UserParameter(name: "tiefe", expression: "300 mm", comment: String(localized: "ohne Rückwand")),
            UserParameter(name: "staerke", expression: "19 mm", comment: String(localized: "Plattenstärke")),
            UserParameter(name: "fachhoehe", expression: "290 mm", comment: String(localized: "Unterkante Fachboden")),
            UserParameter(name: "rueckversatz", expression: "20 mm", comment: String(localized: "Fachboden hinten zurückgesetzt")),
            UserParameter(name: "rueckwand", expression: "8 mm", comment: String(localized: "Stärke Rückwand")),
        ]
        func board(_ name: String, x: (String, Double), z: (String, Double), w: (String, Double), h: (String, Double),
                   depth: String, material: String = String(localized: "Eiche massiv"), grain: GrainDirection = .length) {
            let (s, e) = rectangle(.xz, name: name, x: x, y: z, width: w, height: h, distance: depth)
            doc.features += [s, e]
            doc.bodies[e.id] = BodyMeta(name: name, material: material, grain: grain)
        }
        let inner = ("breite - 2 * staerke", 462.0)
        board(String(localized: "Seite links"), x: ("0 mm", 0), z: ("0 mm", 0), w: ("staerke", 19), h: ("hoehe", 600), depth: "tiefe")
        board(String(localized: "Seite rechts"), x: ("breite - staerke", 481), z: ("0 mm", 0), w: ("staerke", 19), h: ("hoehe", 600), depth: "tiefe")
        board(String(localized: "Boden"), x: ("staerke", 19), z: ("0 mm", 0), w: inner, h: ("staerke", 19), depth: "tiefe")
        board(String(localized: "Deckel"), x: ("staerke", 19), z: ("hoehe - staerke", 581), w: inner, h: ("staerke", 19), depth: "tiefe")
        board(String(localized: "Fachboden"), x: ("staerke", 19), z: ("fachhoehe", 290), w: inner, h: ("staerke", 19), depth: "tiefe - rueckversatz")
        // The XZ plane faces -Y: boards grow to the front, the back panel goes behind (negative distance).
        board(String(localized: "Rückwand"), x: ("0 mm", 0), z: ("0 mm", 0), w: ("breite", 500), h: ("hoehe", 600), depth: "-rueckwand",
              material: String(localized: "Birke Multiplex"), grain: .none)

        // Dowel holes Ø8 through the horizontal boards, 100 mm from the sides, centred in the depth.
        var sk = Sketch(plane: .xy)
        var holes: [ProfileRef] = []
        let sketchId = UUID()
        for (x, xv) in [("100 mm", 100.0), ("breite - 100 mm", 400.0)] {
            let c = sk.addPoint(Vec2(xv, -150))
            let circle = sk.addCircle(center: c, radius: 4)
            sk.addConstraint(.horizontalDistance(Sketch.originId, c, value: x))
            sk.addConstraint(.verticalDistance(Sketch.originId, c, value: "tiefe / 2"))
            sk.addConstraint(.diameter(curve: circle, value: "8 mm"))
            holes.append(ProfileRef(sketch: sketchId, sample: Vec2(xv, -150), anchor: ProfileAnchor(points: [c], weights: [1])))
        }
        let holeSketch = Feature(id: sketchId, name: String(localized: "Skizze Dübellöcher"), kind: .sketch(sk))
        var cut = ExtrudeFeature()
        cut.profiles = holes
        cut.distance = "hoehe + 100 mm"
        cut.operation = .cut
        doc.features += [holeSketch, Feature(name: String(localized: "Dübellöcher Ø8"), kind: .extrude(cut))]

        var drawing = DrawingSettings()
        drawing.title = String(localized: "Korpus")
        drawing.material = String(localized: "Eiche 19 mm")
        doc.drawing = drawing
        return doc
    }

    // MARK: - Schneidebrett

    /// Cutting board with rounded corners, a Ø30 hanging hole and 2 mm chamfered top edges.
    public static func cuttingBoard() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            UserParameter(name: "laenge", expression: "400 mm", comment: ""),
            UserParameter(name: "breite", expression: "250 mm", comment: ""),
            UserParameter(name: "dicke", expression: "25 mm", comment: String(localized: "Brettstärke")),
            UserParameter(name: "eckradius", expression: "20 mm", comment: ""),
        ]
        var (sketch, extrude) = rectangle(.xy, name: String(localized: "Brett"), x: ("0 mm", 0), y: ("0 mm", 0),
                                          width: ("laenge", 400), height: ("breite", 250), distance: "dicke")
        guard case var .sketch(sk) = sketch.kind else { return doc }
        let c = sk.addPoint(Vec2(360, 210))
        let hole = sk.addCircle(center: c, radius: 15)
        sk.addConstraint(.horizontalDistance(Sketch.originId, c, value: "laenge - 40 mm"))
        sk.addConstraint(.verticalDistance(Sketch.originId, c, value: "breite - 40 mm"))
        sk.addConstraint(.diameter(curve: hole, value: "30 mm"))
        sketch.kind = .sketch(sk)
        doc.features = [sketch, extrude]
        doc.bodies[extrude.id] = BodyMeta(name: String(localized: "Schneidebrett"), material: String(localized: "Eiche massiv"), grain: .length)

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
        drawing.title = String(localized: "Schneidebrett")
        drawing.material = String(localized: "Eiche 25 mm")
        doc.drawing = drawing
        return doc
    }

    // MARK: - Aufbewahrungsbox

    /// Open box for 3D printing, centred on the origin: rounded vertical edges, thin walls.
    public static func storageBox() -> CADDocument {
        var doc = CADDocument()
        doc.parameters = [
            UserParameter(name: "laenge", expression: "120 mm", comment: ""),
            UserParameter(name: "breite", expression: "80 mm", comment: ""),
            UserParameter(name: "hoehe", expression: "50 mm", comment: ""),
            UserParameter(name: "wand", expression: "2 mm", comment: String(localized: "Wandstärke, Vielfaches der Düse (0,4)")),
            UserParameter(name: "radius", expression: "10 mm", comment: String(localized: "Eckradius außen")),
        ]
        let (sketch, extrude) = rectangle(.xy, name: String(localized: "Box"), x: ("laenge / 2", -60), y: ("breite / 2", -40),
                                          width: ("laenge", 120), height: ("breite", 80), distance: "hoehe")
        doc.features = [sketch, extrude]
        doc.bodies[extrude.id] = BodyMeta(name: String(localized: "Box"), material: String(localized: "PLA"))
        appendFillet(&doc, body: extrude.id, radius: "radius") { e in e.kind == .line && abs(e.end.z - e.start.z) > 1 }

        // Remove the top face and hollow out.
        if let body = ModelBuilder().build(doc).bodies[extrude.id],
           let top = body.faceInfos.compactMap({ $0 }).filter({ $0.isPlanar && $0.normal.z > 0.99 }).max(by: { $0.centroid.z < $1.centroid.z }),
           let ref = body.faceRef(top.index) {
            var shell = ShellFeature()
            shell.faces = [BodyFaceRef(body: extrude.id, face: ref)]
            shell.thickness = "wand"
            doc.features.append(Feature(name: String(localized: "Wandstärke"), kind: .shell(shell)))
        }
        return doc
    }

    // MARK: - Helpers

    /// Fully constrained rectangle (position from the sketch origin, width, height – each an expression
    /// with its initial value) plus an extrusion of it as a new body. The profile is anchored to the
    /// four corners, so it follows parameter changes.
    static func rectangle(_ plane: PlaneRef, name: String, x: (String, Double), y: (String, Double),
                          width: (String, Double), height: (String, Double), distance: String) -> (sketch: Feature, extrude: Feature) {
        var sk = Sketch(plane: plane)
        let x0 = x.1, y0 = y.1, x1 = x.1 + width.1, y1 = y.1 + height.1
        let p = [sk.addPoint(Vec2(x0, y0)), sk.addPoint(Vec2(x1, y0)), sk.addPoint(Vec2(x1, y1)), sk.addPoint(Vec2(x0, y1))]
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.horizontal(line: l[0]))
        sk.addConstraint(.vertical(line: l[1]))
        sk.addConstraint(.horizontal(line: l[2]))
        sk.addConstraint(.vertical(line: l[3]))
        sk.addConstraint(.length(line: l[0], value: width.0), labelOffset: Vec2(0, -12))
        sk.addConstraint(.length(line: l[1], value: height.0), labelOffset: Vec2(12, 0))
        sk.addConstraint(.horizontalDistance(Sketch.originId, p[0], value: x.0))
        sk.addConstraint(.verticalDistance(Sketch.originId, p[0], value: y.0))
        let s = Feature(name: String(localized: "Skizze \(name)"), kind: .sketch(sk))
        var ex = ExtrudeFeature()
        ex.profiles = [ProfileRef(sketch: s.id, sample: Vec2((x0 + x1) / 2, (y0 + y1) / 2),
                                  anchor: ProfileAnchor(points: p, weights: [0.25, 0.25, 0.25, 0.25]))]
        ex.distance = distance
        ex.operation = .newBody
        return (s, Feature(name: name, kind: .extrude(ex)))
    }

    static func appendFillet(_ doc: inout CADDocument, body id: UUID, radius: String, where keep: (EdgeInfo) -> Bool) {
        guard let body = ModelBuilder().build(doc).bodies[id] else { return }
        var f = FilletFeature()
        f.radius = radius
        f.edges = body.edgeInfos.compactMap { $0 }.filter(keep).compactMap { info in body.edgeRef(info.index).map { BodyEdgeRef(body: id, edge: $0) } }
        doc.features.append(Feature(name: String(localized: "Abrundung"), kind: .fillet(f)))
    }

    static func appendChamfer(_ doc: inout CADDocument, body id: UUID, distance: String, where keep: (EdgeInfo) -> Bool) {
        guard let body = ModelBuilder().build(doc).bodies[id] else { return }
        var c = ChamferFeature()
        c.distance = distance
        c.edges = body.edgeInfos.compactMap { $0 }.filter(keep).compactMap { info in body.edgeRef(info.index).map { BodyEdgeRef(body: id, edge: $0) } }
        doc.features.append(Feature(name: String(localized: "Fase"), kind: .chamfer(c)))
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
        // English names (localized examples and material presets)
        ("oak", 0.71), ("beech", 0.72), ("maple", 0.65), ("walnut", 0.64), ("pine", 0.52), ("spruce", 0.47),
        ("larch", 0.59), ("birch plywood", 0.68), ("beech plywood", 0.75), ("plywood", 0.60), ("blockboard", 0.48),
        ("chipboard", 0.65), ("particleboard", 0.65), ("aluminum", 2.70), ("stainless steel", 7.90), ("steel", 7.85), ("brass", 8.50),
    ]

    /// Density for a free-text material name ("Eiche massiv" → 0.71), nil if unknown.
    public static func lookup(_ name: String) -> Double? {
        let n = name.lowercased()
        // Longest key first so "buche multiplex" wins over "buche".
        return table.sorted { $0.0.count > $1.0.count }.first { n.contains($0.0) }?.1
    }
}
