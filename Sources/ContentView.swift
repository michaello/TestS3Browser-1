import SwiftUI
import os.log

struct ContentView: View {
    private let logger = Logger(subsystem: "com.s3browser", category: "ContentView")
    @Binding var config: S3Config
    @State private var s3Service: S3Service
    @AppStorage("lastSelectedTab") private var lastSelectedTabRaw: String = AppTab.browse.rawValue
    @State private var tabState: AppTabState
    private var selectedTab: AppTab {
        get { tabState.selected }
        nonmutating set { tabState.select(newValue) }
    }
    @State private var isDropTargeted = false
    @State private var uploadToast: UploadToast?
    @State private var showBucketSwitcher = false
    @State private var showUploadQueue = false
    @State private var queueManager = UploadQueueManager.shared

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

    init(config: Binding<S3Config>, service: S3Service? = nil) {
        self._config = config
        self._s3Service = State(initialValue: service ?? S3Service(config: config.wrappedValue))
        let preferences = service?.snapshotDefaults ?? .standard
        let initial = AuditAppFixture.isEnabled ? AppTab.recent : AppTab(rawValue: preferences.string(forKey: "lastSelectedTab") ?? "") ?? .browse
        self._tabState = State(initialValue: AppTabState(initial: initial))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Content area
                ZStack {
                    ForEach(tabState.retainedTabs, id: \.self) { tab in
                        tabContent(tab)
                            .opacity(selectedTab == tab ? 1 : 0)
                            .allowsHitTesting(selectedTab == tab)
                            .accessibilityHidden(selectedTab != tab)
                            .zIndex(selectedTab == tab ? 1 : 0)
                    }
                }
                .id(s3Service.session.generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Custom tab bar with context menu support
                CustomTabBar(selectedTab: Binding(get: { selectedTab }, set: { selectedTab = $0 }))
            }

            // Drop overlay when dragging
            if isDropTargeted {
                dropOverlay
            }

            // Upload toast
            if let toast = uploadToast {
                uploadToastView(toast)
            }

            // Bucket switcher trigger pill — only shown when multiple buckets exist
            if s3Service.availableBuckets.count > 1 && !showBucketSwitcher {
                VStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showBucketSwitcher = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cylinder.split.1x2")
                                .font(.caption)
                            Text(s3Service.currentBucket)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.bar, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
                    }
                    .padding(.bottom, 56) // sit just above the custom tab bar
                }
            }

            // Upload queue badge button — top-trailing, visible when queue is busy or has failures
            if queueManager.busyCount > 0 || queueManager.failedCount > 0 {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showUploadQueue = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(queueManager.failedCount > 0 ? .red : .accentColor)
                                    .padding(8)
                                    .background(.bar, in: Circle())

                                let badge = queueManager.failedCount > 0
                                    ? queueManager.failedCount
                                    : queueManager.busyCount
                                Text("\(badge)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(queueManager.failedCount > 0 ? Color.red : Color.accentColor, in: Circle())
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: queueManager.busyCount + queueManager.failedCount)
            }

            // Bucket switcher overlay
            if showBucketSwitcher {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showBucketSwitcher = false
                        }
                    }

                VStack {
                    Spacer()
                    BucketSwitcherOverlay(
                        s3Service: s3Service,
                        onSelect: { bucket in
                            showBucketSwitcher = false
                            selectedTab = .browse
                            Task {
                                try? await s3Service.switchBucket(bucket)
                            }
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showBucketSwitcher = false
                            }
                        }
                    )
                    .frame(maxHeight: 420)
                    .padding(.bottom, 84) // clear the custom tab bar
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            guard !items.isEmpty else { return false }
            let context = UploadContext(service: s3Service, prefix: "dump/")
            Task { await handleDroppedImages(items, context: context) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .sheet(isPresented: $showUploadQueue) {
            UploadQueueSheet()
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            // Restore last selected tab on launch
            if AuditAppFixture.isEnabled {
                selectedTab = .recent
            } else if let savedTab = AppTab(rawValue: lastSelectedTabRaw) {
                selectedTab = savedTab
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Persist tab selection
            if !AuditAppFixture.isEnabled { lastSelectedTabRaw = newTab.rawValue }
        }
        .onChange(of: s3Service.session.generation) { _, _ in tabState.resetForConfiguration() }
        .task(id: config) {
            do { try await s3Service.updateConfig(config) }
            catch is CancellationError {}
            catch { logger.error("Configuration apply failed: \(error.localizedDescription)") }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .browse: BucketBrowserView(s3Service: s3Service, config: $config)
        case .apps: ScreensDesignAppsView(s3Service: s3Service)
        case .recent: RecentFilesView(config: config, s3Service: s3Service)
        case .stash: StashView(s3Service: s3Service)
        case .stats: StatsView(s3Service: s3Service)
        case .upload: DumpFilesView(s3Service: s3Service)
        case .settings: SettingsView(config: $config, service: s3Service)
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

    private func handleDroppedImages(_ items: [Data], context: UploadContext) async {
        uploadToast = .uploading
        let outcome = await ImageDropBatch.process(items) { image in
            try await s3Service.uploadToDump(imageData: image.data, bucket: context.destination.bucket,
                expectedConfig: context.configuration, expectedGeneration: context.generation)
        }
        uploadToast = outcome.failures.isEmpty ? .success(outcome.summary) : .failure(outcome.summary)
        do { try await Task.sleep(for: .seconds(outcome.failures.isEmpty ? 3 : 5)) }
        catch { return }
        uploadToast = nil
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
