import Foundation

@MainActor
struct ShareAttachmentSource {
    let name: String
    let load: () async throws -> PreparedUploadPayload
}

struct ShareAttachmentReport: Sendable {
    enum Status: Sendable { case uploaded(String), failed(String), cancelled }
    struct Outcome: Sendable { let index: Int; let name: String; let status: Status }
    let attempted: Int
    var outcomes: [Outcome] = []
    var keys: [String] { outcomes.compactMap { if case .uploaded(let key) = $0.status { return key }; return nil } }
    var failed: Int { outcomes.filter { if case .failed = $0.status { return true }; return false }.count }
    var cancelled: Int { outcomes.filter { if case .cancelled = $0.status { return true }; return false }.count }
    var summary: String {
        var text = "Uploaded \(keys.count) of \(attempted) attachments. Failed: \(failed). Cancelled: \(cancelled)."
        let errors = outcomes.compactMap { outcome -> String? in
            if case .failed(let message) = outcome.status { return "\(outcome.index + 1). \(outcome.name): \(message)" }
            return nil
        }
        if !errors.isEmpty { text += "\n" + errors.joined(separator: "\n") }
        if cancelled > 0 { text += "\nPending work stopped. An in-flight upload may already have completed." }
        return text
    }
}

@MainActor
enum ShareAttachmentPipeline {
    /// One owned representation is loaded, sent and released before loading the next.
    static func process(_ sources: [ShareAttachmentSource],
                        progress: (Int, Int) -> Void = { _, _ in },
                        upload: (PreparedUploadPayload) async throws -> String) async -> ShareAttachmentReport {
        var report = ShareAttachmentReport(attempted: sources.count)
        for (index, source) in sources.enumerated() {
            let status: ShareAttachmentReport.Status
            if Task.isCancelled { status = .cancelled }
            else {
                progress(index + 1, sources.count)
                do {
                    let payload = try await source.load()
                    defer { payload.cleanInputFile() }
                    try Task.checkCancellation()
                    guard case .file = payload.body else { throw UploadPreparationError.unavailableRepresentation }
                    status = .uploaded(try await upload(payload))
                } catch is CancellationError { status = .cancelled }
                catch { status = Task.isCancelled ? .cancelled : .failed(error.localizedDescription) }
            }
            report.outcomes.append(.init(index: index, name: source.name, status: status))
        }
        return report
    }
}
