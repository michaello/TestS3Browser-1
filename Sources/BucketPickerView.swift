import SwiftUI

/// Displays a bucket picker in the toolbar
struct BucketPickerView: View {
    let currentBucket: String
    let availableBuckets: [String]
    let isLoading: Bool
    let onSelectBucket: (String) -> Void

    /// Debounced loading state - only shows spinner after delay to prevent flicker
    @State private var showSpinner = false
    @State private var spinnerTask: Task<Void, Never>?

    private let spinnerDelay: UInt64 = 300_000_000 // 300ms

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
                if showSpinner {
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
        .onChange(of: isLoading) { _, loading in
            if loading {
                // Start debounce timer - only show spinner after delay
                spinnerTask?.cancel()
                spinnerTask = Task {
                    try? await Task.sleep(nanoseconds: spinnerDelay)
                    if !Task.isCancelled {
                        showSpinner = true
                    }
                }
            } else {
                // Loading finished - immediately hide spinner
                spinnerTask?.cancel()
                spinnerTask = nil
                showSpinner = false
            }
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
