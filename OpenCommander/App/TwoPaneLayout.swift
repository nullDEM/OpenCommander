import SwiftUI

struct TwoPaneLayout: Layout {
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
