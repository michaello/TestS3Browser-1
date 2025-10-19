import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("globeImage")
            
            Text("Hello, SwiftUI!")
                .font(.largeTitle)
                .padding()
                .accessibilityIdentifier("welcomeText")
            
            Button("Get Started") {
                // Action
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("getStartedButton")
        }
        .padding()
        .accessibilityIdentifier("mainView")
    }
}

#Preview {
    ContentView()
}
