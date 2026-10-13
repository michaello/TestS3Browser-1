import SwiftUI

@main
struct TestS3BrowserApp: App {
    @State private var config: S3Config
    @State private var configurationStorageError: String?
    @State private var configurationReady: Bool
    @State private var showCredentialRecovery = false
    @State private var fixtureService: S3Service?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = AuditTelemetry.shared
        if AuditAppFixture.isEnabled {
            _config = State(initialValue: AuditAppFixture.config)
            _fixtureService = State(initialValue: AuditAppFixture.service())
            _configurationStorageError = State(initialValue: nil)
            _configurationReady = State(initialValue: true)
            return
        }
        // Resolve saved credentials before ContentView creates its service or starts requests.
        do {
            _config = State(initialValue: try SharedConfig.loadAndMigrateConfig() ?? .default)
            _configurationStorageError = State(initialValue: nil)
            _configurationReady = State(initialValue: true)
        } catch {
            _config = State(initialValue: .default)
            _configurationStorageError = State(initialValue: error.localizedDescription)
            _configurationReady = State(initialValue: false)
        }
        _fixtureService = State(initialValue: nil)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if configurationReady {
                    ContentView(config: savedConfig, service: fixtureService)
                } else {
                    ContentUnavailableView {
                        Label("Configuration Unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                    } description: {
                        Text(configurationStorageError ?? "Retry loading your saved configuration.")
                    } actions: {
                        Button("Retry", action: restoreConfiguration)
                        Button("Re-enter Configuration") { showCredentialRecovery = true }
                    }
                }
            }
                .defaultAppStorage(fixtureService?.snapshotDefaults ?? .standard)
                .task {
                    AppPerformanceMonitor.shared.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AppPerformanceMonitor.shared.start() }
                    else { AppPerformanceMonitor.shared.stop() }
                }
                .alert("Configuration Storage", isPresented: Binding(
                    get: { configurationReady && configurationStorageError != nil },
                    set: { if !$0 { configurationStorageError = nil } }
                )) {
                    Button("Retry", action: restoreConfiguration)
                    Button("Dismiss", role: .cancel) { configurationStorageError = nil }
                } message: { Text(configurationStorageError ?? "") }
                .sheet(isPresented: $showCredentialRecovery) {
                    SettingsView(config: savedConfig)
                }
        }
    }

    private var savedConfig: Binding<S3Config> {
        Binding(get: { config }, set: { replacement in
            do {
                if !AuditAppFixture.isEnabled { try SharedConfig.saveConfig(replacement) }
                config = replacement
                configurationReady = true
                configurationStorageError = nil
                showCredentialRecovery = false
            } catch { configurationStorageError = error.localizedDescription }
        })
    }

    private func restoreConfiguration() {
        if AuditAppFixture.isEnabled {
            config = AuditAppFixture.config
            configurationReady = true
            configurationStorageError = nil
            return
        }
        do {
            config = try SharedConfig.loadAndMigrateConfig() ?? .default
            configurationReady = true
            configurationStorageError = nil
        } catch { configurationStorageError = error.localizedDescription }
    }
}
