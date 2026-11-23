import Foundation

/// Słaba referencja w pudełku — pozwala fabryce kart sięgnąć do `AppState` po zakończeniu jego inicjalizacji.
final class WeakBox<T: AnyObject> {
    weak var value: T?
}
