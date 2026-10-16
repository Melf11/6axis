import SwiftUI
import SixAxisCore

/// Dialog contents for the commands of 1.2 (construction geometry, hole, thread, patterns, move, combine).
extension CommandPanel {
    @ViewBuilder
    func modellingContent(_ cmd: ActiveCommand) -> some View {
        switch editor.commandFeature?.kind {
        case let .plane(p)?: planeContent(p, cmd)
        case let .axis(a)?: axisContent(a, cmd)
        case let .hole(h)?: holeContent(h)
        case let .thread(t)?: threadContent(t)
        case let .pattern(p)?: patternContent(p, cmd)
        case let .move(m)?: moveContent(m, cmd)
        case let .combine(c)?: combineContent(c, cmd)
        default: EmptyView()
        }
    }

    // MARK: Helpers

    private func update(_ change: @escaping (inout FeatureKind) -> Void) { editor.updateCommandFeature(change) }

    private func planeButtons(_ set: @escaping (PlaneRef) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach([PlaneRef.xy, .xz, .yz], id: \.self) { p in
                Button(p.displayName) { set(p) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func axisButtons(_ set: @escaping (AxisRef) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach([AxisRef.x, .y, .z], id: \.self) { a in
                Button(a.displayName) { set(a) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: set)).toggleStyle(.checkbox).font(.system(size: 12))
    }

    private func field(_ label: String, _ text: String, kind: ValueKind = .length, _ set: @escaping (String) -> Void) -> some View {
        ExpressionField(label: label, text: text, kind: kind, editor: editor, onChange: set)
    }

    // MARK: Construction plane

    private func planeContent(_ p: ConstructionPlaneFeature, _ cmd: ActiveCommand) -> some View {
        func set(_ change: @escaping (inout ConstructionPlaneFeature) -> Void) {
            update { k in if case var .plane(x) = k { change(&x); k = .plane(x) } }
        }
        return VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(get: { p.mode }, set: { v in set { $0.mode = v } })) {
                ForEach(ConstructionPlaneMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            selectionRow(p.mode == .midplane ? String(localized: "Ebene 1") : String(localized: "Ebene"), count: p.plane == nil ? 0 : 1,
                         symbol: "square.3.layers.3d", active: cmd.activeInput == 0, detail: p.plane?.displayName) {
                set { $0.plane = nil }
            } activate: { editor.setActiveInput(0) }
            planeButtons { r in set { $0.plane = r } }
            switch p.mode {
            case .offset:
                field(String(localized: "Abstand"), p.distance) { v in set { $0.distance = v } }
            case .angle:
                selectionRow(String(localized: "Drehachse"), count: p.axis == nil ? 0 : 1, symbol: "line.diagonal",
                             active: cmd.activeInput == 1, detail: p.axis?.displayName) {
                    set { $0.axis = nil }
                } activate: { editor.setActiveInput(1) }
                axisButtons { a in set { $0.axis = a } }
                field(String(localized: "Winkel"), p.angle, kind: .angle) { v in set { $0.angle = v } }
            case .midplane:
                selectionRow(String(localized: "Ebene 2"), count: p.plane2 == nil ? 0 : 1, symbol: "square.3.layers.3d",
                             active: cmd.activeInput == 1, detail: p.plane2?.displayName) {
                    set { $0.plane2 = nil }
                } activate: { editor.setActiveInput(1) }
            }
        }
    }

    // MARK: Construction axis

    private func axisContent(_ a: ConstructionAxisFeature, _ cmd: ActiveCommand) -> some View {
        func set(_ change: @escaping (inout ConstructionAxisFeature) -> Void) {
            update { k in if case var .axis(x) = k { change(&x); k = .axis(x) } }
        }
        return VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(get: { a.mode }, set: { v in set { $0.mode = v }; editor.setActiveInput(0) })) {
                ForEach(ConstructionAxisMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            if a.mode == .reference {
                selectionRow(String(localized: "Bezug"), count: a.axis == nil ? 0 : 1, symbol: "line.diagonal", active: true,
                             detail: a.axis?.displayName) { set { $0.axis = nil } }
                hint(String(localized: "Gerade Kante, Kreiskante oder Zylinderfläche (z. B. eine Bohrung) anklicken."))
            } else {
                selectionRow(String(localized: "Ebene 1"), count: a.plane == nil ? 0 : 1, symbol: "square.3.layers.3d",
                             active: cmd.activeInput == 0, detail: a.plane?.displayName) {
                    set { $0.plane = nil }
                } activate: { editor.setActiveInput(0) }
                selectionRow(String(localized: "Ebene 2"), count: a.plane2 == nil ? 0 : 1, symbol: "square.3.layers.3d",
                             active: cmd.activeInput == 1, detail: a.plane2?.displayName) {
                    set { $0.plane2 = nil }
                } activate: { editor.setActiveInput(1) }
            }
        }
    }

    // MARK: Hole

    private func holeContent(_ h: HoleFeature) -> some View {
        func set(_ change: @escaping (inout HoleFeature) -> Void) {
            update { k in if case var .hole(x) = k { change(&x); k = .hole(x) } }
        }
        let thread = h.thread.flatMap(MetricThread.named)
        return VStack(alignment: .leading, spacing: 12) {
            selectionRow(String(localized: "Positionen"), count: h.points.count, symbol: "smallcircle.filled.circle", active: true) {
                set { $0.points = [] }
            }
            Picker("", selection: Binding(get: { h.type }, set: { v in set { $0.type = v } })) {
                ForEach(HoleType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            LabeledRow(String(localized: "Gewinde")) {
                Picker("", selection: Binding(get: { h.thread ?? "" }, set: { v in set { $0.thread = v.isEmpty ? nil : v } })) {
                    Text("Ohne").tag("")
                    ForEach(MetricThread.all) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
            }
            if let thread {
                hint(String(localized: "Kernloch Ø \(formatValue(thread.tapDrill, kind: .length))"))
                toggle(String(localized: "Gewinde modellieren (für den 3D-Druck)"), h.threadModeled) { v in set { $0.threadModeled = v } }
            } else {
                field(String(localized: "Durchmesser"), h.diameter) { v in set { $0.diameter = v } }
            }
            LabeledRow(String(localized: "Ende")) {
                Picker("", selection: Binding(get: { h.extent }, set: { v in set { $0.extent = v } })) {
                    ForEach(HoleExtent.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if h.extent == .depth {
                field(String(localized: "Tiefe"), h.depth) { v in set { $0.depth = v } }
            }
            if h.type != .simple {
                field(String(localized: "Senkung Ø"), h.headDiameter) { v in set { $0.headDiameter = v } }
                if h.type == .counterbore {
                    field(String(localized: "Senktiefe"), h.headDepth) { v in set { $0.headDepth = v } }
                } else {
                    field(String(localized: "Senkwinkel"), h.countersinkAngle, kind: .angle) { v in set { $0.countersinkAngle = v } }
                }
            }
            toggle(String(localized: "Richtung umkehren"), h.flip) { v in set { $0.flip = v } }
        }
    }

    // MARK: Thread

    private func threadContent(_ t: ThreadFeature) -> some View {
        func set(_ change: @escaping (inout ThreadFeature) -> Void) {
            update { k in if case var .thread(x) = k { change(&x); k = .thread(x) } }
        }
        return VStack(alignment: .leading, spacing: 12) {
            selectionRow(String(localized: "Flächen"), count: t.faces.count, symbol: "cylinder", active: true) { set { $0.faces = [] } }
            LabeledRow(String(localized: "Größe")) {
                Picker("", selection: Binding(get: { t.size ?? "" }, set: { v in set { $0.size = v.isEmpty ? nil : v } })) {
                    Text("Automatisch").tag("")
                    ForEach(MetricThread.all) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
            }
            toggle(String(localized: "Gewinde modellieren (für den 3D-Druck)"), t.modeled) { v in set { $0.modeled = v } }
            hint(t.modeled ? String(localized: "Metrisches ISO-Gewinde über die ganze Länge der Fläche.")
                           : String(localized: "Nur gekennzeichnet – erscheint in der Zeichnung, der Körper bleibt glatt."))
        }
    }

    // MARK: Patterns

    private func patternContent(_ p: PatternFeature, _ cmd: ActiveCommand) -> some View {
        func set(_ change: @escaping (inout PatternFeature) -> Void) {
            update { k in if case var .pattern(x) = k { change(&x); k = .pattern(x) } }
        }
        let byFeature = !p.features.isEmpty || (p.bodies.isEmpty && editor.command?.activeInput == -1)
        return VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(get: { byFeature }, set: { v in
                set { x in
                    if v { x.bodies = []; if x.features.isEmpty, let last = editor.patternableFeatures.last { x.features = [last.id] } }
                    else { x.features = [] }
                }
                editor.setActiveInput(v ? -1 : 0)
            })) {
                Text("Körper").tag(false)
                Text("Elemente").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            if byFeature {
                LabeledRow(String(localized: "Elemente")) {
                    Menu(p.features.isEmpty ? String(localized: "Auswählen") : String(localized: "\(p.features.count) ausgewählt")) {
                        ForEach(editor.patternableFeatures) { f in
                            Toggle(f.name, isOn: Binding(get: { p.features.contains(f.id) }, set: { on in
                                set { x in if on { x.features.append(f.id) } else { x.features.removeAll { $0 == f.id } } }
                            }))
                        }
                    }
                }
                hint(String(localized: "Bohrungen, Extrusionen oder Drehungen werden an jeder Position erneut ausgeführt."))
            } else {
                selectionRow(String(localized: "Körper"), count: p.bodies.count, symbol: "cube", active: cmd.activeInput == 0) {
                    set { $0.bodies = [] }
                } activate: { editor.setActiveInput(0) }
            }
            switch p.kind {
            case .rectangular:
                selectionRow(String(localized: "Richtung"), count: p.direction == nil ? 0 : 1, symbol: "arrow.right",
                             active: cmd.activeInput == 1, detail: p.direction?.displayName) {
                    set { $0.direction = nil }
                } activate: { editor.setActiveInput(1) }
                axisButtons { a in set { $0.direction = a } }
                field(String(localized: "Anzahl"), p.count, kind: .scalar) { v in set { $0.count = v } }
                field(String(localized: "Abstand"), p.spacing) { v in set { $0.spacing = v } }
                toggle(String(localized: "Zweite Richtung"), p.direction2 != nil) { on in
                    set { $0.direction2 = on ? .y : nil }
                }
                if p.direction2 != nil {
                    selectionRow(String(localized: "Richtung 2"), count: 1, symbol: "arrow.up",
                                 active: cmd.activeInput == 2, detail: p.direction2?.displayName) {
                        set { $0.direction2 = nil }
                    } activate: { editor.setActiveInput(2) }
                    field(String(localized: "Anzahl 2"), p.count2, kind: .scalar) { v in set { $0.count2 = v } }
                    field(String(localized: "Abstand 2"), p.spacing2) { v in set { $0.spacing2 = v } }
                }
            case .circular:
                selectionRow(String(localized: "Achse"), count: p.axis == nil ? 0 : 1, symbol: "line.diagonal",
                             active: cmd.activeInput == 1, detail: p.axis?.displayName) {
                    set { $0.axis = nil }
                } activate: { editor.setActiveInput(1) }
                axisButtons { a in set { $0.axis = a } }
                field(String(localized: "Anzahl"), p.circularCount, kind: .scalar) { v in set { $0.circularCount = v } }
                field(String(localized: "Winkel"), p.angle, kind: .angle) { v in set { $0.angle = v } }
            case .mirror:
                selectionRow(String(localized: "Spiegelebene"), count: p.plane == nil ? 0 : 1, symbol: "square.3.layers.3d",
                             active: cmd.activeInput == 1, detail: p.plane?.displayName) {
                    set { $0.plane = nil }
                } activate: { editor.setActiveInput(1) }
                planeButtons { r in set { $0.plane = r } }
            }
        }
    }

    // MARK: Move / copy

    private func moveContent(_ m: MoveFeature, _ cmd: ActiveCommand) -> some View {
        func set(_ change: @escaping (inout MoveFeature) -> Void) {
            update { k in if case var .move(x) = k { change(&x); k = .move(x) } }
        }
        return VStack(alignment: .leading, spacing: 12) {
            selectionRow(String(localized: "Körper"), count: m.bodies.count, symbol: "cube", active: cmd.activeInput == 0) {
                set { $0.bodies = [] }
            } activate: { editor.setActiveInput(0) }
            field("X", m.dx) { v in set { $0.dx = v } }
            field("Y", m.dy) { v in set { $0.dy = v } }
            field("Z", m.dz) { v in set { $0.dz = v } }
            selectionRow(String(localized: "Drehachse"), count: m.axis == nil ? 0 : 1, symbol: "line.diagonal",
                         active: cmd.activeInput == 1, detail: m.axis?.displayName) {
                set { $0.axis = nil }
            } activate: { editor.setActiveInput(1) }
            axisButtons { a in set { $0.axis = a } }
            field(String(localized: "Winkel"), m.angle, kind: .angle) { v in set { $0.angle = v } }
            toggle(String(localized: "Kopie erstellen"), m.copy) { v in set { $0.copy = v } }
        }
    }

    // MARK: Combine

    private func combineContent(_ c: CombineFeature, _ cmd: ActiveCommand) -> some View {
        func set(_ change: @escaping (inout CombineFeature) -> Void) {
            update { k in if case var .combine(x) = k { change(&x); k = .combine(x) } }
        }
        return VStack(alignment: .leading, spacing: 12) {
            selectionRow(String(localized: "Ziel"), count: c.target == nil ? 0 : 1, symbol: "cube.fill", active: cmd.activeInput == 0,
                         detail: c.target.map { editor.doc.bodyName($0) }) {
                set { $0.target = nil }
            } activate: { editor.setActiveInput(0) }
            selectionRow(String(localized: "Werkzeuge"), count: c.tools.count, symbol: "cube", active: cmd.activeInput == 1) {
                set { $0.tools = [] }
            } activate: { editor.setActiveInput(1) }
            operationPicker(c.operation, operations: [.join, .cut, .intersect]) { op in set { $0.operation = op } }
            toggle(String(localized: "Werkzeugkörper behalten"), c.keepTools) { v in set { $0.keepTools = v } }
        }
    }
}
