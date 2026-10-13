import SwiftUI

private let screensDesignPrefix = "screensdesign/apps/"

private struct ScreensDesignApp: Decodable, Identifiable {
    struct Video: Decodable, Identifiable {
        let key: String
        let label: String
        let frames: Int

        var id: String { key }
    }

    let slug: String
    let name: String
    let videos: [Video]
    let sourceURL: String?

    var id: String { slug }
    var frameCount: Int { videos.reduce(0) { $0 + $1.frames } }
    var source: URL? {
        URL(string: sourceURL ?? "https://screensdesign.com/apps/\(slug)/")
    }
}

/// A product index over the selected, private ScreensDesign frames in S3.
struct ScreensDesignAppsView: View {
    let s3Service: S3Service

    @State private var apps: [ScreensDesignApp] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && apps.isEmpty {
                    ProgressView("Loading apps...")
                } else if let errorMessage {
                    ContentUnavailableView("Apps unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if apps.isEmpty {
                    ContentUnavailableView("No apps uploaded", systemImage: "square.grid.2x2", description: Text("ScreensDesign apps in this bucket will appear here."))
                } else {
                    List(apps) { app in
                        NavigationLink {
                            ScreensDesignAppDetailView(app: app, s3Service: s3Service)
                        } label: {
                            HStack(spacing: 12) {
                                ScreensDesignCoverView(app: app, s3Service: s3Service)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.headline)
                                    Text("\(app.frameCount) in-app frames · \(app.videos.count) recordings")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Apps")
        }
        .task(id: s3Service.currentBucket) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            var folders: [S3Folder] = []
            var token: String?
            repeat {
                let page = try await s3Service.listPrefix(screensDesignPrefix, continuationToken: token)
                folders += page.items.compactMap {
                    if case .folder(let folder) = $0 { return folder }
                    return nil
                }
                token = page.nextToken
            } while token != nil

            var loaded: [ScreensDesignApp] = []
            for folder in folders {
                do {
                    let data = try await s3Service.downloadObject(key: "\(folder.prefix)app.json")
                    loaded.append(try JSONDecoder().decode(ScreensDesignApp.self, from: data))
                } catch {
                    // An incomplete app upload should not hide the other apps.
                    continue
                }
            }
            apps = loaded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct ScreensDesignCoverView: View {
    let app: ScreensDesignApp
    let s3Service: S3Service
    @State private var thumbnail: UIImage?

    private var firstFrameKey: String? {
        guard let video = app.videos.first else { return nil }
        return "\(screensDesignPrefix)\(app.slug)/\(video.key)/screen-001.webp"
    }

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 70)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: firstFrameKey.map {
            MediaObjectIdentity(account: S3AccountScope.identifier(region: s3Service.config.region, accessKey: s3Service.config.accessKey),
                                bucket: s3Service.currentBucket, key: $0).digest
        }) {
            guard let key = firstFrameKey else { return }
            thumbnail = nil
            let generation = s3Service.session.generation
            guard let metadata = try? await s3Service.headObject(key: key) else { return }
            let object = S3Object(
                key: key,
                size: Int64(metadata.contentLength ?? 0),
                lastModified: metadata.lastModified ?? .now,
                etag: metadata.etag,
                bucket: s3Service.currentBucket
            )
            let image = await ImageCacheActor.shared.loadThumbnail(for: object, using: s3Service)
            guard !Task.isCancelled, s3Service.session.isCurrent(generation) else { return }
            thumbnail = image
        }
    }
}

private struct ScreensDesignAppDetailView: View {
    let app: ScreensDesignApp
    let s3Service: S3Service

    var body: some View {
        List {
            Section {
                if let source = app.source {
                    Link(destination: source) {
                        Label("View on ScreensDesign", systemImage: "link")
                    }
                }
            } footer: {
                Text("Frames captured from in-app walkthroughs, grouped by recording.")
            }

            Section("Recordings") {
                ForEach(app.videos) { video in
                    NavigationLink {
                        ScreensDesignFramesView(app: app, video: video, s3Service: s3Service)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.label)
                            Text("\(video.frames) frames")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ScreensDesignFramesView: View {
    let app: ScreensDesignApp
    let video: ScreensDesignApp.Video
    let s3Service: S3Service

    @State private var frames: [S3Object] = []
    @State private var listing = PagedListingState()

    private var prefix: String { "\(screensDesignPrefix)\(app.slug)/\(video.key)/" }
    private var query: ListingQuery {
        ListingQuery(account: s3Service.session.configuration.account, bucket: s3Service.currentBucket, prefix: prefix)
    }

    var body: some View {
        Group {
            if listing.isLoading && frames.isEmpty {
                ProgressView("Loading frames...")
            } else if let errorMessage = listing.error, frames.isEmpty {
                ContentUnavailableView("Frames unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ScrollView {
                    if let error = listing.error {
                        Text(error).font(.caption).foregroundStyle(.red).padding()
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
                        ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                            NavigationLink {
                                ImageGalleryView(images: frames, initialIndex: index, s3Service: s3Service)
                            } label: {
                                RecentFileGridItem(object: frame, s3Service: s3Service, cardSize: 115)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)

                    if listing.page?.nextToken != nil {
                        Button(listing.isLoadingMore ? "Loading..." : "Load more") { Task { await loadNextPage() } }
                            .disabled(listing.isLoading || listing.isLoadingMore)
                            .padding()
                    }
                }
                .refreshable { await reload(force: true) }
            }
        }
        .navigationTitle(video.label)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) { await reload() }
    }

    private func reload(force: Bool = false) async {
        let captured = query, generation = s3Service.session.generation
        if listing.query != captured { frames = [] }
        do {
            try await listing.reload(captured, force: force) { token in
                try await s3Service.fetchPrefixMetadataPage(captured, token: token)
            }
            guard query == captured, s3Service.session.isCurrent(generation), !Task.isCancelled else { return }
            publishFrames()
        } catch { /* The owned listing publishes its current error and retains good frames. */ }
    }

    private func loadNextPage() async {
        let captured = query, generation = s3Service.session.generation
        do {
            try await listing.loadMore { token in
                try await s3Service.fetchPrefixMetadataPage(captured, token: token)
            }
            guard query == captured, s3Service.session.isCurrent(generation), !Task.isCancelled else { return }
            publishFrames()
        } catch { /* Obsolete page failures cannot change the refreshed listing. */ }
    }

    private func publishFrames() {
        frames = (listing.page?.files ?? []).map(\.s3Object)
            .filter { $0.fileType == .image }.sorted { $0.key < $1.key }
    }
}
