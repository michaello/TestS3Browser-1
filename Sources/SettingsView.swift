import SwiftUI

struct SettingsView: View {
    @Binding var config: S3Config
    @State private var isTesting = false
    @State private var testStatus = ""
    @AppStorage("autoPreviewNewPhotos") private var autoPreviewNewPhotos = false
    @State private var starStore = StarStore.shared
    @State private var tagStore = TagStore.shared
    @State private var diskCacheBytes: Int64 = 0
    @State private var confirmClearCache = false
    @State private var confirmClearStars = false
    @State private var confirmClearTags = false
    @State private var policyJSON: String? = nil
    @State private var isPolicyLoading = false
    @State private var lifecycleRules: [LifecycleRuleDisplay] = []
    @State private var isLifecycleLoading = false
    @State private var lifecycleLoaded = false
    @State private var corsRules: [CORSRuleDisplay] = []
    @State private var isCORSLoading = false
    @State private var corsLoaded = false
    @State private var replicationRules: [ReplicationRuleDisplay] = []
    @State private var isReplicationLoading = false
    @State private var replicationLoaded = false
    @State private var metrics: [BucketMetric] = []
    @State private var isMetricsLoading = false
    @State private var metricsLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Behavior") {
                    Toggle("Auto-preview new photos", isOn: $autoPreviewNewPhotos)

