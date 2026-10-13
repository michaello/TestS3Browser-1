import SwiftUI

private struct ObjectTransferConfirmation: ViewModifier {
    @Binding var conflict: ObjectTransferConflict?
    let onConfirm: @MainActor (ObjectTransferRequest, ObjectReplacementApproval?) async -> Void

    func body(content: Content) -> some View {
        content.alert("Replace existing file?", isPresented: Binding(
            get: { conflict != nil },
            set: { if !$0 { conflict = nil } }
        ), presenting: conflict) { pending in
            Button("Replace", role: .destructive) {
                conflict = nil
                Task { await onConfirm(pending.request, pending.approval) }
            }
            Button("Keep Both") {
                conflict = nil
                Task { await onConfirm(pending.request.keepingBoth(), nil) }
            }
            Button("Cancel", role: .cancel) { conflict = nil }
        } message: { pending in
            Text("A file exists at \(pending.request.destination.bucket)/\(pending.request.destination.key). Replace it, save under a new name, or cancel. S3 checks the destination before copying but cannot reserve it against other writers.")
        }
    }
}

extension View {
    func objectTransferConfirmation(conflict: Binding<ObjectTransferConflict?>,
        onConfirm: @escaping @MainActor (ObjectTransferRequest, ObjectReplacementApproval?) async -> Void) -> some View {
        modifier(ObjectTransferConfirmation(conflict: conflict, onConfirm: onConfirm))
    }
}
