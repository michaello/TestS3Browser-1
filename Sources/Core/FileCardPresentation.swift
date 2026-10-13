import SwiftUI

enum FileCardPresentation {
    static let filenameFont: Font = .caption
    static let metadataFont: Font = .caption2
    static let tagFont: Font = .caption2
    static func filenameLineLimit(isAccessibilitySize: Bool) -> Int? { isAccessibilitySize ? nil : 2 }
    static func prefersList(requestedGrid: Bool, isAccessibilitySize: Bool) -> Bool { !requestedGrid || isAccessibilitySize }
}

/// Labels grow independently of the thumbnail's fixed height. Accessibility text sizes
/// may wrap the complete filename; browser screens also offer the existing list layout.
struct FileCardLabels: View {
    let name: String
    let detail: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(name)
                .font(FileCardPresentation.filenameFont)
                .fontWeight(.semibold)
                .lineLimit(FileCardPresentation.filenameLineLimit(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(FileCardPresentation.metadataFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
