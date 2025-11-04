import SwiftUI

struct ContentView: View {
    @Binding var config: S3Config
    @State private var s3Service: S3Service

    init(config: Binding<S3Config>) {
        self._config = config
        self._s3Service = State(initialValue: S3Service(config: config.wrappedValue))
    }

    var body: some View {
        TabView {
            BucketBrowserView(s3Service: s3Service, config: $config)
                .tabItem {
                    Label("Browse", systemImage: "folder")
                }

            RecentFilesView(config: config, s3Service: s3Service)
                .tabItem {
                    Label("Recent", systemImage: "clock")
                }

            SettingsView(config: $config)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .onChange(of: config) { _, newConfig in
            Task {
                try? await s3Service.updateConfig(newConfig)
            }
        }
    }
}

#Preview {
    ContentView(config: .constant(S3Config.default))
}
