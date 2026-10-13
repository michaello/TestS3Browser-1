import SwiftUI

struct SettingsView: View {
    @Binding var config: S3Config
    @State private var configurationDraft: ConfigurationDraft<S3Config>
    let service: S3Service?
    @State private var fallbackService: S3Service?
    @State private var configurationSaveError: String?
    @State private var isTesting = false
    @State private var testStatus = ""
    @AppStorage("autoPreviewNewPhotos") private var autoPreviewNewPhotos = false
    @State private var starStore = StarStore.shared
    @State private var tagStore = TagStore.shared
    @State private var diskCacheBytes: Int64 = 0
    @State private var confirmClearCache = false
    @State private var confirmClearStars = false
    @State private var confirmClearTags = false
    @State private var policyExpanded = false
    @State private var lifecycleExpanded = false
    @State private var corsExpanded = false
    @State private var replicationExpanded = false
    @State private var metricsExpanded = false

    init(config: Binding<S3Config>, service: S3Service? = nil) {
        _config = config
        self.service = service
        _configurationDraft = State(initialValue: ConfigurationDraft(applied: config.wrappedValue))
    }

    private var admin: BucketAdministrationCache? { service?.administration ?? fallbackService?.administration }
    private var policyJSON: String? {
        guard let raw = admin?.policy.value(for: administrationIdentity) ?? nil else { return nil }
        if let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: pretty, encoding: .utf8)
        }
        return raw
    }
    private var isPolicyLoading: Bool { admin?.policy.isLoading(administrationIdentity) ?? false }
    private var lifecycleRules: [LifecycleRuleDisplay] { admin?.lifecycle.value(for: administrationIdentity) ?? [] }
    private var isLifecycleLoading: Bool { admin?.lifecycle.isLoading(administrationIdentity) ?? false }
    private var lifecycleLoaded: Bool { admin?.lifecycle.hasLoaded(administrationIdentity) ?? false }
    private var corsRules: [CORSRuleDisplay] { admin?.cors.value(for: administrationIdentity) ?? [] }
    private var isCORSLoading: Bool { admin?.cors.isLoading(administrationIdentity) ?? false }
    private var corsLoaded: Bool { admin?.cors.hasLoaded(administrationIdentity) ?? false }
    private var replicationRules: [ReplicationRuleDisplay] { admin?.replication.value(for: administrationIdentity) ?? [] }
    private var isReplicationLoading: Bool { admin?.replication.isLoading(administrationIdentity) ?? false }
    private var replicationLoaded: Bool { admin?.replication.hasLoaded(administrationIdentity) ?? false }
    private var metrics: [BucketMetric] { admin?.metrics.value(for: administrationIdentity) ?? [] }
    private var isMetricsLoading: Bool { admin?.metrics.isLoading(administrationIdentity) ?? false }
    private var metricsLoaded: Bool { admin?.metrics.hasLoaded(administrationIdentity) ?? false }
    private var metricsError: String? { admin?.metrics.error(for: administrationIdentity) }

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
                    TextField("Bucket Name", text: $configurationDraft.value.bucketName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Region", text: $configurationDraft.value.region)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Prefix (optional)", text: $configurationDraft.value.prefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Example: clarityvoice-logs/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AWS Credentials") {
                    TextField("Access Key", text: $configurationDraft.value.accessKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)

                    SecureField("Secret Key", text: $configurationDraft.value.secretKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)

                    Text("IAM credentials with S3 read permissions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Apply Configuration") {
                        do {
                            try configurationDraft.apply { replacement in
                                if !AuditAppFixture.isEnabled { try SharedConfig.saveConfig(replacement) }
                                config = replacement
                                guard config == replacement else { throw SecureConfigurationError.preferenceWriteNotVerified }
                            }
                            configurationSaveError = nil
                        } catch { configurationSaveError = error.localizedDescription }
                    }
                    .disabled(configurationDraft.value == config || !isDraftValid)

                    Button("Discard Changes") { configurationDraft.discard(); configurationSaveError = nil }
                        .disabled(configurationDraft.value == config)

                    if let configurationSaveError {
                        Text(configurationSaveError).font(.caption).foregroundStyle(.red)
                    }

                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || !isDraftValid)

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

                Section {
                    DisclosureGroup("Bucket Policy", isExpanded: $policyExpanded) {
                        if isPolicyLoading {
                            HStack {
                                ProgressView()
                                Text("Loading policy...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = admin?.policy.error(for: administrationIdentity) {
                            Text("Unable to load policy: \(error)").foregroundStyle(.red)
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
                            Task { await loadBucketPolicy(force: true) }
                        }
                        .disabled(isPolicyLoading || !isConfigValid)
                    }
                    .task(id: AdministrationLoadRequest(identity: administrationIdentity, expanded: policyExpanded)) {
                        await loadBucketPolicy()
                    }
                }

                Section {
                    DisclosureGroup("Lifecycle Rules", isExpanded: $lifecycleExpanded) {
                        if isLifecycleLoading {
                            HStack {
                                ProgressView()
                                Text("Loading rules...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = admin?.lifecycle.error(for: administrationIdentity) {
                            Text("Unable to load lifecycle rules: \(error)").foregroundStyle(.red)
                        } else if lifecycleLoaded && lifecycleRules.isEmpty {
                            Text("No lifecycle rules configured")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(lifecycleRules) { rule in
                                DisclosureGroup {
                                    if let expiration = rule.expirationDescription {
                                        LabeledContent("Expiration", value: expiration)
                                    }
                                    ForEach(rule.transitions) { t in
                                        LabeledContent(
                                            "Transition: \(t.scheduleDescription)",
                                            value: t.storageClass
                                        )
                                    }
                                    ForEach(rule.additionalActions, id: \.self) { action in
                                        Text(action).font(.caption)
                                    }
                                    if rule.expirationDescription == nil && rule.transitions.isEmpty && rule.additionalActions.isEmpty {
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
                            Task { await loadLifecycleRules(force: true) }
                        }
                        .disabled(isLifecycleLoading || !isConfigValid)
                    }
                    .task(id: AdministrationLoadRequest(identity: administrationIdentity, expanded: lifecycleExpanded)) {
                        await loadLifecycleRules()
                    }
                }

                Section {
                    DisclosureGroup("CORS Rules", isExpanded: $corsExpanded) {
                        if isCORSLoading {
                            HStack {
                                ProgressView()
                                Text("Loading CORS rules...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = admin?.cors.error(for: administrationIdentity) {
                            Text("Unable to load CORS rules: \(error)").foregroundStyle(.red)
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
                            Task { await loadCORSRules(force: true) }
                        }
                        .disabled(isCORSLoading || !isConfigValid)
                    }
                    .task(id: AdministrationLoadRequest(identity: administrationIdentity, expanded: corsExpanded)) {
                        await loadCORSRules()
                    }
                }

                Section {
                    DisclosureGroup("Replication Rules", isExpanded: $replicationExpanded) {
                        if isReplicationLoading {
                            HStack {
                                ProgressView()
                                Text("Loading replication rules...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = admin?.replication.error(for: administrationIdentity) {
                            Text("Unable to load replication rules: \(error)").foregroundStyle(.red)
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
                            Task { await loadReplicationRules(force: true) }
                        }
                        .disabled(isReplicationLoading || !isConfigValid)
                    }
                    .task(id: AdministrationLoadRequest(identity: administrationIdentity, expanded: replicationExpanded)) {
                        await loadReplicationRules()
                    }
                }

                Section {
                    DisclosureGroup("CloudWatch Metrics", isExpanded: $metricsExpanded) {
                        if isMetricsLoading {
                            HStack {
                                ProgressView()
                                Text("Loading metrics...")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let metricsError {
                            Text("Unable to load metrics: \(metricsError)")
                                .foregroundStyle(.red)
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
                            Task { await loadMetrics(force: true) }
                        }
                        .disabled(isMetricsLoading || !isConfigValid)
                    }
                    .task(id: AdministrationLoadRequest(identity: administrationIdentity, expanded: metricsExpanded)) {
                        await loadMetrics()
                    }
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
                            .disabled(starStore.starredKeys.isEmpty && starStore.legacyCount == 0)
                    }

                    HStack {
                        Label("Tagged Files", systemImage: "tag")
                        Spacer()
                        Text("\(tagStore.tags.count)")
                            .foregroundStyle(.secondary)
                        Button("Clear") { confirmClearTags = true }
                            .buttonStyle(.bordered)
                            .disabled(tagStore.tags.isEmpty && tagStore.legacyCount == 0)
                    }
                    if starStore.legacyCount > 0 || tagStore.legacyCount > 0 {
                        Text("Unassigned legacy labels retained: \(starStore.legacyCount) stars, \(tagStore.legacyCount) tags. Their original account and bucket are unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = starStore.storageError ?? tagStore.storageError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: config) { _, applied in configurationDraft.receiveApplied(applied) }
            .task { await loadCacheSize() }

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

    private var administrationIdentity: AdministrationIdentity {
        AdministrationIdentity(configuration: S3Service.sessionConfiguration(config))
    }

    private func configuredAdministrationService(for applied: S3Config) async throws -> S3Service {
        let configured: S3Service
        if let service { configured = service }
        else if let fallbackService { configured = fallbackService }
        else {
            configured = S3Service(config: applied)
            fallbackService = configured
        }
        if configured.config != applied { try await configured.updateConfig(applied) }
        return configured
    }

    private func loadReplicationRules(force: Bool = false) async {
        let applied = config
        let identity = administrationIdentity
        admin?.replication.activate(identity)
        guard isConfigValid, replicationExpanded || force else { return }
        do {
            let service = try await configuredAdministrationService(for: applied)
            guard !Task.isCancelled, service.session.configuration == S3Service.sessionConfiguration(applied) else { return }
            let generation = service.session.generation
            await service.administration.replication.load(identity, expanded: replicationExpanded || force, force: force) {
                guard service.session.isCurrent(generation) else { throw CancellationError() }
                return try await service.fetchReplicationRules(bucket: identity.bucket)
            }
        } catch { configurationSaveError = error.localizedDescription }
    }

    private func loadMetrics(force: Bool = false) async {
        let applied = config
        let identity = administrationIdentity
        admin?.metrics.activate(identity)
        guard isConfigValid, metricsExpanded || force else { return }
        do {
            let service = try await configuredAdministrationService(for: applied)
            guard !Task.isCancelled, service.session.configuration == S3Service.sessionConfiguration(applied) else { return }
            let generation = service.session.generation
            await service.administration.metrics.load(identity, expanded: metricsExpanded || force, force: force) {
                guard service.session.isCurrent(generation) else { throw CancellationError() }
                return try await service.fetchBucketMetrics(bucket: identity.bucket)
            }
        } catch { configurationSaveError = error.localizedDescription }
    }

    private func loadCORSRules(force: Bool = false) async {
        let applied = config
        let identity = administrationIdentity
        admin?.cors.activate(identity)
        guard isConfigValid, corsExpanded || force else { return }
        do {
            let service = try await configuredAdministrationService(for: applied)
            guard !Task.isCancelled, service.session.configuration == S3Service.sessionConfiguration(applied) else { return }
            let generation = service.session.generation
            await service.administration.cors.load(identity, expanded: corsExpanded || force, force: force) {
                guard service.session.isCurrent(generation) else { throw CancellationError() }
                return try await service.fetchCORSRules(bucket: identity.bucket)
            }
        } catch { configurationSaveError = error.localizedDescription }
    }

    private func loadLifecycleRules(force: Bool = false) async {
        let applied = config
        let identity = administrationIdentity
        admin?.lifecycle.activate(identity)
        guard isConfigValid, lifecycleExpanded || force else { return }
        do {
            let service = try await configuredAdministrationService(for: applied)
            guard !Task.isCancelled, service.session.configuration == S3Service.sessionConfiguration(applied) else { return }
            let generation = service.session.generation
            await service.administration.lifecycle.load(identity, expanded: lifecycleExpanded || force, force: force) {
                guard service.session.isCurrent(generation) else { throw CancellationError() }
                return try await service.fetchLifecycleRules(bucket: identity.bucket)
            }
        } catch { configurationSaveError = error.localizedDescription }
    }

    private func loadBucketPolicy(force: Bool = false) async {
        let applied = config
        let identity = administrationIdentity
        admin?.policy.activate(identity)
        guard isConfigValid, policyExpanded || force else { return }
        do {
            let service = try await configuredAdministrationService(for: applied)
            guard !Task.isCancelled, service.session.configuration == S3Service.sessionConfiguration(applied) else { return }
            let generation = service.session.generation
            await service.administration.policy.load(identity, expanded: policyExpanded || force, force: force) {
                guard service.session.isCurrent(generation) else { throw CancellationError() }
                return try await service.fetchBucketPolicy(bucket: identity.bucket)
            }
        } catch { configurationSaveError = error.localizedDescription }
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
        let tested = configurationDraft.value
        isTesting = true
        testStatus = "Testing connection..."

        Task {
            do {
                let service = S3Service(config: tested)
                try await service.updateConfig(tested)
                try await service.listObjects()
                testStatus = "✓ Connection successful"
            } catch {
                testStatus = "✗ Failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private var isDraftValid: Bool {
        !configurationDraft.value.bucketName.isEmpty && !configurationDraft.value.region.isEmpty && !configurationDraft.value.accessKey.isEmpty && !configurationDraft.value.secretKey.isEmpty
    }
}

#Preview {
    SettingsView(config: .constant(S3Config.default))
}

@MainActor
final class BucketAdministrationCache {
    let policy = AdministrationSection<String?>()
    let lifecycle = AdministrationSection<[LifecycleRuleDisplay]>()
    let cors = AdministrationSection<[CORSRuleDisplay]>()
    let replication = AdministrationSection<[ReplicationRuleDisplay]>()
    let metrics = AdministrationSection<[BucketMetric]>()
}
