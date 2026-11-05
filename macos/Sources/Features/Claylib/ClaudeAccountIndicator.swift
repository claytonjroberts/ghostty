import SwiftUI

/// A block of the Claude account's color on a tab; hidden with no Claude session.
struct ClaudeAccountIndicator: View {
    let color: NSColor?

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color(color ?? .clear))
            .frame(width: 6, height: 12)
            .opacity(color == nil ? 0 : 1)
    }
}
