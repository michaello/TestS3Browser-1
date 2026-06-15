import SwiftUI

/// Shared "Delete Failed" alert used by views that delete S3 objects (RecentFilesView,
/// StashView). Each view keeps its own bool + message state and sets them in the catch
/// block of its delete method, then attaches this modifier so the alert markup lives in
/// one place instead of being copied per view.
private struct DeleteErrorAlert: ViewModifier {
    @Binding var isPresented: Bool
    let message: String

    func body(content: Content) -> some View {
        content.alert(isPresented: $isPresented) {
            Alert(
                title: Text("Delete Failed"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

extension View {
    /// Presents the shared delete-failure alert when `isPresented` is true.
    /// - Parameters:
    ///   - isPresented: Binding flipped to true in a delete method's catch block.
    ///   - message: The failure detail to show in the alert body.
    func deleteErrorAlert(isPresented: Binding<Bool>, message: String) -> some View {
        modifier(DeleteErrorAlert(isPresented: isPresented, message: message))
    }
}
