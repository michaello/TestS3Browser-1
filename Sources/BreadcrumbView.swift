import SwiftUI

/// Displays a breadcrumb navigation path for S3 folder browsing
struct BreadcrumbView: View {
    let pathComponents: [String]
    let onTapIndex: (Int) -> Void
    let onTapRoot: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root bucket button
                Button(action: onTapRoot) {
                    Text("Bucket")
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                // Path components
                ForEach(pathComponents.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Button(action: { onTapIndex(index) }) {
                            Text(pathComponents[index])
                                .font(.caption)
                                .foregroundColor(.blue)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
    }
}

#Preview {
    VStack {
        BreadcrumbView(
            pathComponents: ["photos", "debug"],
            onTapIndex: { _ in },
            onTapRoot: { }
        )

        Spacer()
    }
}
