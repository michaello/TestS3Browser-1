import UIKit
import Social
import UniformTypeIdentifiers
import os.log
import AVFoundation
import WidgetKit

/// Share Extension view controller for uploading images and videos to S3 dump folder
class ShareViewController: UIViewController {
    private let logger = Logger(subsystem: "com.crispytoast.TestS3Browser.ShareExtension", category: "ShareVC")

    private var statusLabel: UITextView!
    private var progressView: UIActivityIndicatorView!
    private var iconView: UIImageView!
    private var containerView: UIView!
    private var sharedConfigLoadError: String?
    private var actionButton: UIButton!
    private var copyLinkButton: UIButton!
    private var linkLabel: UILabel!
    private var buttonStack: UIStackView!

    /// Stores the presigned URL after successful upload
    private var presignedURL: String?
    private var processingTask: Task<Void, Never>?
    private var isFinished = false
    private var hasSuccessfulUpload = false
    private var cancellationRequested = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        processSharedItems()
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        containerView = UIView()
        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 16
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        iconView = UIImageView(image: UIImage(systemName: "arrow.up.circle"))
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(iconView)

        progressView = UIActivityIndicatorView(style: .large)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.startAnimating()
        containerView.addSubview(progressView)

        statusLabel = UITextView()
        statusLabel.isEditable = false
        statusLabel.isSelectable = true
        statusLabel.isScrollEnabled = true
        statusLabel.backgroundColor = .clear
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textContainerInset = .zero
        statusLabel.text = "Uploading to S3..."
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)

        linkLabel = UILabel()
        linkLabel.textAlignment = .center
        linkLabel.font = .preferredFont(forTextStyle: .caption1)
        linkLabel.textColor = .secondaryLabel
        linkLabel.numberOfLines = 3
        linkLabel.lineBreakMode = .byTruncatingMiddle
        linkLabel.isHidden = true
        linkLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(linkLabel)

        // Copy Link button (shown after upload)
        copyLinkButton = UIButton(type: .system)
        copyLinkButton.setTitle("Copy Link", for: .normal)
        copyLinkButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copyLinkButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        copyLinkButton.backgroundColor = .systemBlue
        copyLinkButton.setTitleColor(.white, for: .normal)
        copyLinkButton.tintColor = .white
        copyLinkButton.layer.cornerRadius = 10
        copyLinkButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        copyLinkButton.addTarget(self, action: #selector(copyLinkTapped), for: .touchUpInside)
        copyLinkButton.isHidden = true
        copyLinkButton.translatesAutoresizingMaskIntoConstraints = false

        // Done / Cancel button
        actionButton = UIButton(type: .system)
        actionButton.setTitle("Cancel", for: .normal)
        actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        buttonStack = UIStackView(arrangedSubviews: [copyLinkButton, actionButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        buttonStack.alignment = .center
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 300),

            iconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            progressView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            progressView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 12),
            statusLabel.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.25),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            linkLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            linkLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            linkLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: linkLabel.bottomAnchor, constant: 16),
            buttonStack.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16),
        ])
    }

    @objc private func actionButtonTapped() {
        if isFinished {
            if hasSuccessfulUpload { extensionContext?.completeRequest(returningItems: nil) }
            else { extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: -1)) }
        } else {
            cancellationRequested = true
            processingTask?.cancel()
            actionButton.isEnabled = false
            actionButton.setTitle("Cancelling...", for: .normal)
            statusLabel.text = "Stopping pending attachments..."
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isFinished { processingTask?.cancel() }
    }

    @objc private func copyLinkTapped() {
        guard let url = presignedURL else { return }
        UIPasteboard.general.string = url

        // Visual feedback
        let originalTitle = copyLinkButton.title(for: .normal)
        copyLinkButton.setTitle("Copied", for: .normal)
        copyLinkButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
        copyLinkButton.backgroundColor = .systemGreen

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyLinkButton.setTitle(originalTitle, for: .normal)
            self?.copyLinkButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
            self?.copyLinkButton.backgroundColor = .systemBlue
        }
    }

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("No items to share"); return
        }
        guard let config = loadSharedConfig() else {
            showError(sharedConfigLoadError ?? "S3 is not configured. Finish setup in the app."); return
        }
        let attachments = extensionItems.flatMap { $0.attachments ?? [] }
        guard !attachments.isEmpty else { showError("No attachments were supplied."); return }
        let sources = attachments.enumerated().map { index, provider in
            ShareAttachmentSource(name: provider.suggestedName ?? "Attachment \(index + 1)") {
                try await self.loadAttachment(provider)
            }
        }
        processingTask = Task { [weak self] in
            guard let self else { return }
            let report = await ShareAttachmentPipeline.process(sources, progress: { index, total in
                self.statusLabel.text = "Uploading attachment \(index) of \(total)..."
            }, upload: { payload in
                guard case .file(let file) = payload.body else { throw ShareUploadError.unsupportedRepresentation }
                let key = UploadKeyFactory.image(extension: file.pathExtension)
                try await self.uploadToS3(file: file, key: key, contentType: payload.contentType, config: config)
                return key
            })
            self.finish(report, config: config)
            self.processingTask = nil
        }
    }

    private func loadAttachment(_ provider: NSItemProvider) async throws -> PreparedUploadPayload {
        let movie = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let image = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        guard movie || image else { throw ShareUploadError.unsupportedRepresentation }
        let type = movie ? UTType.movie.identifier : UTType.image.identifier
        let promise = CancellableFilePromise<ImportedUploadFile>(identity: { $0.url }, dispose: { $0.payload.cleanInputFile() })
        let raw: ImportedUploadFile
        do {
            raw = try await promise.value { finish in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw ShareUploadError.unsupportedRepresentation }
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        let descriptor = UploadFileDescriptor(filenameExtension: url.pathExtension,
                            contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                        finish(.success(try OwnedUploadInputs.copyWhileAvailable(url, descriptor: descriptor)))
                    } catch { finish(.failure(error)) }
                }
            }
        } catch {
            try Task.checkCancellation()
            guard image && !movie else { throw error }
            // Some image providers expose only a data representation. Stage one image,
            // then release its Data before the serial pipeline requests another item.
            let fallback = CancellableFilePromise<ImportedUploadFile>(identity: { $0.url }, dispose: { $0.payload.cleanInputFile() })
            raw = try await fallback.value { finish in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    do {
                        if let error { throw error }
                        guard let data else { throw ShareUploadError.unsupportedRepresentation }
                        let decoded = try ImageUploadRepresentation.decode(data)
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s3-share-inputs")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let url = directory.appendingPathComponent(UUID().uuidString + "." + decoded.filenameExtension)
                        do {
                            try data.write(to: url, options: .atomic)
                            finish(.success(.init(url: url, filename: url.lastPathComponent, contentType: decoded.contentType)))
                        } catch { try? FileManager.default.removeItem(at: url); throw error }
                    } catch { finish(.failure(error)) }
                }
            }
        }
        defer { raw.payload.cleanInputFile() }
        try Task.checkCancellation()
        return try await ImportedUploadFile.importMedia(at: raw.url, movie: movie).payload
    }

    private func finish(_ report: ShareAttachmentReport, config: S3Config) {
        isFinished = true
        hasSuccessfulUpload = !report.keys.isEmpty
        progressView.stopAnimating()
        let complete = report.failed == 0 && report.cancelled == 0
        iconView.image = UIImage(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        iconView.tintColor = complete ? .systemGreen : .systemOrange
        statusLabel.text = report.summary
        if let key = report.keys.last,
           let url = S3ObjectAddress.presignedURL(bucket: config.bucketName, region: config.region, key: key,
               accessKey: config.accessKey, secretKey: config.secretKey, expiresIn: 86_400) {
            presignedURL = url
            UIPasteboard.general.string = url
            linkLabel.text = "Last successful link copied (expires in 1 day)"
            linkLabel.isHidden = false
            copyLinkButton.isHidden = false
        }
        actionButton.isEnabled = true
        actionButton.setTitle("Done", for: .normal)
    }

    private func showError(_ message: String) {
        isFinished = true
        progressView.stopAnimating()
        iconView.image = UIImage(systemName: "xmark.circle.fill")
        iconView.tintColor = .systemRed
        statusLabel.text = message
        actionButton.isEnabled = true
        actionButton.setTitle("Done", for: .normal)
    }

    // MARK: - Shared Config (App Groups)

    private func loadSharedConfig() -> S3Config? {
        sharedConfigLoadError = nil
        do { return try SharedConfig.loadConfig() }
        catch {
            sharedConfigLoadError = error.localizedDescription
            logger.error("Secure S3 configuration could not be loaded: \(error.localizedDescription)")
            return nil
        }
    }

    private func uploadToS3(file: URL, key: String, contentType: String, config: S3Config) async throws {
        let signed = try await S3FileUploadSigning.shared.request(file: file, bucket: config.bucketName,
            region: config.region, key: key, accessKey: config.accessKey, secretKey: config.secretKey, contentType: contentType)
        try Task.checkCancellation()
        let (_, response) = try await URLSession.shared.upload(for: signed.request, fromFile: file)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ShareUploadError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if let defaults = UserDefaults(suiteName: "group.com.crispytoast.TestS3Browser") {
            do {
                let record = MetadataRecord(bucket: config.bucketName, key: key, size: signed.bytes, modified: Date(),
                    etag: httpResponse.value(forHTTPHeaderField: "ETag"), contentType: contentType)
                try RecentUploadDelivery.uploaded(record,
                    account: S3AccountScope.identifier(region: config.region, accessKey: config.accessKey),
                    defaults: defaults, lockURL: SharedConfig.recentDeliveryLockURL()) {
                    WidgetCenter.shared.reloadTimelines(ofKind: "TestS3BrowserWidget")
                }
            } catch { logger.error("Upload succeeded but widget snapshot delivery failed: \(error.localizedDescription)") }
        }
    }

}

/// S3Config definition for share extension (must match main app's S3Config)
struct S3Config: Decodable, Equatable, Sendable {
    var bucketName: String
    var region: String
    var accessKey: String
    var secretKey: String
    var prefix: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        zip([lhs.bucketName, lhs.region, lhs.accessKey, lhs.secretKey, lhs.prefix],
            [rhs.bucketName, rhs.region, rhs.accessKey, rhs.secretKey, rhs.prefix])
            .allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

enum ShareUploadError: LocalizedError {
    case invalidURL
    case uploadFailed(Int)
    case noConfig
    case unsupportedRepresentation

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid S3 URL"
        case .uploadFailed(let code): return "Upload failed with status \(code)"
        case .noConfig: return "S3 not configured"
        case .unsupportedRepresentation: return "This attachment has no supported, readable image or movie representation."
        }
    }
}
