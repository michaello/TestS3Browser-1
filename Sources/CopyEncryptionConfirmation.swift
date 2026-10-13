import SwiftUI

@MainActor
struct CopyEncryptionPrompt: Identifiable {
    let id = UUID()
    let requirement: CopyEncryptionRequirement
    let resume: @MainActor (CopyEncryptionDecision) -> Void
}

private struct CopyEncryptionConfirmationSheet: View {
    let prompt: CopyEncryptionPrompt
    let dismiss: () -> Void
    @State private var context = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("KMS Encryption Context") {
                    Text("S3 does not return the original additional encryption context for this object. Supply it to retain the same KMS permission conditions.")
                    Text(prompt.requirement.request.source.bucket + "/" + prompt.requirement.request.source.key)
                        .font(.caption).textSelection(.enabled)
                    TextEditor(text: $context)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 120)
                        .accessibilityLabel("Original encryption context as JSON or base64")
                    if let validationError { Text(validationError).foregroundStyle(.red) }
                    Button("Use Supplied Context") {
                        do {
                            let validated = try ValidatedCopyEncryptionContext(text: context)
                            dismiss()
                            prompt.resume(.supplied(prompt.requirement, validated))
                        } catch { validationError = error.localizedDescription }
                    }
                }
                Section {
                    Text(CopyEncryptionRequirement.defaultDisclosure)
                    Button("Use Default Context", role: .destructive) {
                        dismiss()
                        prompt.resume(.useDefault(prompt.requirement))
                    }
                }
            }
            .navigationTitle("Copy Encryption")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss) } }
        }
    }
}

extension View {
    func copyEncryptionConfirmation(prompt: Binding<CopyEncryptionPrompt?>) -> some View {
        sheet(item: prompt) { pending in
            CopyEncryptionConfirmationSheet(prompt: pending, dismiss: { prompt.wrappedValue = nil })
        }
    }
}
