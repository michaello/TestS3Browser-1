import SwiftUI

private let screensDesignPrefix = "screensdesign/apps/"

/// A product index over the selected, private ScreensDesign frames in S3.
struct ScreensDesignAppsView: View {
    let s3Service: S3Service

    @State private var index = ScreensAppIndexCache.shared
    private var identity: MediaObjectIdentity {
        MediaObjectIdentity(account: s3Service.session.configuration.account, bucket: s3Service.currentBucket, key: screensDesignPrefix)
    }
    private var entries: [ScreensAppEntry] { index.value(for: identity)?.entries ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty && (!index.hasLoaded(identity) || index.isLoading(identity)) {
                    ProgressView("Loading apps...")
                } else if let errorMessage = index.error(identity), entries.isEmpty {
                    ContentUnavailableView("Apps unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    Button("Retry") { Task { await load(force: true) } }
                } else if entries.isEmpty {
                    ContentUnavailableView("No apps uploaded", systemImage: "square.grid.2x2", description: Text("ScreensDesign apps in this bucket will appear here."))
                    Button("Refresh") { Task { await load(force: true) } }
                } else {
                    List {
                        if let snapshot = index.value(for: identity), !snapshot.isComplete || index.error(identity) != nil {
                            Section {
                                Text(index.error(identity) ?? "Index incomplete. \(snapshot.failures.count) app manifests could not be refreshed.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Retry") { Task { await load(force: true) } }
                            }
                        }
                        ForEach(entries) { entry in
                        NavigationLink {
                            ScreensDesignAppDetailView(app: entry.app, s3Service: s3Service)
                        } label: {
                            HStack(spacing: 12) {
                                ScreensDesignCoverView(app: entry.app, cover: entry.cover, s3Service: s3Service)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.app.name).font(.headline)
                                    Text("\(entry.app.frameCount) in-app frames · \(entry.app.videos.count) recordings")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        }
                    }
                    .refreshable { await load(force: true) }
                }
            }
            .navigationTitle("Apps")
        }
        .task(id: identity) { await load() }
    }

    private func load(force: Bool = false) async {
        await index.load(identity, force: force, transport: ScreensIndexServiceTransport(service: s3Service))
    }
}

private struct ScreensDesignCoverView: View {
    let app: ScreensDesignApp
    let cover: MetadataRecord?
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
                                bucket: cover?.bucket ?? s3Service.currentBucket, key: $0, etag: cover?.etag).digest
        }) {
            guard let key = firstFrameKey else { return }
            thumbnail = nil
            let generation = s3Service.session.generation
            let object: S3Object
            if let cover { object = cover.s3Object }
            else {
                let unknown = S3Object(key: key, size: -1, lastModified: .distantPast, etag: nil, bucket: s3Service.currentBucket)
                guard case .metadata(let metadata) = try? await DetailMetadataCache.shared.load(.metadata, object: unknown, service: s3Service) else { return }
                object = S3Object(key: key, size: Int64(metadata.contentLength ?? -1), lastModified: metadata.lastModified ?? .distantPast,
                                  etag: metadata.etag, bucket: unknown.bucket)
            }
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
