import SwiftUI
import AppKit

/// Dwa panele z przeciąganym separatorem. Zamiast `HSplitView` (który razem z inspektorem wpadał w pętlę
/// aktualizacji ograniczeń AppKit) używa własnego `Layout`: szerokość kontenera nie wraca do stanu widoku,
/// przesunięcie jest tylko liczbą pikseli względem podziału po połowie i jest przycinane w układzie.
struct TwoPaneSplit<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?

    var body: some View {
        TwoPaneLayout(offset: offset) {
            left
            handle
            right
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
    }
}

private struct TwoPaneLayout: Layout {
    var offset: CGFloat
    static let minPane: CGFloat = 250
    static let handleWidth: CGFloat = 9

    private var minTotal: CGFloat { 2 * Self.minPane + Self.handleWidth }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(proposal.width ?? minTotal, minTotal), height: proposal.height ?? 400)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let available = max(bounds.width - Self.handleWidth, 0)
        let lower = min(Self.minPane, available / 2)
        let leftWidth = min(max(available / 2 + offset, lower), available - lower)
        let rightWidth = available - leftWidth
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: leftWidth, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + leftWidth, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: Self.handleWidth, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.minX + leftWidth + Self.handleWidth, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: rightWidth, height: bounds.height))
    }
}
