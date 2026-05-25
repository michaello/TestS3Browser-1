import SwiftUI
import os.log

/// Tab identifiers for navigation
enum AppTab: String, CaseIterable {
    case browse
    case recent
    case stash
    case upload
    case settings

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .recent: return "Recent"
        case .stash: return "Stash"
        case .upload: return "Upload"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .browse: return "folder"
        case .recent: return "clock"
        case .stash: return "doc.richtext"
        case .upload: return "square.and.arrow.up"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "ContentView")
    @Binding var config: S3Config
    @State private var s3Service: S3Service
    @AppStorage("lastSelectedTab") private var lastSelectedTabRaw: String = AppTab.browse.rawValue
    @State private var selectedTab: AppTab = .browse
    @State private var isDropTargeted = false
    @State private var uploadToast: UploadToast?

    enum UploadToast: Identifiable {
        case uploading
        case success(String)
        case failure(String)

        var id: String {
            switch self {
            case .uploading: return "uploading"
            case .success(let key): return "success-\(key)"
            case .failure(let msg): return "failure-\(msg)"
            }
        }
    }

    init(config: Binding<S3Config>) {
        self._config = config
        self._s3Service = State(initialValue: S3Service(config: config.wrappedValue))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Content area
                Group {
                    switch selectedTab {
                    case .browse:
                        BucketBrowserView(s3Service: s3Service, config: $config)
                    case .recent:
                        RecentFilesView(config: config, s3Service: s3Service)
                    case .stash:
                        StashView(s3Service: s3Service)
                    case .upload:
                        DumpFilesView(s3Service: s3Service)
                    case .settings:
                        SettingsView(config: $config)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Custom tab bar with context menu support
                CustomTabBar(selectedTab: $selectedTab)
            }

            // Drop overlay when dragging
            if isDropTargeted {
                dropOverlay
            }

            // Upload toast
            if let toast = uploadToast {
                uploadToastView(toast)
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first else { return false }
            Task {
                await handleDroppedImage(data)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onAppear {
            // Restore last selected tab on launch
            if let savedTab = AppTab(rawValue: lastSelectedTabRaw) {
                selectedTab = savedTab
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Persist tab selection
            lastSelectedTabRaw = newTab.rawValue
        }
        .onChange(of: config) { _, newConfig in
            Task {
                try? await s3Service.updateConfig(newConfig)
            }
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white)

                Text("Drop to Upload")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
        }
    }

    @ViewBuilder
    private func uploadToastView(_ toast: UploadToast) -> some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                switch toast {
                case .uploading:
                    ProgressView()
                        .tint(.white)
                    Text("Uploading...")
                        .foregroundStyle(.white)
                case .success(let key):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Uploaded: \(key.split(separator: "/").last ?? "")")
                        .foregroundStyle(.white)
                        .lineLimit(1)
                case .failure(let msg):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Failed: \(msg)")
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .padding()
            .background(Color(.systemGray))
            .cornerRadius(12)
            .padding()
            .padding(.bottom, 60)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut, value: uploadToast?.id)
    }

    private func handleDroppedImage(_ data: Data) async {
        await MainActor.run {
            uploadToast = .uploading
        }

        do {
            // Convert to JPEG
            let jpegData: Data
            if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
                jpegData = jpeg
            } else {
                jpegData = data
            }

            let key = try await s3Service.uploadToDump(imageData: jpegData)
            logger.info("Uploaded dropped image to \(key)")

            await MainActor.run {
                uploadToast = .success(key)
            }

            // Auto-dismiss after 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if case .success = uploadToast {
                    uploadToast = nil
                }
            }
        } catch {
            logger.error("Drop upload failed: \(error.localizedDescription)")
            await MainActor.run {
                uploadToast = .failure(error.localizedDescription)
            }

            // Auto-dismiss after 5 seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if case .failure = uploadToast {
                    uploadToast = nil
                }
            }
        }
    }
}

/// Custom tab bar that supports context menus on long press
struct CustomTabBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                TabBarButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    onTap: { selectedTab = tab },
                    onSelectTab: { selectedTab = $0 }
                )
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(.systemBackground))
    }
}

/// Individual tab bar button with context menu
struct TabBarButton: View {
    let tab: AppTab
    let isSelected: Bool
    let onTap: () -> Void
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 22))
                Text(tab.title)
                    .font(.caption2)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
        }
        .contextMenu {
            ForEach(AppTab.allCases, id: \.self) { menuTab in
                Button {
                    onSelectTab(menuTab)
                } label: {
                    Label(menuTab.title, systemImage: menuTab.icon)
                }
            }
        }
    }
}

#Preview {
    ContentView(config: .constant(S3Config.default))
}
