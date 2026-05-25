import UIKit
import Social
import UniformTypeIdentifiers
import os.log
import CommonCrypto

/// Share Extension view controller for uploading images and videos to S3 dump folder
class ShareViewController: UIViewController {
    private let logger = Logger(subsystem: "com.crispytoast.TestS3Browser.ShareExtension", category: "ShareVC")

    private var statusLabel: UILabel!
    private var progressView: UIActivityIndicatorView!
    private var iconView: UIImageView!
    private var containerView: UIView!
    private var actionButton: UIButton!
    private var copyLinkButton: UIButton!
    private var linkLabel: UILabel!
    private var buttonStack: UIStackView!

    /// Stores the presigned URL after successful upload
    private var presignedURL: String?

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

        statusLabel = UILabel()
        statusLabel.text = "Uploading to S3..."
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
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
        if presignedURL != nil {
            // Done — dismiss after successful upload
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            // Cancel — abort
            extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: -1))
        }
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
            showError("No items to share")
            return
        }

        guard let config = loadSharedConfig() else {
            showError("S3 not configured. Open CrispyAWS app first to set up credentials.")
            return
        }

        var itemsToUpload: [(Data, String, String)] = [] // (data, extension, contentType)
        let group = DispatchGroup()

        for extensionItem in extensionItems {
            guard let attachments = extensionItem.attachments else { continue }

            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    group.enter()
                    attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] item, error in
                        defer { group.leave() }

                        if let error = error {
                            self?.logger.error("Failed to load image: \(error.localizedDescription)")
                            return
                        }

                        var imageData: Data?
                        if let url = item as? URL {
                            imageData = try? Data(contentsOf: url)
                        } else if let data = item as? Data {
                            imageData = data
                        } else if let image = item as? UIImage {
                            imageData = image.jpegData(compressionQuality: 0.8)
                        }

                        if let data = imageData {
                            let jpegData: Data
                            if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) {
                                jpegData = jpeg
                            } else {
                                jpegData = data
                            }
                            itemsToUpload.append((jpegData, "jpg", "image/jpeg"))
                        }
                    }
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    group.enter()
                    attachment.loadItem(forTypeIdentifier: UTType.movie.identifier, options: nil) { [weak self] item, error in
                        defer { group.leave() }

                        if let error = error {
                            self?.logger.error("Failed to load video: \(error.localizedDescription)")
                            return
                        }

                        if let url = item as? URL, let data = try? Data(contentsOf: url) {
                            let ext = url.pathExtension.lowercased()
                            let contentType = ext == "mov" ? "video/quicktime" : "video/mp4"
                            itemsToUpload.append((data, ext.isEmpty ? "mp4" : ext, contentType))
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            if itemsToUpload.isEmpty {
                self.showError("No supported media found")
                return
            }

            Task {
                await self.uploadItems(itemsToUpload, config: config)
            }
        }
    }

    private func uploadItems(_ items: [(Data, String, String)], config: S3Config) async {
        let total = items.count
        var uploaded = 0
        var lastUploadedKey: String?

        for (data, ext, contentType) in items {
            await MainActor.run {
                statusLabel.text = "Uploading \(uploaded + 1) of \(total)..."
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let key = "dump/\(timestamp).\(ext)"

            do {
                try await uploadToS3(data: data, key: key, contentType: contentType, config: config)
                uploaded += 1
                lastUploadedKey = key
                logger.info("Uploaded \(key) (\(data.count) bytes)")
            } catch {
                logger.error("Upload failed for \(key): \(error.localizedDescription)")
                await MainActor.run {
                    showError("Upload failed: \(error.localizedDescription)")
                }
                return
            }
        }

        // Generate presigned URL for the last uploaded file (1-day expiry)
        let url: String?
        if let key = lastUploadedKey {
            url = generatePresignedURL(for: key, config: config, expiresIn: 86400)
        } else {
            url = nil
        }

        await MainActor.run {
            progressView.stopAnimating()
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            statusLabel.text = "Uploaded \(uploaded) file\(uploaded == 1 ? "" : "s")"

            if let url = url {
                presignedURL = url
                // Auto-copy to clipboard
                UIPasteboard.general.string = url
                linkLabel.text = "Link copied to clipboard (expires in 1 day)"
                linkLabel.isHidden = false
                copyLinkButton.isHidden = false
            }

            actionButton.setTitle("Done", for: .normal)
        }
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.progressView.stopAnimating()
            self?.iconView.image = UIImage(systemName: "xmark.circle.fill")
            self?.iconView.tintColor = .systemRed
            self?.statusLabel.text = message
        }

        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: -1))
        }
    }

    // MARK: - Shared Config (App Groups)

    private func loadSharedConfig() -> S3Config? {
        let suiteName = "group.com.crispytoast.TestS3Browser"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            logger.error("Failed to access App Group UserDefaults")
            return nil
        }
        guard let data = defaults.data(forKey: "s3Config") else {
            logger.error("No S3 config found in App Group UserDefaults")
            return nil
        }
        return try? JSONDecoder().decode(S3Config.self, from: data)
    }

    // MARK: - Presigned URL Generation

    /// Generates a presigned GET URL for an S3 object (7-day max expiry)
    private func generatePresignedURL(for key: String, config: S3Config, expiresIn: Int = 86400) -> String? {
        let bucket = config.bucketName
        let region = config.region
        let host = region == "us-east-1"
            ? "\(bucket).s3.amazonaws.com"
            : "\(bucket).s3.\(region).amazonaws.com"

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let credential = "\(config.accessKey)/\(credentialScope)"

        let encodedKey = key.split(separator: "/").map { component in
            component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
        }.joined(separator: "/")

        let signedHeaders = "host"
        var awsQueryAllowed = CharacterSet.urlQueryAllowed
        awsQueryAllowed.remove("/")
        let encodedCredential = credential.addingPercentEncoding(withAllowedCharacters: awsQueryAllowed) ?? credential
        let queryParams = [
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "X-Amz-Credential=\(encodedCredential)",
            "X-Amz-Date=\(amzDate)",
            "X-Amz-Expires=\(expiresIn)",
            "X-Amz-SignedHeaders=\(signedHeaders)",
        ].joined(separator: "&")

        let canonicalRequest = [
            "GET",
            "/\(encodedKey)",
            queryParams,
            "host:\(host)",
            "",
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest.data(using: .utf8)!)
        ].joined(separator: "\n")

        let kDate = hmacSHA256(key: "AWS4\(config.secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmacSHA256(key: kDate, data: region.data(using: .utf8)!)
        let kService = hmacSHA256(key: kRegion, data: "s3".data(using: .utf8)!)
        let kSigning = hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)

        let signature = hmacSHA256(key: kSigning, data: stringToSign.data(using: .utf8)!)
            .map { String(format: "%02x", $0) }.joined()

        return "https://\(host)/\(encodedKey)?\(queryParams)&X-Amz-Signature=\(signature)"
    }

    // MARK: - S3 Upload via AWS Signature V4

    private func uploadToS3(data: Data, key: String, contentType: String, config: S3Config) async throws {
        let bucket = config.bucketName
        let region = config.region
        let host = region == "us-east-1"
            ? "\(bucket).s3.amazonaws.com"
            : "\(bucket).s3.\(region).amazonaws.com"

        guard let url = URL(string: "https://\(host)/\(key)") else {
            throw ShareUploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        let payloadHash = sha256Hex(data)

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = [
            "content-type:\(contentType)",
            "host:\(host)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(amzDate)"
        ].joined(separator: "\n")

        let canonicalRequest = [
            "PUT",
            "/\(key)",
            "",
            canonicalHeaders,
            "",
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest.data(using: .utf8)!)
        ].joined(separator: "\n")

        let kDate = hmacSHA256(key: "AWS4\(config.secretKey)".data(using: .utf8)!, data: dateStamp.data(using: .utf8)!)
        let kRegion = hmacSHA256(key: kDate, data: region.data(using: .utf8)!)
        let kService = hmacSHA256(key: kRegion, data: "s3".data(using: .utf8)!)
        let kSigning = hmacSHA256(key: kService, data: "aws4_request".data(using: .utf8)!)

        let signature = hmacSHA256(key: kSigning, data: stringToSign.data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ShareUploadError.uploadFailed(statusCode)
        }
    }

    // MARK: - Crypto Helpers

    private func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBuffer in
            data.withUnsafeBytes { dataBuffer in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyBuffer.baseAddress, key.count,
                       dataBuffer.baseAddress, data.count,
                       &hmac)
            }
        }
        return Data(hmac)
    }
}

/// S3Config definition for share extension (must match main app's S3Config)
struct S3Config: Codable, Equatable {
    var bucketName: String
    var region: String
    var accessKey: String
    var secretKey: String
    var prefix: String
}

enum ShareUploadError: LocalizedError {
    case invalidURL
    case uploadFailed(Int)
    case noConfig

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid S3 URL"
        case .uploadFailed(let code): return "Upload failed with status \(code)"
        case .noConfig: return "S3 not configured"
        }
    }
}
