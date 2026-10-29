import Foundation
import Observation

/// Pytanie o hasło lub passphrase klucza (treść pytania w `PromptQueue`).
public struct CredentialPrompt: Sendable {
    public let profile: ConnectionProfile
    public let kind: CredentialKind
    public init(profile: ConnectionProfile, kind: CredentialKind) { self.profile = profile; self.kind = kind }
}

/// Kolejka pytań do użytkownika (klucz serwera, hasło): w danej chwili widoczne jest jedno pytanie, kolejne czekają w kolejności
/// zgłoszenia. Po odpowiedzi pytanie znika (`current` wraca do `nil`) i dopiero wtedy pojawia się następne — okno pytania
/// nie może zostać na ekranie po udzieleniu odpowiedzi.
@MainActor @Observable
public final class PromptQueue<Info: Sendable, Answer: Sendable> {
    @MainActor @Observable
    public final class Request: Identifiable {
        public let id = UUID()
        public let info: Info
        @ObservationIgnored private var continuation: CheckedContinuation<Answer, Never>?
        @ObservationIgnored private unowned let queue: PromptQueue

        fileprivate init(info: Info, continuation: CheckedContinuation<Answer, Never>, queue: PromptQueue) {
            self.info = info; self.continuation = continuation; self.queue = queue
        }

        /// Pierwsza odpowiedź wygrywa; kolejne wywołania są ignorowane.
        public func answer(_ value: Answer) {
            guard let c = continuation else { return }
            continuation = nil
            c.resume(returning: value)
            queue.finish(self)
        }
    }

    /// Pytanie wyświetlane teraz (`nil`, gdy nikt nie czeka na odpowiedź).
    public private(set) var current: Request?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Miejsce jest zarezerwowane dla następnego oczekującego (zwolnione, ale jeszcze nieobsadzone).
    @ObservationIgnored private var handoff = false

    public init() {}

    /// Zadaje pytanie i czeka na odpowiedź użytkownika.
    public func ask(_ info: Info) async -> Answer {
        if current != nil || handoff {
            await withCheckedContinuation { waiters.append($0) }
            handoff = false
        }
        return await withCheckedContinuation { cont in
            current = Request(info: info, continuation: cont, queue: self)
        }
    }

    fileprivate func finish(_ request: Request) {
        guard current === request else { return }
        current = nil
        if !waiters.isEmpty {
            handoff = true
            waiters.removeFirst().resume()
        }
    }
}
