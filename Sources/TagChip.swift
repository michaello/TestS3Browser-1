import SwiftUI

/// Small colored capsule displaying a tag label.
struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color(for: tag), in: Capsule())
    }

    /// Derives a stable color from the tag string so each distinct tag gets a consistent hue.
    private func color(for tag: String) -> Color {
        let palette: [Color] = [.indigo, .teal, .pink, .orange, .purple, .cyan, .mint, .brown]
        let index = abs(tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[index]
    }
}

#Preview {
    HStack {
        TagChip(tag: "important")
        TagChip(tag: "review")
        TagChip(tag: "archive")
    }
    .padding()
}
