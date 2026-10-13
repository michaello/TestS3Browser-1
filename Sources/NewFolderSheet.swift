import SwiftUI

struct NewFolderSheet: View {
    let service: S3Service
    let context: UploadContext
    let onCreated: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var state = FolderCreationState()
    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $state.name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(state.mutation.isRunning)
                if let error = state.mutation.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("folder.validation-error")
                }
            }
            .navigationTitle("New Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(state.mutation.isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            let created = await state.create(prefix: context.destination.prefix) { name in
                                guard context.matches(service) else { throw UploadPreparationError.accountChanged }
                                try await service.createFolder(named: name, prefix: context.destination.prefix,
                                    bucket: context.destination.bucket, expectedGeneration: context.generation)
                            }
                            if created { await onCreated(); dismiss() }
                        }
                    }.disabled(state.mutation.isRunning)
                }
            }
            .interactiveDismissDisabled(state.mutation.isRunning)
        }
    }
}
