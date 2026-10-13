import Foundation

/// Captures credentials in memory only. A later account change cancels before mutation.
@MainActor
struct UploadContext {
    let configuration: S3Config
    let destination: UploadDestination
    let generation: UUID

    init(service: S3Service, bucket: String? = nil, prefix: String? = nil) {
        self.init(configuration: service.config, bucket: bucket ?? service.currentBucket,
                  prefix: prefix ?? service.currentPrefix, generation: service.session.generation)
    }

    init(configuration: S3Config, bucket: String, prefix: String, generation: UUID) {
        self.configuration = configuration
        self.generation = generation
        destination = UploadDestination(
            account: S3AccountScope.identifier(region: configuration.region, accessKey: configuration.accessKey),
            bucket: bucket, prefix: prefix
        )
    }

    func matches(_ service: S3Service) -> Bool {
        configuration == service.config && generation == service.session.generation
    }
}
