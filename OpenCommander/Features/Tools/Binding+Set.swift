import SwiftUI

extension Binding {
    /// Przełącznik członkostwa jednego elementu w zbiorze, np. `Toggle(isOn: $marked.contains(url))`.
    func contains<Element: Hashable>(_ element: Element) -> Binding<Bool> where Value == Set<Element> {
        Binding<Bool>(
            get: { wrappedValue.contains(element) },
            set: { isMember in
                if isMember { wrappedValue.insert(element) } else { wrappedValue.remove(element) }
            }
        )
    }
}
