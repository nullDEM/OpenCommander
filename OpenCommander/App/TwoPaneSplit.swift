import SwiftUI
import AppKit
import OpenCommanderCore

/// Dwa panele z przeciąganym separatorem. Zamiast `HSplitView` (który razem z inspektorem wpadał w pętlę
/// aktualizacji ograniczeń AppKit) używa własnego `Layout`: szerokość kontenera nie wraca do stanu widoku,
/// przesunięcie jest tylko liczbą pikseli względem podziału po połowie i jest przycinane w układzie.
struct TwoPaneSplit<Left: View, Right: View>: View {
    /// Ukryty panel (`nil` = oba widoczne). Ukryty panel nie jest w ogóle budowany; widoczny zachowuje tożsamość widoku
    /// (przewijanie, fokus), bo każdy z trzech elementów ma w układzie własne, stałe miejsce.
    var hidden: PanelSide?
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?

    var body: some View {
        TwoPaneLayout(offset: offset) {
            if hidden != .left { left }
            if hidden == nil { handle }
            if hidden != .right { right }
        }
    }

    private var handle: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = offset }
                    offset = (dragStart ?? 0) + value.translation.width
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { offset = 0 }
        .help("Przeciągnij, aby zmienić szerokość paneli (dwuklik: po równo)")
        .accessibilityLabel("Separator paneli")
        // VoiceOver i Sterowanie głosem nie przeciągają — separator można przesuwać strzałkami góra/dół (jak suwak).
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: offset = min(offset + Self.keyboardStep, Self.maxOffset)
            case .decrement: offset = max(offset - Self.keyboardStep, -Self.maxOffset)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Podziel panele po równo") { offset = 0 }
    }

    /// Krok przesunięcia przy obsłudze bez myszy; zakres chroni przed „nawijaniem” przesunięcia poza szerokość okna
    /// (układ i tak je przycina do szerokości paneli).
    private static var keyboardStep: CGFloat { 40 }
    private static var maxOffset: CGFloat { 3000 }
}
