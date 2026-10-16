import AppKit
import Foundation
import simd
import SixAxisCore

/// Components, instances and the exploded view.
extension Editor {
    func componentName(of body: UUID) -> String? { state.component(of: body, in: doc.components)?.name }

    /// Makes a component from the selected bodies (or the one under the selection's faces).
    func createComponent() {
        let bodies = selectedBodies().filter { state.copyOf[$0] == nil }
        guard !bodies.isEmpty else {
            showToast(String(localized: "Körper auswählen, die zusammen ein Bauteil bilden"))
            return
        }
        if let taken = bodies.first(where: { componentName(of: $0) != nil }) {
            showToast(String(localized: "„\(doc.bodyName(taken))“ gehört schon zur Komponente „\(componentName(of: taken)!)“"))
            return
        }
        var n = doc.components.count + 1
        let names = Set(doc.components.map(\.name))
        var name = bodies.count == 1 ? doc.bodyName(bodies[0]) : String(localized: "Komponente\(n)")
        while names.contains(name) { n += 1; name = String(localized: "Komponente\(n)") }
        commit { $0.components.append(ComponentDef(name: name, bodies: bodies)) }
        showToast(String(localized: "Komponente „\(name)“ erstellt – Kopien davon zählen als weitere Exemplare"))
    }

    /// Another instance of a component: a copy of its bodies, moved with the Move/Copy dialog.
    func insertInstance(_ id: UUID) {
        guard let c = doc.components.first(where: { $0.id == id }) else { return }
        selection = c.bodies.filter { state.bodies[$0] != nil }.map { .body($0) }
        beginCommand(.move)
        updateCommandFeature { k in if case var .move(m) = k { m.copy = true; m.dx = "100 mm"; k = .move(m) } }
    }

    func renameComponent(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        commit { d in if let i = d.components.firstIndex(where: { $0.id == id }) { d.components[i].name = trimmed } }
    }

    /// Removes the component (the bodies stay).
    func dissolveComponent(_ id: UUID) {
        commit { $0.components.removeAll { $0.id == id } }
    }

    // MARK: Exploded view

    /// Offset of each body in the exploded view.
    func explodeOffsets() -> [UUID: Vec3] {
        state.explodeOffsets(state.bodyOrder.filter { doc.isBodyVisible($0) }, components: doc.components, factor: explode)
    }
}
