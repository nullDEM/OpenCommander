import SwiftUI

struct TwoPaneLayout: Layout {
    var offset: CGFloat
    static let minPane: CGFloat = 250
    static let handleWidth: CGFloat = 9

    /// Minimalna szerokość jest stała (dwa panele z separatorem), także gdy jeden panel jest ukryty: zmiana minimalnego rozmiaru
    /// okna w trakcie przełączania paneli wymuszałaby zmianę rozmiaru okna wewnątrz przebiegu układu.
    private static let minTotal: CGFloat = 2 * minPane + handleWidth

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        return CGSize(width: max(proposal.width ?? Self.minTotal, Self.minTotal), height: proposal.height ?? 400)
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
