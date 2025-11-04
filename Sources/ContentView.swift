import SwiftUI

struct ContentView: View {
    @Binding var config: S3Config

    var body: some View {
        TabView {
            BucketBrowserView(config: $config)
                .tabItem {
                    Label("Files", systemImage: "folder")
                }

            SettingsView(config: $config)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}

#Preview {
    ContentView(config: .constant(S3Config.default))
}
