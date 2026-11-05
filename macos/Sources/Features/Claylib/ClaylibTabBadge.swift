import SwiftUI

/// What sits on a tab beside its title: a bar in the repo's color, then a block in the Claude
/// account's color. Each is hidden when there is none.
struct ClaylibTabBadge: View {
    let repo: NSColor?
    let account: NSColor?

    var body: some View {
        HStack(spacing: 3) {
            swatch(repo, width: 3)
            swatch(account, width: 6)
        }
    }

    private func swatch(_ color: NSColor?, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color(color ?? .clear))
            .frame(width: width, height: 12)
            .opacity(color == nil ? 0 : 1)
    }
}