                    Text("Automatically open new photos when returning to the app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("S3 Bucket") {
                    TextField("Bucket Name", text: $config.bucketName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Region", text: $config.region)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Prefix (optional)", text: $config.prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Example: clarityvoice-logs/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AWS Credentials") {
                    TextField("Access Key", text: $config.accessKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)

                    SecureField("Secret Key", text: $config.secretKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)

                    Text("IAM credentials with S3 read permissions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || !isConfigValid)

                    if isTesting {
                        HStack {
                            ProgressView()
                            Text("Testing...")
                        }
                    }

                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundStyle(testStatus.hasPrefix("✓") ? .green : .red)
                    }
                }

                Section("Bucket Policy") {
                    if isPolicyLoading {
                        HStack {
                            ProgressView()
                            Text("Loading policy...")
                                .foregroundStyle(.secondary)
                        }
                    } else if let json = policyJSON {
                        ScrollView(.vertical) {
                            Text(json)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 260)
                    } else {
                        Text("No policy configured")
                            .foregroundStyle(.secondary)
                    }

                    Button("Refresh") {
                        Task { await loadBucketPolicy() }
                    }
                    .disabled(isPolicyLoading || !isConfigValid)
                }

                Section("Lifecycle Rules") {
                    if isLifecycleLoading {
                        HStack {
                            ProgressView()
                            Text("Loading rules...")
                                .foregroundStyle(.secondary)
                        }
                    } else if lifecycleLoaded && lifecycleRules.isEmpty {
                        Text("No lifecycle rules configured")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lifecycleRules) { rule in
                            DisclosureGroup {
                                if let days = rule.expirationDays {
                                    LabeledContent("Expiration", value: "\(days) day\(days == 1 ? "" : "s")")
                                }
                                ForEach(rule.transitions) { t in
                                    LabeledContent(
                                        "Transition\(t.days.map { " after \($0)d" } ?? "")",
                                        value: t.storageClass
                                    )
                                }
                                if rule.expirationDays == nil && rule.transitions.isEmpty {
                                    Text("No expiration or transitions")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            } label: {
                                HStack {
                                    Text(rule.id)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(rule.status)
                                        .font(.caption)
                                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                                }
                            }
                        }
                    }

                    Button("Refresh") {
                        Task { await loadLifecycleRules() }
                    }
                    .disabled(isLifecycleLoading || !isConfigValid)
                }

                Section("CORS Rules") {
                    if isCORSLoading {
                        HStack {
                            ProgressView()
                            Text("Loading CORS rules...")
                                .foregroundStyle(.secondary)
                        }
                    } else if corsLoaded && corsRules.isEmpty {
                        Text("No CORS rules configured")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(corsRules) { rule in
                            DisclosureGroup {
                                LabeledContent("Origins", value: rule.allowedOrigins.joined(separator: ", "))
                                LabeledContent("Methods", value: rule.allowedMethods.joined(separator: ", "))
                                if !rule.allowedHeaders.isEmpty {
                                    LabeledContent("Allow Headers", value: rule.allowedHeaders.joined(separator: ", "))
                                }
                                if !rule.exposeHeaders.isEmpty {
                                    LabeledContent("Expose Headers", value: rule.exposeHeaders.joined(separator: ", "))
                                }
                                if let age = rule.maxAgeSeconds {
                                    LabeledContent("Max Age", value: "\(age)s")
                                }
                            } label: {
                                Text(rule.id)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Button("Refresh") {
                        Task { await loadCORSRules() }
                    }
                    .disabled(isCORSLoading || !isConfigValid)
                }

                Section("Replication Rules") {
                    if isReplicationLoading {
                        HStack {
                            ProgressView()
                            Text("Loading replication rules...")
                                .foregroundStyle(.secondary)
                        }
                    } else if replicationLoaded && replicationRules.isEmpty {
                        Text("No replication configured")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(replicationRules) { rule in
                            DisclosureGroup {
                                LabeledContent("Destination", value: rule.destinationBucket)
                                if let sc = rule.storageClass {
                                    LabeledContent("Storage Class", value: sc)
                                }
                                if let p = rule.priority {
                                    LabeledContent("Priority", value: "\(p)")
                                }
                            } label: {
                                HStack {
                                    Text(rule.id)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(rule.status)
                                        .font(.caption)
                                        .foregroundStyle(rule.isEnabled ? .green : .secondary)
                                }
                            }
                        }
                    }

                    Button("Refresh") {
                        Task { await loadReplicationRules() }
                    }
                    .disabled(isReplicationLoading || !isConfigValid)
                }

                Section("CloudWatch Metrics") {
                    if isMetricsLoading {
                        HStack {
                            ProgressView()
                            Text("Loading metrics...")
                                .foregroundStyle(.secondary)
                        }
                    } else if metricsLoaded && metrics.isEmpty {
                        Text("No metrics configured")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(metrics) { metric in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(metric.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            Text(metric.value)
                                                .font(.body)
                                                .lineLimit(2)
                                            if !metric.unit.isEmpty {
                                                Text(metric.unit)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Divider()
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 260)
                    }

                    Button("Refresh") {
                        Task { await loadMetrics() }
                    }
                    .disabled(isMetricsLoading || !isConfigValid)
                }

                Section("Storage & Cache") {
                    HStack {
                        Label("Image Cache", systemImage: "photo.on.rectangle")
                        Spacer()
                        Text(formattedBytes(diskCacheBytes))
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearCache = true }
                            .buttonStyle(.bordered)
                            .disabled(diskCacheBytes == 0)
                    }

                    HStack {
                        Label("Starred Files", systemImage: "star")
                        Spacer()
                        Text("\(starStore.starredKeys.count)")
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearStars = true }
                            .buttonStyle(.bordered)
                            .disabled(starStore.starredKeys.isEmpty)
                    }

                    HStack {
                        Label("Tagged Files", systemImage: "tag")
                        Spacer()
                        Text("\(tagStore.tags.count)")
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearTags = true }
                            .buttonStyle(.bordered)
                            .disabled(tagStore.tags.isEmpty)
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await loadCacheSize() }
            .task(id: config.bucketName) { await loadBucketPolicy() }
            .task(id: config.bucketName) { await loadLifecycleRules() }
            .task(id: config.bucketName) { await loadCORSRules() }
            .task(id: config.bucketName) { await loadReplicationRules() }
            .task(id: config.bucketName) { await loadMetrics() }
            .confirmationDialog("Clear image cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await ImageCacheActor.shared.clearCache()
                        await loadCacheSize()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Thumbnails will be re-downloaded as you browse.")
            }
            .confirmationDialog("Remove all stars?", isPresented: $confirmClearStars, titleVisibility: .visible) {
                Button("Remove All Stars", role: .destructive) {
                    starStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove all tags?", isPresented: $confirmClearTags, titleVisibility: .visible) {
                Button("Remove All Tags", role: .destructive) {
                    tagStore.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func loadReplicationRules() async {
        guard isConfigValid else { return }
        isReplicationLoading = true
        replicationLoaded = false
        replicationRules = []
        let service = S3Service(config: config)
        replicationRules = await service.fetchReplicationRules(bucket: config.bucketName)
        replicationLoaded = true
        isReplicationLoading = false
    }

    private func loadMetrics() async {
        guard isConfigValid else { return }
        isMetricsLoading = true
        metricsLoaded = false
        metrics = []
        let service = S3Service(config: config)
        metrics = await service.fetchBucketMetrics(bucket: config.bucketName)
        metricsLoaded = true
        isMetricsLoading = false
    }

    private func loadCORSRules() async {
        guard isConfigValid else { return }
        isCORSLoading = true
        corsLoaded = false
        corsRules = []
        let service = S3Service(config: config)
        corsRules = await service.fetchCORSRules(bucket: config.bucketName)
        corsLoaded = true
        isCORSLoading = false
    }

    private func loadLifecycleRules() async {
        guard isConfigValid else { return }
        isLifecycleLoading = true
        lifecycleLoaded = false
        lifecycleRules = []
        let service = S3Service(config: config)
        lifecycleRules = await service.fetchLifecycleRules(bucket: config.bucketName)
        lifecycleLoaded = true
        isLifecycleLoading = false
    }

    private func loadBucketPolicy() async {
        guard isConfigValid else { return }
        isPolicyLoading = true
        policyJSON = nil
        let service = S3Service(config: config)
        let raw = await service.fetchBucketPolicy(bucket: config.bucketName)
        // Pretty-print if valid JSON, otherwise show raw string
        let pretty: String?
        if let raw,
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let prettyStr = String(data: prettyData, encoding: .utf8) {
            pretty = prettyStr
        } else {
            pretty = raw
        }
        policyJSON = pretty
        isPolicyLoading = false
    }

    private var isConfigValid: Bool {
        !config.bucketName.isEmpty && !config.accessKey.isEmpty && !config.secretKey.isEmpty && !config.region.isEmpty
    }

    private func loadCacheSize() async {
        let bytes = await ImageCacheActor.shared.diskCacheSize()
        await MainActor.run { diskCacheBytes = bytes }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "Empty" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    private func testConnection() {
        isTesting = true
        testStatus = "Testing connection..."

        Task {
            do {
                let service = S3Service(config: config)
                try await service.updateConfig(config)
                try await service.listObjects()
                testStatus = "✓ Connection successful"
            } catch {
                testStatus = "✗ Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

#Preview {
    SettingsView(config: .constant(S3Config.default))
}
