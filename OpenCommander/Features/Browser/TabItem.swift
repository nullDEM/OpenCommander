import SwiftUI

struct TabItem: View {
    let title: String
    let path: String
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                Text(title.isEmpty ? "/" : title).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Karta \(title)")
            .accessibilityValue(isSelected ? "aktywna" : "")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Zamknij kartę (⌘W)").accessibilityLabel("Zamknij kartę \(title)")
        }
        .font(.callout.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.primary.opacity(0.14) : (hovering ? Color.primary.opacity(0.07) : .clear)))
        .onHover { hovering = $0 }
        .help(path)
    }
}
