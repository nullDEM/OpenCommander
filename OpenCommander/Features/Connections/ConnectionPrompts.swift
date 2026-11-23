import SwiftUI
import OpenCommanderCore

/// Wspólne podpięcie okien pytań. Tylko jedno miejsce w hierarchii je prezentuje (`topLevel`), żeby nie powstały dwa arkusze naraz:
/// gdy otwarty jest inny arkusz (menedżer połączeń, formularz), pytania pojawiają się nad nim.
struct ConnectionPrompts: ViewModifier {
    let state: AppState
    let topLevel: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { show ? state.hostKeyPrompts.current : nil }, set: { _ in })) { HostKeySheet(request: $0) }
            .sheet(item: Binding(get: { show ? state.credentialPrompts.current : nil }, set: { _ in })) { CredentialSheet(request: $0) }
    }

    private var show: Bool { topLevel ? state.sheet == nil : state.sheet != nil }
}

extension View {
    func connectionPrompts(_ state: AppState, topLevel: Bool) -> some View { modifier(ConnectionPrompts(state: state, topLevel: topLevel)) }
}
