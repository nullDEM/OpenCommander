import SwiftUI

struct TwoPaneLayout: Layout {
    var offset: CGFloat
    static let minPane: CGFloat = 250
    static let handleWidth: CGFloat = 9

    /// Szerokość preferowana (gdy nikt jej nie proponuje): dwa panele z separatorem.
    private static let idealWidth: CGFloat = 2 * minPane + handleWidth

    /// Układ przyjmuje każdą zaproponowaną szerokość i nigdy nie zgłasza więcej, niż mu dano: wymuszone minimum większe
    /// od miejsca w oknie (pasek boczny + inspektor) wprowadzało okno AppKit w nieskończoną pętlę przeliczania ograniczeń
    /// („The window has been marked as needing another Update Constraints…”). Panele przycina `placeSubviews`.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? Self.idealWidth, height: proposal.height ?? 400)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if subviews.count == 1 {
            // Drugi panel ukryty: jedyny panel zajmuje całą szerokość.
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
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
