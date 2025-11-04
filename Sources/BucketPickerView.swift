import SwiftUI

/// Displays a bucket picker in the toolbar
struct BucketPickerView: View {
    let currentBucket: String
    let availableBuckets: [String]
    let isLoading: Bool
    let onSelectBucket: (String) -> Void

    var body: some View {
        Menu {
            ForEach(availableBuckets, id: \.self) { bucket in
                Button(action: {
                    if bucket != currentBucket {
                        onSelectBucket(bucket)
                    }
                }) {
                    HStack {
                        Text(bucket)
                        if bucket == currentBucket {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "cylinder.split.1x2")
                }
                Text(currentBucket)
                    .lineLimit(1)
                    .font(.caption)
            }
            .frame(maxWidth: 150)
        }
    }
}

#Preview {
    BucketPickerView(
        currentBucket: "my-bucket",
        availableBuckets: ["my-bucket", "test-bucket", "production-bucket"],
        isLoading: false,
        onSelectBucket: { _ in }
    )
}
