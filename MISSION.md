# Mission: puddingdemo_0_0

TestS3Browser - S3 browser app. iOS 18+, Observation, async/await, actor-isolated service.
Tracks the demo build-out across phases. Each phase lists the concrete work and the
commits that delivered it so the next assignment can pick up from a known state.

Repo: /Users/mike/Developer/test-projects/TestS3Browser-1
Bundle ID: com.crispytoast.TestS3Browser

## Phase 1 - App Intents + explicit project structure (DONE)

- Added `Sources/Intents/UploadToS3Intent.swift` (UploadFileToS3Intent + TestS3BrowserShortcuts AppShortcutsProvider).
- Converted `TestS3Browser.xcodeproj/project.pbxproj` from `PBXFileSystemSynchronizedRootGroup`
  (Xcode 16 synchronized folders) to explicit per-file PBXBuildFile / PBXFileReference /
  PBXSourcesBuildPhase entries for all `.swift` files under `Sources/`.
- Verified UploadToS3Intent exposed to Siri via AppShortcutsProvider.

Commit: `da8a10d` Convert Sources to explicit pbxproj entries, add UploadToS3Intent

## Phase 2 - ListRecentFilesIntent Siri shortcut (DONE)

- Added `Sources/Intents/ListRecentFilesIntent.swift`: returns the most recent N S3 object
  keys (default 10) by reading `S3Service.recentFiles` after `fetchRecentFilesFromAllBuckets`.
- Added an AppShortcut in TestS3BrowserShortcuts with phrase
  "List my recent S3 files with ${applicationName}" and systemImageName "list.bullet".
- Wired into the pbxproj with explicit entries; confirmed registration in
  `Metadata.appintents/extract.actionsdata`.

Commit: `881b007` add list recent s3 files siri intent

## Phase 3 - Delete UX hardening (DONE)

- RecentFilesView: error alert catching `deleteFile` failures via `.alert(isPresented:)`.
- StashView: swipe-to-delete on report rows (`deleteReport` -> `deleteObject`), with its
  own delete-failure alert state.
- RecentFilesView: "Clear All" toolbar button (`S3Service.clearRecentFiles()` on the main
  actor + reload), gated behind a `.confirmationDialog` confirmation step.
- Extracted the shared delete-failure alert into `Sources/Extensions/DeleteErrorAlert.swift`
  (`.deleteErrorAlert(isPresented:message:)` modifier) and applied it to both views.

Commits:
- `5263940` show alert when deleting a recent file fails
- `78f8563` add swipe-to-delete for stash reports
- `898a716` add clear-all button to recent files view
- `ca58c99` confirm before clearing all recent files
- `23f5f41` extract shared delete-error alert modifier

Runtime verification (simulator iPhone 16 Pro, via temporary launch-arg seams, since
reverted): delete-failure alert and Clear All confirmation dialog both rendered through
the production code paths. Receipts: `/tmp/s3b-receipts/` (13-delete-error-alert.png,
15-clear-all-confirm.png, COLLAGE-phase3-verification.png).

## Phase 4 - "Copy S3 URL" swipe action on RecentFilesView (DONE)

### Delivered
Added a leading `.swipeActions(edge: .leading)` to the recent-files **list** row
(`Sources/RecentFilesView.swift`, the `ForEach(filteredRecentFiles)` in `listView`): a
"Copy URL" button (systemImage "link", `.tint(.blue)`) that calls
`s3Service.generatePresignedURL(for: file.key, bucket: file.bucket, expiresIn: 86400)`,
copies the URL to the pasteboard on success, and shows `showCopyToast("Link copied")`.
The nil-URL return is guarded with `if let`, so the copy/toast only fire on a real URL.

Build clean (xcodebuild, iOS Simulator). Commit: `9b5d6f8` add copy url swipe action to recent files list.

Follow-up (resolves the two open deviations):
- nil-URL toast: added. The list swipe and the context-menu Copy Link item now both call a
  shared `copyURL(for:)` helper that shows "Link copied" on success and "Could not copy link"
  when `generatePresignedURL` returns nil.
- grid-mode swipe action: NOT implementable. `gridView` is a `LazyVGrid` inside a `ScrollView`,
  not a `List`. SwiftUI `.swipeActions` only takes effect on `List` rows, so a swipe action on
  a grid card would compile but never trigger. The grid keeps the Copy Link affordance via its
  existing context menu (also routed through `copyURL(for:)`). No swipe is possible there.

### Original plan (TODO)

### Goal
Give recent-file rows a one-swipe way to copy a shareable presigned S3 URL, parallel to
the swipe-to-delete added to StashView in Phase 3. A "Copy Link (1 day)" context-menu item
already exists, but it is hidden behind a long-press; this surfaces the same action as a
leading swipe so it is discoverable and one-gesture.

### Scope
- In `Sources/RecentFilesView.swift`, add a leading `.swipeActions(edge: .leading)` to each
  row in both `listView` and `gridView` (the `ForEach(filteredRecentFiles)` blocks around
  lines 158-183) with a non-destructive Button labelled "Copy URL" (systemImage "link").
- The button must reuse the existing presigned-URL path, not a new one:
  `s3Service.generatePresignedURL(for: file.key, bucket: file.bucket, expiresIn: 86400)`,
  then `UIPasteboard.general.string = url` and `showCopyToast("Link copied")` - the exact
  calls already used by the `deleteContextMenu` Copy Link item (RecentFilesView.swift:188-191).
- If `generatePresignedURL` returns nil, surface a failure via the existing toast
  (`showCopyToast("Could not copy link")`) - do not add a new alert path.
- Keep the existing context-menu Copy Link item; the swipe action is additive.

### Acceptance criteria
- Leading-swipe on a recent-file row reveals a "Copy URL" button (list and grid modes).
- Tapping it copies a 1-day presigned URL to the pasteboard and shows the "Link copied" toast.
- Nil-URL case shows a "Could not copy link" toast, no crash.
- No regression to swipe-to-delete (StashView) or the context-menu Copy Link/Copy Path items.
- Build clean; commit with message "add copy-url swipe action to recent files".

### References
- Existing presigned-URL + toast: `Sources/RecentFilesView.swift` deleteContextMenu (lines 186-201), showCopyToast (line 436).
- Swipe-action precedent: `Sources/StashView.swift` `.swipeActions` on report rows (lines 53-59).
- Service method: `S3Service.generatePresignedURL(for:bucket:expiresIn:)`.

## Phase 5 - Widget, new intents, upload UX, and cold-launch persistence (DONE)

### WidgetKit extension (`TestS3BrowserWidget`)
- Added `Sources/Widget/TestS3BrowserWidget.swift`: `SystemSmall` shows the most recent
  upload (icon, filename, age, bucket); `SystemMedium` shows up to 3 rows with size and
  relative date. Both read `[S3Object]` JSON from
  `UserDefaults(suiteName: "group.com.crispytoast.TestS3Browser")` key `"recentUploads"`.
  Timeline refreshes every 15 minutes as a backstop.
- Added `WidgetExtension/TestS3BrowserWidget.entitlements` with the shared App Group.
- Wired `TestS3BrowserWidget` target into `project.pbxproj` (bundle ID
  `com.crispytoast.TestS3Browser.Widget`, team `AS5AAW6A59`), embedded into the main app
  via the existing Embed App Extensions phase.
- `S3Object` gained `Codable` conformance in `Sources/Models.swift` to support JSON
  round-tripping.

Commit: `1306175` widget: recent uploads widget with shared app group

### Widget reload trigger
- `S3Service.persistRecentFiles()` now calls
  `WidgetCenter.shared.reloadTimelines(ofKind: "TestS3BrowserWidget")` immediately after
  writing UserDefaults, so the widget reflects every mutation (fetch, delete, clear,
  switchBucket) without waiting for the 15-minute poll.

Commit: `5841947` widget: reload timeline after every recentFiles mutation

### `DownloadFileIntent` Siri shortcut
- Added `Sources/Intents/DownloadFileIntent.swift`: takes `key: String` and optional
  `bucket: String?`, calls `S3Service.downloadObject(key:bucket:)`, wraps bytes in
  `IntentFile` with UTType inferred from extension, returns the file so Shortcuts can
  pipe it to Save to Files / Quick Look.
- Registered in `TestS3BrowserShortcuts` with phrase
  "Download S3 file with ${applicationName}" and systemImage `arrow.down.circle`.
- Confirmed in `Metadata.appintents/extract.actionsdata`.

Commit: `f6bd1fc` intents: add DownloadFileIntent Siri shortcut

### `DeleteFileIntent` Siri shortcut
- Added `Sources/Intents/DeleteFileIntent.swift`: takes `key: String` and optional
  `bucket: String?`, calls `S3Service.deleteObject(key:bucket:)`, returns a dialog
  confirming the filename. Chainable after `ListRecentFilesIntent` for bulk deletes.
- Registered in `TestS3BrowserShortcuts` with phrase
  "Delete S3 file with ${applicationName}" and systemImage `trash`.
- Confirmed in `Metadata.appintents/extract.actionsdata` alongside all four intents.

Commit: `2862c0a` intents: add DeleteFileIntent Siri shortcut

### Upload progress bar
- `S3Service+Transfer.swift` `uploadObject` gained `onProgress: (@MainActor (Double) -> Void)?`.
  A background task ticks every 100 ms and eases toward 0.9 using `1 - exp(-3t/T)` (T
  estimated from byte count at 500 KB/s); snaps to 1.0 when `putObject` returns.
  `uploadToDump` forwards the callback transparently.
- `DropUploadView` replaced the indeterminate spinner with `ProgressView(value:)` (linear)
  plus an "Uploading 42%..." label counting up to "Finishing..." at 100%.

Commit: `adbddda` upload: show transfer progress bar in upload view

### Copy Link button in upload success card
- `DropUploadView` success card gained a "Copy Link" button alongside "Copy Path".
  Calls `s3Service.generatePresignedURL(for:expiresIn:86400)`, copies on success, shows
  "Could not generate link" toast on nil. Same slide-in toast overlay pattern as
  `RecentFilesView`.

Commit: `b4e4b74` upload: add Copy Link button to upload success card

### Cold-launch persistence for Recent Files
- `S3Service.init` now calls `loadPersistedRecentFiles()`, which reads the same
  `"recentUploads"` key written by `persistRecentFiles()`, so `recentFiles` is populated
  immediately on cold launch without a network round-trip. Pattern mirrors
  `SharedConfig.loadConfig()`.

Commit: `0b32e2f` recent-files: persist upload history across cold launches

### `SearchFileIntent` Siri shortcut
- Added `Sources/Intents/SearchFileIntent.swift`: takes `query: String`, calls
  `fetchRecentFilesFromAllBuckets(limit: 50)`, filters keys by case-insensitive substring
  match, returns matching keys as `[String]` with a count dialog.
- Registered in `TestS3BrowserShortcuts` with phrase
  "Search my S3 files with ${applicationName}" and systemImage `magnifyingglass`.
- Confirmed in `Metadata.appintents/extract.actionsdata` alongside all five intents.

Commit: `3e1b4d6` intents: add SearchFileIntent Siri shortcut

## Phase 6 - In-app search bar in RecentFilesView (DONE)

- Added `@State private var searchText` to `RecentFilesView`.
- `filteredRecentFiles` now applies a case-insensitive key substring filter after the
  existing type filter when `searchText` is non-empty.
- `.searchable(text: $searchText, prompt: "Search files")` added to the `NavigationStack`
  so iOS renders the standard pull-down search bar.
- Empty-results state uses `ContentUnavailableView.search(text:)` (system search empty
  state) when the search query is active, and the existing "No Matching Files" view when
  only the type filter is active.

Commit: `3ff1b1f` ui: add in-app search bar to RecentFilesView

## Phase 7 - File rename in RecentFilesView (DONE)

- Added `S3Service+Transfer.renameObject(key:to:bucket:)`: copies the object to the new
  key via `CopyObjectInput`, deletes the original via `DeleteObjectInput`, then patches
  the in-memory `recentFiles` array and calls `persistRecentFiles()` so the UI updates
  without a network reload. S3 has no native rename; copy-then-delete is the only option.
- `RecentFilesView` context menu gained a "Rename" item (pencil icon) that populates a
  `TextField` alert pre-filled with the current filename. On confirm the new filename is
  joined back onto the original key's directory prefix so the object stays in its folder.
- Rename failure shows a separate "Rename Failed" alert with the error message, matching
  the delete-error alert pattern.
- Both list and grid rows get the rename item via the shared `deleteContextMenu` builder.

Commit: `e67ceb4` feat: add file rename to RecentFilesView

## Phase 8 - Bulk multi-select delete in RecentFilesView (DONE)

- Toolbar gains an "Edit" button (top-left) that toggles selection mode. In selection mode
  it becomes "Done" and the trailing trash button becomes "Delete (N)" showing the count.
- In list mode each row shows a leading checkbox overlay; tapping the row toggles selection
  instead of navigating. Grid mode cards get the same checkbox overlay.
- "Delete (N)" is disabled when nothing is selected. Tapping it presents a confirmation
  dialog then deletes all selected files concurrently via `withThrowingTaskGroup`, removing
  each from `recentFiles` as it completes. Any per-file failures are collected and surfaced
  in a single error alert after the batch finishes.
- Exiting Edit mode (Done button or after a successful delete) clears the selection set.
- Context menus, swipe actions, and navigation links are suppressed while in selection mode.

Commit: `8014888` feat: add bulk multi-select delete to RecentFilesView

## Phase 9 - File tagging in RecentFilesView (DONE)

- Added `Sources/TagStore.swift`: `@Observable` singleton backed by `UserDefaults.standard`
  key `"s3FileTags"` holding a `[String: String]` dict (S3 object key -> tag label). Exposes
  `setTag(_:forKey:)` (nil/empty removes the tag) and `allTags` (sorted distinct values).
- Added `Sources/TagChip.swift`: small colored capsule that derives a stable hue from the
  tag string's character sum so each distinct tag always renders in the same color.
- `RecentFileRow` and `RecentFileGridItem` gained a `tag: String?` parameter and render a
  `TagChip` in their existing badge row / below the filename respectively.
- `RecentFilesView` context menu gained "Set Tag" / "Edit Tag" (tag icon), which pre-fills
  the current tag and opens an alert with a text field, Save, Remove Tag, and Cancel actions.
- `filteredRecentFiles` chains a tag filter step after the existing type and search filters.
- A horizontally scrolling tag-filter bar (`tagFilterBar`) appears above the list/grid via
  `.safeAreaInset(edge: .top)` when at least one tag exists. Tapping a chip sets `tagFilter`;
  tapping again (or tapping "All") clears it. The bar is hidden when no tags are in use.

Commit: `2864ecf` feat: add file tagging to RecentFilesView

## Phase 10 - Sort controls in RecentFilesView (DONE)

- Added `SortOrder` enum (nested in `RecentFilesView`) with five cases:
  `newestFirst`, `oldestFirst`, `nameAZ`, `nameZA`, `bucket`.
- `@State private var sortOrder: SortOrder = .newestFirst` — in-memory only, not persisted.
- `filteredRecentFiles` applies the sort as a final step after type, tag, and search filters.
  Nil `lastModified` dates sort as `.distantPast`; bucket sort falls back to empty string.
- Sort menu button (`arrow.up.arrow.down` icon) added to the trailing toolbar (left of the
  filter menu) via a new `sortMenu` computed var. Active option shows a checkmark.

Commit: `1c1b25a` feat: add sort controls to RecentFilesView

## Phase 11 - Folder/prefix navigation from RecentFilesView (DONE)

- Added `S3Service.listPrefix(_:bucket:)` in `S3Service+Transfer.swift`: lists common
  prefixes (virtual folders) and objects under a given prefix using delimiter `/`, returns
  `[S3Item]` directly without touching the service's observable state, so it runs safely
  in parallel with BucketBrowserView's own listing.
- Added `Sources/PrefixBrowserView.swift`: self-contained recursive drill-down view.
  Owns its own `@State` items/isLoading/error. Tapping a folder `NavigationLink` pushes
  a new `PrefixBrowserView` at the child prefix; tapping a file opens `FileDetailView`.
  Pull-to-refresh reloads the current level. Reuses `FolderRow` and `FileRow` from
  `BucketBrowserView.swift`.
- `RecentFilesView` gained a `BrowseRoot` sentinel (private `Hashable` struct), a
  `.navigationDestination(for: BrowseRoot.self)` that opens `PrefixBrowserView` at the
  bucket root, and a folder-icon toolbar button (left of the sort menu) that appends
  `BrowseRoot()` to the existing `navigationPath`, triggering the push.

Commit: `dda02e3` feat: add folder/prefix navigation to RecentFilesView

## Phase 12 - File upload from folder browser (DONE)

- `PrefixBrowserView` gained a `+` toolbar button that opens a Menu with two options:
  "Photo or Video" (PhotosPicker, matches images + videos) and "File" (fileImporter,
  accepts any `.item` UTType / document picker).
- Photo picker handler: loads `Data` via `loadTransferable`, infers filename from the
  item identifier (falls back to `photo.jpg`), derives content type from extension.
- File importer handler: opens a security-scoped URL, reads bytes with `Data(contentsOf:)`,
  derives MIME type via `UTType(filenameExtension:).preferredMIMEType`.
- Both paths call `s3Service.uploadObject(data:key:contentType:onProgress:)` with the key
  set to `\(prefix)\(filename)` so the file lands in the current browsed prefix.
- A `.safeAreaInset(edge: .bottom)` status bar shows a linear progress view while uploading
  and a success/failure row with an ✕ dismiss button after completion.
- On success, the listing reloads automatically so the new file appears immediately.

Commit: `52baa67` feat: add file upload to folder browser

## Phase 13 - Pagination in prefix browser (DONE)

- `S3Service.listPrefix(_:bucket:continuationToken:)` in `S3Service+Transfer.swift` gained
  a `continuationToken` parameter (nil = first page) and now returns `(items: [S3Item],
  nextToken: String?)` instead of `[S3Item]`. A non-nil `nextToken` means more pages exist.
- `PrefixBrowserView` gained `@State private var nextToken: String?` and `isLoadingMore`.
  `load()` resets both and fetches page 1. When `nextToken` is non-nil, a "Load more"
  button row appears at the bottom of the List; tapping it calls `loadMore()`, which appends
  the next page and updates `nextToken`. A `ProgressView` spinner replaces the button while
  the page request is in flight.
- Pull-to-refresh still calls `load()`, which resets pagination from the beginning.

Commit: `3c67c1c` feat: add pagination to prefix browser

## Phase 14 - Delete in prefix browser (DONE)

- `PrefixBrowserView` file rows gained `.swipeActions(edge: .trailing, allowsFullSwipe: true)`
  with a destructive "Delete" button, and a "Delete" item in the `.contextMenu`.
- Both call `deleteItem(_:)`, which calls `s3Service.deleteObject(key:bucket:)` and removes
  the item from the local `@State items` array on success so the list updates without a reload.
- Failures surface in a "Delete Failed" alert (`showDeleteError` / `deleteErrorMessage`).
- Folder rows intentionally have no delete (S3 has no recursive folder delete).

Commit: `01e61a3` feat: add delete to prefix browser

## Phase 15 - Move/copy between prefixes (DONE)

- Added `Sources/PrefixPickerSheet.swift`: half-height sheet that browses the bucket prefix
  tree (folders only, one level at a time). Back button walks back up. Trailing "Move"/"Copy"
  toolbar button confirms. A destination banner at the bottom shows where the file will land.
  Disabled when source and destination prefix are the same.
- `PrefixBrowserView` file row `.contextMenu` gained "Move to…" and "Copy to…" items that
  set `moveCopyTarget` and present `PrefixPickerSheet`.
- `performMoveCopy(object:destPrefix:)` calls `s3Service.copyObject(key:to:sourceBucket:destBucket:)`
  then, for move, `deleteObject` and removes the row from `items`. Copy reloads the listing.
- Added `S3Service.copyObject(key:to:sourceBucket:destBucket:)` in `S3Service+Transfer.swift`:
  builds a `CopyObjectInput` with `copySource = "\(src)/\(key)"` and calls `client.copyObject`.

Commit: `e01a845` feat: add move/copy to prefix browser

## Phase 16 - Share presigned URL with expiry picker (DONE)

- Added `Sources/SharePresignedURLSheet.swift`: `.presentationDetents([.medium])` sheet with
  a file identity header, 4 expiry chips (1 hour / 1 day / 3 days / 7 days), a monospace URL
  preview, a "Copy" button (copies to pasteboard with a toast), and a `ShareLink` button that
  opens the system share sheet (AirDrop, Messages, Mail, etc.). URL is generated on-the-fly
  from `s3Service.generatePresignedURL(for:bucket:expiresIn:)` whenever the expiry selection
  changes.
- `RecentFilesView`: context-menu "Copy Link (1 day)" replaced by "Share Link…" (opens sheet);
  leading swipe action updated from direct clipboard copy to opening the same sheet.
  `@State private var shareTarget: S3Object?` drives the `.sheet(item:)`.
- `FileDetailView`: "Share Link…" added to the HTML view's `...` menu; a share toolbar button
  (`square.and.arrow.up`) added to the standard detail view's navigation bar. Both set
  `showingShareSheet = true` and present the sheet.

Commit: `a65b2db` feat: add share presigned URL sheet with expiry picker

## Phase 17 - Object metadata viewer via HeadObject (DONE)

- Added `S3ObjectMetadata` struct in `Sources/Models.swift`: holds `contentType`, `contentLength`,
  `lastModified`, `etag`, `storageClass`, `cacheControl`, `contentEncoding`, `versionId`, and
  `userMetadata: [String: String]` (user-defined `x-amz-meta-*` headers).
- Added `S3Service.headObject(key:bucket:)` in `Sources/Services/S3Service+Transfer.swift`:
  issues a `HeadObjectInput` call and maps the response to `S3ObjectMetadata`.
- `FileDetailView.metadataCard` now shows Content-Type, Storage Class, Encoding, Cache-Control,
  Version ID, ETag, and all custom metadata keys in sorted order. While the HEAD fetch is in
  flight a small spinner replaces the rows. Failure is silent so the rest of the view works.
- Both `htmlPrimaryView` and `standardDetailView` fire `loadMetadata()` concurrently with
  `loadFile()` via `async let`.

Commit: `a3bff14` feat: add object metadata viewer via HeadObject in FileDetailView

## Phase 18 - Bucket usage statistics dashboard

### Goal
Give the user a quick at-a-glance summary of how each S3 bucket is used: total object count
and total storage consumed, without downloading any object bodies.

### Scope
- Add `BucketStats` struct to `Sources/Models.swift`:
  `struct BucketStats: Identifiable { let bucket: String; let objectCount: Int; let totalBytes: Int64 }`
- Add `S3Service.fetchBucketStats() async throws -> [BucketStats]` in a new extension file
  `Sources/Services/S3Service+Stats.swift`. For each bucket in `availableBuckets`, issue
  paginated `ListObjectsV2Input` calls (no delimiter, no prefix) accumulating `size` and
  incrementing count per object. Run all buckets concurrently via `withTaskGroup`. Return
  results sorted by `totalBytes` descending.
- Add `Sources/StatsView.swift`: `@Observable final class StatsViewModel` owns
  `stats: [BucketStats]`, `isLoading: Bool`, `error: String?`. `load()` calls
  `s3Service.fetchBucketStats()`. The view is a `NavigationStack` with a `List` of bucket
  rows showing bucket name, object count, and formatted total size. A toolbar refresh button
  re-triggers `load()`. Pull-to-refresh also calls `load()`. Empty/error states use
  `ContentUnavailableView`.
- Add a `Stats` case to `AppTab` in `ContentView.swift` (icon `chart.bar`) and wire
  `StatsView` into the tab switch. Add pbxproj entries for both new Swift files.

### Acceptance criteria
- "Stats" tab appears in the tab bar between "Stash" and "Upload".
- On first visit the view shows a loading spinner, then populates the list.
- Each row shows bucket name (headline), object count (e.g. "1 234 objects"), and total size
  (formatted with the existing `formattedSize` approach: KB / MB / GB).
- Pull-to-refresh and the toolbar refresh button re-fetch all bucket stats.
- Empty bucket (0 objects) shows "0 objects · 0 KB".
- Inaccessible buckets are skipped silently (same pattern as `fetchRecentFilesFromAllBuckets`).
- Build clean; commit with message "feat: add bucket usage stats tab".

## Phase 18 - Bucket usage statistics dashboard (DONE)

- Added `BucketStats` struct in `Sources/Models.swift`: `objectCount`, `totalBytes`,
  `formattedSize` (KB/MB/GB), `formattedCount` (locale-formatted "N objects").
- Added `Sources/Services/S3Service+Stats.swift`: `fetchBucketStats()` scans all
  `availableBuckets` concurrently via `withTaskGroup`, paginating each bucket fully with
  `ListObjectsV2`. Inaccessible buckets return `nil` and are skipped. Results sorted by
  `totalBytes` descending.
- Added `Sources/StatsView.swift`: `@Observable StatsViewModel` owns `stats`, `isLoading`,
  `error`. The view is a `NavigationStack` with a summary section (total objects + size +
  bucket count) and a per-bucket `List`. Pull-to-refresh and a toolbar refresh button
  re-trigger `load()`. Loading / error / empty states use `ContentUnavailableView`.
- Added `stats` case to `AppTab` in `ContentView.swift` (icon `chart.bar`, between Stash
  and Upload) and wired `StatsView` into the tab switch.

Commit: `b877c7a` feat: add bucket usage stats tab

## Phase 19 - Search in BucketBrowserView (DONE)

- Added `@State private var searchText = ""` to `BucketBrowserView`.
- `sortedItems` gained a search filter step before sorting: when `searchText` is non-empty,
  folders match on `folderName` and files match on `fileName` (both case-insensitive
  substring). Folders are always shown when there is no active search; when a search is
  active they are filtered too so the results only show what matches.
- `.searchable(text: $searchText, prompt:)` added to the `NavigationStack`. The prompt
  dynamically reads the current prefix name or bucket name so it says "Search in photos/"
  rather than a static string.
- When search is active and `sortedItems` is empty, `ContentUnavailableView.search(text:)`
  replaces the normal empty state.
- `searchText` is cleared when the user navigates into a subfolder (inside the folder-tap
  `Button` action) so each level starts with a clean search bar.

Commit: `91c2a9b` feat: add in-prefix search to BucketBrowserView

## Phase 20 - Starred / favorited files (DONE)

- Added `Sources/StarStore.swift`: `@Observable` singleton backed by `UserDefaults.standard`
  key `"s3StarredKeys"` holding a `Set<String>` of S3 object keys. Exposes `toggle(_:)`,
  `isStarred(_:)`, and `starredKeys` (the full set). Persists on every mutation.
- `RecentFilesView`: each row and grid-card context menu gained a "Star" / "Unstar" item
  (star icon, bound to `StarStore.shared`). A "Starred" filter option added to the existing
  type/tag filter chain — when active, `filteredRecentFiles` only shows objects whose key is
  in `StarStore.shared.starredKeys`. A star chip in the filter bar (alongside the tag chips)
  toggles the starred filter on/off.
- `BucketBrowserView` file rows gained a "Star" / "Unstar" context-menu item so files can be
  starred while browsing. `FileRow` shows a small star badge (yellow fill) when the file is
  starred, using `StarStore.shared.isStarred(object.key)`.

Commit: `5e1a488` feat: add starred/favorited files

## Phase 21 - Grid view mode for BucketBrowserView (DONE)

- Added a third `ViewStyle` case `.grid` to `BucketBrowserView` alongside the existing
  `.standard` and `.compact` list styles.
- `@AppStorage("s3BrowserGridCardSize")` persists the card size (60-160 pt, default 100).
- When `.grid` is active the `List` is replaced with a `ScrollView` + `LazyVGrid`
  (`GridItem(.adaptive(minimum: cardSize))`). Each cell is a `BrowserGridItem` view:
  image files show a thumbnail (loaded from `ImageCacheActor` cache or downloaded);
  video files show the thumbnail with a play-circle badge; folders show a filled folder
  icon. All cells show the display name and — for files — formatted size below.
  Starred files show the yellow star badge (bottom-trailing corner) via `StarStore.shared`.
- The view-style menu in the trailing toolbar now has three options: Standard, Compact,
  Grid. When Grid is active a `Slider` for card size appears in the toolbar (same pattern
  as `RecentFilesView`).
- Pull-to-refresh works in grid mode via `refreshable` on the outer `ScrollView`.
- Swipe-to-delete and the file context menu (Star/Unstar, Copy Content, Share Link,
  Delete) are preserved; in grid mode they are attached to the `BrowserGridItem` via
  `.contextMenu` on the `NavigationLink` / `Button`.

Commit: `d66ba4f` feat: add grid view mode to BucketBrowserView

## Phase 22 - Save to Files export from FileDetailView (DONE)

- Added `@State private var exportURL: URL?` and `@State private var isExporting: Bool`
  to `FileDetailView`. When the user taps "Save to Files…", `prepareExport()` writes the
  file bytes to a uniquely-named temp file (`FileManager.default.temporaryDirectory /
  UUID-filename`) and sets `exportURL`, which drives a `.fileExporter` modifier that
  presents the system document picker so the user can choose any Files location.
- For file types where content is already loaded (`fileContent`), bytes are produced
  locally (text UTF-8, image PNG, video temp-file URL, HTML UTF-8) with no extra network
  call. For unknown types the raw bytes are downloaded fresh.
- The "Save to Files…" action (icon `arrow.down.doc`) appears:
  - In the `standardDetailView` trailing toolbar as a second button next to "Share Link".
  - In the `htmlPrimaryView` "…" menu alongside the existing "Share Link…" and
    "File Details" items.
- Export errors surface in a "Export Failed" alert. Temp files are written with the
  object's original filename so the Files app shows the correct name.

Commit: `0ca1d3e` feat: add Save to Files export to FileDetailView

## Phase 23 - Upload from BucketBrowserView (DONE)

- Added upload state (`isUploading`, `uploadProgress`, `uploadResult`, `showPhotoPicker`,
  `showFilePicker`, `selectedPhoto`) to `BucketBrowserView`, mirroring `PrefixBrowserView`.
- Added a `+` toolbar button (Menu with "Photo or Video" and "File" options) as a second
  `ToolbarItem` in the trailing area, disabled while uploading or when not configured.
- Added `uploadStatusBar` as a `.safeAreaInset(edge: .bottom)` overlay (identical pattern
  to `PrefixBrowserView`): shows a linear progress view while uploading and a
  success/failure row with a dismiss button after completion.
- `handlePhotoPickerItem`, `handleFileImport`, and `upload(data:filename:contentType:)`
  are ported directly from `PrefixBrowserView`, with the key built as
  `s3Service.currentPrefix + filename` so files land in the currently browsed prefix.
  On success the listing reloads automatically via `refreshFiles()`.
- `.photosPicker` and `.fileImporter` modifiers added to `NavigationStack`.

Commit: `7a87094` feat: add upload to BucketBrowserView

## Phase 24 - Rename files in BucketBrowserView (DONE)

- Added rename state (`renameTarget: S3Object?`, `renameText: String`, `showRenameError`,
  `renameErrorMessage`) to `BucketBrowserView`.
- `fileContextMenuItems(for:)` gained a "Rename…" item (pencil icon) that pre-fills
  `renameText` with the current `fileName` and sets `renameTarget`.
- A `.alert("Rename File", isPresented:)` driven by `renameTarget != nil` presents a
  `TextField` pre-filled with the current filename, plus Rename and Cancel buttons.
  On confirm the new name is joined back onto the original key's directory prefix so the
  file stays in its folder (same logic as `RecentFilesView.renameFile`).
- `renameFile(_:to:)` calls `s3Service.renameObject(key:to:bucket:)` and on success
  calls `refreshFiles()` to update the listing. Failure surfaces in a "Rename Failed"
  alert via `showRenameError` / `renameErrorMessage`.

Commit: `28b2a85` feat: add file rename to BucketBrowserView

## Phase 25 - Cache management and data reset in SettingsView (DONE)

- Added `diskCacheSize() -> Int64` to `ImageCacheActor`: sums `fileSize` attributes of
  all files under `thumbnailCacheDirectory`, returns total bytes.
- Added `clearAll()` to `StarStore`: removes all starred keys from `starredKeys` and
  persists the empty set.
- Added `TagStore.clearAll()`: removes all tags from the dict and persists.
- `SettingsView` gained a "Storage & Cache" `Form` section showing:
  - "Image Cache" row: disk size formatted as KB/MB, with a "Clear" button that calls
    `ImageCacheActor.shared.clearCache()` and refreshes the size display.
  - "Stars" row: count of starred files, with a "Clear" button calling
    `StarStore.shared.clearAll()`.
  - "Tags" row: count of tagged files, with a "Clear" button calling
    `TagStore.shared.clearAll()`.
  Each clear button is guarded by a `.confirmationDialog` to prevent accidental taps.
  Cache size is loaded on `.task` and refreshed after each clear. All counts read live
  from the `@Observable` singletons so they update immediately.

Commit: `cbce369` feat: add cache management section to SettingsView

## Phase 26 - Move/copy and delete error feedback in BucketBrowserView (DONE)

- Added move/copy to `BucketBrowserView` file context menus using the existing
  `PrefixPickerSheet`. Added state `moveCopyTarget: S3Object?`, `moveCopyMode`,
  `showMoveCopyError`, `moveCopyErrorMessage`. "Move to…" and "Copy to…" items added
  to `fileContextMenuItems(for:)`. A `.sheet(item: $moveCopyTarget)` presents
  `PrefixPickerSheet`; on confirm `performMoveCopy(object:destPrefix:)` calls
  `s3Service.copyObject` then optionally `deleteObject`, then `refreshFiles()`.
- Added delete error feedback: `showDeleteError` / `deleteErrorMessage` state added;
  `deleteObject(_:)` now surfaces failures in a "Delete Failed" alert via
  `.deleteErrorAlert(isPresented:message:)` (the shared modifier from Phase 3).

Commit: `0302368` feat: add move/copy and delete error alert to BucketBrowserView

## Phase 27 - Search and sort in PrefixBrowserView (DONE)

- Added `@State private var searchText = ""` and `@State private var sortOption:
  PrefixSortOption = .nameAZ` to `PrefixBrowserView`.
- `PrefixSortOption` enum with four cases: `nameAZ`, `nameZA`, `dateNewest`,
  `dateOldest`. Folders always sort before files within each option.
- `displayedItems` computed var: filters `items` by case-insensitive `displayName`
  substring when `searchText` is non-empty, then applies the active sort.
- The `List` now iterates `displayedItems` instead of `items`.
- `ContentUnavailableView.search(text: searchText)` replaces the list when
  `displayedItems` is empty and a search is active.
- `.searchable(text: $searchText, prompt: "Search in \(title)")` added to the view body.
- Sort `Menu` button (`arrow.up.arrow.down`) added to the trailing toolbar next to the
  existing upload `+` button. Active sort shows a checkmark.
- `searchText` is not cleared on load so it persists while the user browses the same level.

Commit: `f308b81` feat: add search and sort to PrefixBrowserView

## Phase 28 - Grid view in PrefixBrowserView (DONE)

- Added `@AppStorage("prefixBrowserViewStyle") private var viewStyle: ViewStyle = .list`
  to `PrefixBrowserView`; reuses the existing `ViewStyle` enum from `BucketBrowserView`.
- The `else` branch (items non-empty, no error, not loading) now dispatches on `viewStyle`:
  `.list` renders the existing `List`; `.grid` renders a `LazyVGrid` inside a `ScrollView`
  with `GridItem(.adaptive(minimum: cardSize))` columns.
- `@AppStorage("prefixBrowserGridCardSize") private var cardSize: Double = 120` controls
  the thumbnail cell size; a `Slider(value: $cardSize, in: 80...200)` in the toolbar is
  shown only when `viewStyle == .grid`.
- Grid cells reuse `BrowserGridItem` from `BucketBrowserView.swift` (it is file-scoped
  but accessible because both files are in the same module/target).
- A `list.bullet` / `square.grid.2x2` toolbar toggle button switches modes.
- The grid supports pull-to-refresh via `.refreshable { await load() }` and shows the
  "Load more" row at the bottom just like the list.

Commit: `04aaa6a` feat: add grid view to PrefixBrowserView

## Phase 29 - Batch select and bulk delete in BucketBrowserView (DONE)

- Added `@State private var isSelecting = false` and `@State private var selectedKeys: Set<String> = []`
  to `BucketBrowserView`.
- "Select" toolbar button (`.topBarLeading`) enters selection mode. "Cancel" exits and clears selection.
- In list mode: file rows show a leading circle / filled-checkmark based on selection state. Tapping a row
  toggles its key in `selectedKeys` rather than navigating; `NavigationLink` is omitted while `isSelecting`.
- In grid mode: selected cells show a checkmark overlay in the top-leading corner.
- A "Delete (N)" `Button(role: .destructive)` appears in the toolbar (`.topBarTrailing`) only when
  `isSelecting && !selectedKeys.isEmpty`. Tapping it shows a `.confirmationDialog` listing the count.
  On confirm, `bulkDelete()` calls `s3Service.deleteObject` concurrently with `withThrowingTaskGroup`,
  removes successfully-deleted keys from `items`, and shows a partial-failure summary if some failed.
- "Select All" / "Deselect All" toolbar button added to leading toolbar while in selection mode.
- `isSelecting` is automatically reset to false after bulk delete completes.
- Folder rows are excluded from selection; only file rows are selectable.

Commit: `9bcff10` feat: batch select and bulk delete in BucketBrowserView

## Phase 30 - Batch select and bulk delete in PrefixBrowserView (DONE)

- Added `@State private var isSelecting = false`, `selectedKeys: Set<String>`, `showBulkDeleteConfirm`,
  `isBulkDeleting` to `PrefixBrowserView`.
- "Select" button (`.topBarLeading` when not in selection mode) enters selection mode.
  "Cancel" exits and clears the selection set.
- "Select All" / "Deselect All" toggle in the leading toolbar during selection mode.
- In list mode: file rows become tap-to-toggle buttons with a circle / filled-checkmark indicator.
  Swipe-to-delete and context menus are hidden while selecting. Folder rows stay tappable but skip
  navigation when `isSelecting`.
- In grid mode: file cells show a checkmark overlay in the top-leading corner.
- "Delete (N)" destructive button in trailing toolbar during selection. Triggers a `.confirmationDialog`
  then calls `bulkDelete()` which fans out deletions concurrently, removes succeeded keys from
  `items`, then reports partial-failure count via the existing "Delete Failed" alert.
- Selection cleared on each `load()` call so navigating back and refreshing starts fresh.
- `viewStyleToggle` and `sortMenuButton` hidden during selection to reduce toolbar crowding.

Commit: `31f48d5` feat: batch select and bulk delete in PrefixBrowserView

## Phase 31 - Drag-and-drop upload in BucketBrowserView (DONE)

- Added `@State private var isDragTargeted = false` to `BucketBrowserView`.
- `.onDrop(of: [.fileURL, .data], isTargeted: $isDragTargeted)` attached to the `Group`
  content area so the entire browser surface accepts drops.
- When `isDragTargeted` is true an `.overlay` shows a semi-transparent blue rectangle with
  a rounded border and an `arrow.down.doc` label — visible as long as the drag hovers.
- Drop handler `handleDrop(providers:)` iterates each `NSItemProvider` and loads either
  `.fileURL` (preferred) or `.data` (fallback). For URL items it reads the file with
  security-scoped access; for raw-data items it uses the `suggestedName` as the filename.
  Content-type is inferred via `UTType(filenameExtension:)?.preferredMIMEType` with
  `application/octet-stream` as fallback. Each item fans out to the existing
  `upload(data:filename:contentType:)` function which targets `currentPrefix + filename`.
- Multiple dropped files are processed concurrently via `withTaskGroup`.
- The modifier is gated on `isConfigured` so it is a no-op before credentials are set.

Commit: `cdfc2ab` feat: add drag-and-drop upload to BucketBrowserView

## Phase 32 - New Folder creation in BucketBrowserView and PrefixBrowserView (DONE)

- Added `func createFolder(named:) async throws` to `S3Service` (in `S3Service+Transfer.swift`):
  PUTs a zero-byte object at `currentPrefix + name + "/"` with `content-type: application/x-directory`
  so S3 treats it as a virtual folder.
- `BucketBrowserView`: "New Folder" item added to the existing `+` upload `Menu`. Drives a new
  `.alert("New Folder")` with a `TextField` for the name. On confirm calls `s3Service.createFolder`
  then `refreshFiles()`. Name is validated (non-empty, no `/`) before the call; an error alert
  surfaces any service failure.
- `PrefixBrowserView`: same "New Folder" menu item added to the existing `+` `Menu` upload button,
  same alert + validation flow, calls `s3Service.createFolder` then `load()`.
- Both views show a "Create Failed" alert on error.

Commit: `c345f18` feat: add new folder creation to browser views

## Phase 33 - Multi-bucket quick-switcher overlay (DONE)

- Added `BucketSwitcherOverlay` view (new file `Sources/BucketSwitcherOverlay.swift`): a bottom
  sheet-style overlay that slides up from the bottom over the `ContentView` `ZStack`. Lists all
  `availableBuckets` from `s3Service`. For each bucket shows the bucket name, a checkmark on the
  active bucket, and a cached object count fetched lazily on first open via a lightweight
  `ListObjectsV2` with `maxKeys: 1000` (reports exact count or "1000+" if truncated). Tapping a
  row calls `s3Service.switchBucket`, animates the selection, dismisses the sheet, and switches
  the tab to `.browse`.
- `ContentView`: added `@State private var showBucketSwitcher = false`. A pill-shaped
  `cylinder.split.1x2` button floats above the custom tab bar (inside the `ZStack`, pinned to
  `.bottom` with padding) and is only visible when `s3Service.availableBuckets.count > 1`.
  The overlay is presented via a conditional in the `ZStack` with a `.transition(.move(edge: .bottom)
  .combined(with: .opacity))` animation.
- Object counts are stored in `@State private var bucketCounts: [String: Int]` inside
  `BucketSwitcherOverlay` and fetched once per open via `withTaskGroup` using a single-page listing.

Commit: `c69c866` feat: add multi-bucket quick-switcher overlay

## Phase 34 - Copy as Data URL for image objects in FileDetailView (DONE)

- `FileDetailView`: added `@State private var isCopyingDataURL = false` and `@State private var datURLCopyDone = false`.
- Computed var `isImageObject: Bool` checks the key extension against jpg/jpeg/png/gif/webp (case-insensitive).
- When `isImageObject` is true, a "Copy as Data URL" button appears in the `ImageContentView` action row.
  Tapping it downloads the object bytes (or reuses already-loaded `UIImage` png data), base64-encodes them,
  assembles `data:image/<ext>;base64,<data>`, and places that on `UIPasteboard.general`.
- A `ProgressView` spinner replaces the button while the download is in progress.
- A brief "Copied!" confirmation text appears for 1.5 seconds after success.
- The download uses `service.downloadObject` directly; if the image is already loaded in `fileContent`
  it reuses the PNG data to avoid a second network call.

Commit: `89cfbcf` feat: add copy-as-data-url for image objects

## Phase 35 - Object expiry date from lifecycle rules in FileDetailView (DONE)

- `S3ObjectMetadata`: added `expirationDate: String?` field.
- `S3Service.headObject`: reads the `x-amz-expiration` response header value and stores it in
  `expirationDate`. Parses the `expiry-date="..."` portion from the header and converts it to a
  human-readable date string.
- `FileDetailView.metadataCard`: added an "Expires" row showing the parsed date or "No expiry"
  after the ETag row.

Commit: `89cfbcf` feat: add copy-as-data-url for image objects (landed in same commit as Phase 34)

## Phase 36 - Local download cache with Open-in action in FileDetailView (DONE)


- `FileDetailView`: added `@State private var isDownloadingToCache = false` and
  `@State private var cachedFileURL: URL?`.
- `cacheDirectory`: computed as `FileManager.default.temporaryDirectory/s3cache/<sanitized-key>`.
- A "Save to Cache / Open in..." button appears in the toolbar for all file types.
- On tap: if `cachedFileURL` already points to an existing file, goes straight to presenting
  `UIActivityViewController`. Otherwise downloads via `service.downloadObject`, writes to
  `cacheDirectory`, then presents the share sheet.
- A `ProgressView` spinner replaces the button while downloading.
- Deduplicates re-download by checking `FileManager.default.fileExists(atPath:)` on the cache path.

Commit: `89cfbcf` feat: add copy-as-data-url for image objects (landed in same commit as Phase 34)

## Phase 37 - S3 object version browser in FileDetailView (DONE)

- Added `S3VersionEntry` struct to `Models.swift`: `versionId`, `lastModified`, `size`, `isLatest`,
  `formattedSize` computed var.
- `S3Service+Transfer.swift`: added `listObjectVersions(key:bucket:)` - calls `ListObjectVersionsInput`
  with `prefix: key`, filters results to exact key matches, returns `[S3VersionEntry]` sorted newest
  first. Returns an empty array silently when versioning is not enabled.
- `S3Service+Transfer.swift`: added `restoreVersion(key:versionId:bucket:)` - issues `CopyObjectInput`
  with `copySource: "<bucket>/<key>?versionId=<id>"` to copy the named version back to the same key,
  making it the current version.
- `FileDetailView`: added `versions`, `isLoadingVersions`, `restoringVersionId`,
  `showRestoreConfirm`, `pendingRestoreVersionId` state. `loadVersions()` and `restoreVersion(versionId:)`
  are both called from `.task` alongside `loadFile` and `loadMetadata`.
- `versionsSection` `@ViewBuilder`: shows nothing when there is only one version, shows a spinner
  while loading, and shows a list of version rows when count > 1. Each row shows a truncated version
  ID, "LATEST" badge, relative date, size, and a "Restore" button (hidden on the latest). Tapping
  "Restore" fires a `confirmationDialog` before calling `restoreVersion`, then refreshes the list.

Commit: `c78d395` feat: add object version browser to FileDetailView

## Phase 38 - Change storage class action in FileDetailView (DONE)

- `S3Service+Transfer.swift`: added `changeStorageClass(key:storageClass:bucket:)` — issues a
  `CopyObjectInput` copying the object to itself with the new `storageClass` and
  `metadataDirective: .copy` to preserve all existing metadata.
- `FileDetailView`: added `showStorageClassPicker`, `isChangingStorageClass`, `storageClassError`,
  `showStorageClassError` state vars.
- `storageClassMenu` `@ViewBuilder`: a `Menu` button ("Storage Class") listing the six user-facing
  tiers (STANDARD, INTELLIGENT_TIERING, STANDARD_IA, ONEZONE_IA, GLACIER_IR, GLACIER,
  DEEP_ARCHIVE). The current storage class is shown with a checkmark. Disabled while a change is
  in flight. Appears in the standard detail toolbar `...` menu and the HTML "..." menu.
- After a successful change, `loadMetadata()` is called to refresh the Storage Class row in the
  metadata card.

Commit: `c2da97a` feat: add change-storage-class action to FileDetailView

## Phase 39 - S3 object tag editor in FileDetailView (DONE)

- `S3Service+Transfer.swift`: added `getObjectTags(key:bucket:)` returning `[(key:String,value:String)]`
  via `GetObjectTaggingInput`, and `setObjectTags(key:tags:bucket:)` issuing `PutObjectTaggingInput`
  with a `S3ClientTypes.Tagging` wrapping the new tag set.
- `FileDetailView`: added `objectTags`, `isLoadingTags`, `isEditingTags`, `editableTags`,
  `isSavingTags`, `tagsError`, `showTagsError` state. `loadTags()` runs in `.task` alongside
  `loadFile`/`loadMetadata`/`loadVersions`.
- `tagsSection` `@ViewBuilder`: shown in `standardDetailView` below `versionsSection`. Displays a
  "Tags" header with an "Edit" button. In view mode: a flat list of `key=value` rows (or "No tags"
  placeholder). In edit mode: `TextField` pairs per tag with per-row delete buttons and an "Add Tag"
  row, followed by Save/Cancel toolbar buttons. Save calls `setObjectTags` then reloads.
- Error surfaced via `.alert("Tag Save Failed")`.

Commit: `3d7ca24` feat: add S3 object tag editor to FileDetailView

## Phase 40 - Rename file in PrefixBrowserView (DONE)

- `PrefixBrowserView`: added `renameTarget: S3Object?`, `renameText: String`, `showRenameError: Bool`,
  `renameErrorMessage: String` state vars.
- Leading swipe action (`edge: .leading`) on each file row shows a "Rename" button (pencil icon,
  orange tint). Tapping pre-fills `renameText` with `object.fileName` and sets `renameTarget`.
- "Rename" entry added to the existing file context menu alongside Move/Copy/Delete.
- `.alert("Rename File")` presents a `TextField` pre-filled with the current name; on confirm,
  builds the new key by replacing the filename within the current prefix and calls
  `s3Service.renameObject(key:to:bucket:)`, then reloads. On failure, shows a second
  `.alert("Rename Failed")`.
- `renameFile(_:to:)` async func: calls `s3Service.renameObject`, then `await load()` to refresh.

Commit: `9ba0504` feat: add rename to PrefixBrowserView file rows

## Phase 41 - Batch download to Files app in BucketBrowserView (DONE)

- `BucketBrowserView`: added `isBatchDownloading: Bool`, `batchDownloadProgress: Int`,
  `batchDownloadTotal: Int`, `batchDownloadError: String?`, `showBatchDownloadError: Bool`,
  `batchDownloadURLs: [URL]?`, `showBatchDownloadShare: Bool` state vars.
- In the selection toolbar (trailing, when `isSelecting && !selectedKeys.isEmpty`), added a
  download button (arrow.down.to.line icon) beside the delete button. Disabled while
  `isBatchDownloading`.
- `batchDownload()` async func: iterates `selectedKeys` concurrently via `withTaskGroup`,
  calls `s3Service.downloadObject(key:bucket:)` for each, writes each `Data` to
  `FileManager.default.temporaryDirectory/s3cache/<sanitized-key>`, collects `[URL]`.
  On completion sets `batchDownloadURLs` and `showBatchDownloadShare = true`. Failed keys
  accumulate; if any failed after all succeed, shows `.alert("Download Failed")`.
- Progress shown in the existing `uploadStatusBar`-style bottom bar while downloading: "Downloading
  N / total..." text with a `ProgressView` value of `batchDownloadProgress / batchDownloadTotal`.
- `ActivityView` (already in project from Phase 35) presented as a `.sheet` on
  `showBatchDownloadShare` with the array of file `URL`s so iOS presents the standard
  Files / AirDrop / share sheet.
- After share sheet dismisses, `batchDownloadURLs` is cleared and selection mode exits.

Commit: `a58f009` feat: add batch download to Files app in BucketBrowserView

## Phase 42 - Object ACL viewer in FileDetailView (DONE)

- `S3Service+Transfer.swift`: added `getObjectAcl(key:bucket:)` returning a new `S3ObjectACL`
  struct. Calls `GetObjectAclInput(bucket:key:)`, maps each `S3ClientTypes.Grant` to an
  `ACLGrant` value (grantee display name + permission label). Derives a top-level `summary`
  string: `"Public (read)"` when the All Users group URI
  (`http://acs.amazonaws.com/groups/global/AllUsers`) has READ permission, `"Private"` when
  only the owner appears, otherwise `"Custom (\(n) grants)"`.
- `Models.swift`: added `struct S3ObjectACL` with `summary: String` and
  `grants: [ACLGrant]`; `struct ACLGrant: Identifiable` with `grantee: String` and
  `permission: String`.
- `FileDetailView.swift`: added `objectACL: S3ObjectACL?`, `isLoadingACL: Bool`,
  `aclError: String?` state vars. `loadACL()` runs in `.task` alongside the other four
  loaders. `aclSection` `@ViewBuilder` shows below `tagsSection`: a "Permissions" header
  with the summary string as a `MetadataRow`, then a disclosure group "Show grants" revealing
  per-grant rows (`grantee - permission`). Error state shows inline. Loading state shows a
  spinner. If the bucket has ACLs disabled (Object Ownership enforced) the API returns
  `AccessControlListNotSupported`; this is caught and shown as "ACLs disabled on this bucket".

Commit: `0865900` feat: add object ACL viewer to FileDetailView

## Phase 43 - Upload queue with retry support (DONE)

- `Sources/UploadQueueManager.swift`: `@globalActor UploadQueueActor` owns a shared
  `UploadQueueManager` (`@Observable final class`). Each pending upload is an `UploadItem`
  (`Identifiable`, `@Observable`) with `id: UUID`, `filename: String`, `key: String`,
  `bucket: String`, `contentType: String`, `data: Data`, `state: UploadItemState`
  (`.pending`, `.uploading(progress: Double)`, `.done`, `.failed(String)`), and
  `retryCount: Int`. `UploadQueueManager` exposes `items: [UploadItem]`, `pendingCount: Int`,
  `failedCount: Int`, and `activeCount: Int`. `enqueue(_:)` appends an item and immediately
  calls `processNext()`. `processNext()` finds the first `.pending` item, sets it to
  `.uploading(0)`, calls `s3Service.uploadObject(data:key:contentType:onProgress:)`, then
  marks `.done` or `.failed`. After each item completes, calls `processNext()` again (serial
  queue). `retry(id:)` resets a `.failed` item to `.pending` and calls `processNext()`.
  `removeCompleted()` drops all `.done` items.
- `Sources/UploadQueueSheet.swift`: SwiftUI sheet view showing the queue. A `List` of
  `UploadItem` rows: filename, key truncated to last component, state badge (pending gray,
  uploading spinner + %, done green checkmark, failed red x with error message). Failed rows
  get a "Retry" button. A "Clear Done" toolbar button calls `removeCompleted()`. Empty state
  shows `ContentUnavailableView`. The existing upload flows in `BucketBrowserView` and
  `PrefixBrowserView` continue to work unchanged.
- `ContentView.swift`: added `@State private var showUploadQueue = false`. A toolbar overlay
  button (bell or tray icon) visible when the queue has pending or active items shows a badge
  with `pendingCount + activeCount`. Tapping opens `UploadQueueSheet` as a `.sheet`. The
  queue manager instance is passed as an `@Environment` value so child views can enqueue.

Commit: `807d2e1` feat: add upload queue with retry support

## Phase 44 - Bucket Policy viewer in SettingsView (DONE)

- `S3Service+Stats.swift`: added `fetchBucketPolicy(bucket:) async -> String?`. Calls
  `GetBucketPolicyInput(bucket:)`, returns `output.policy`. Returns nil on
  `NoSuchBucketPolicy`, `AccessDenied`, or any other error — all treated as "no policy".
- `SettingsView`: added `@State private var policyJSON: String?` and `isPolicyLoading`.
  New "Bucket Policy" `Section` above "Storage & Cache": shows a `ProgressView` while
  loading, a scrollable monospaced `Text` (`.textSelection(.enabled)`, max height 260 pt)
  when a policy is present (pretty-printed via `JSONSerialization` with `.sortedKeys`),
  or "No policy configured" in secondary color when nil. A "Refresh" button re-triggers
  `loadBucketPolicy()`. `.task(id: config.bucketName)` reloads automatically when the
  bucket name changes in the form.

Commit: `6e9a666` feat: add bucket policy viewer to settings

## Phase 45 - Lifecycle Rules viewer in SettingsView (DONE)

- `Models.swift`: added `LifecycleTransitionDisplay` (`days`, `storageClass`) and
  `LifecycleRuleDisplay` (`id`, `status`, `expirationDays`, `transitions`, `isEnabled`).
- `S3Service+Stats.swift`: added `fetchLifecycleRules(bucket:) async -> [LifecycleRuleDisplay]`.
  Calls `GetBucketLifecycleConfigurationInput(bucket:)`, maps each `LifecycleRule` to a
  `LifecycleRuleDisplay`. Returns empty array on `NoSuchLifecycleConfiguration`, `AccessDenied`,
  or any other error.
- `SettingsView`: added `lifecycleRules`, `isLifecycleLoading`, `lifecycleLoaded` state.
  New "Lifecycle Rules" `Section` between "Bucket Policy" and "Storage & Cache": shows a
  spinner while loading, "No lifecycle rules configured" when empty, or one `DisclosureGroup`
  per rule showing ID + enabled/disabled status badge in the label, and expiration days plus
  transition rows inside. A "Refresh" button and `.task(id: config.bucketName)` auto-reload
  on bucket name change.

Commit: `9b936a9` feat: add bucket lifecycle rules viewer to settings

## Phase 46 - Bucket CORS Rules viewer in SettingsView (DONE)

- `Models.swift`: added `CORSRuleDisplay` (`id`, `allowedOrigins`, `allowedMethods`,
  `allowedHeaders`, `exposeHeaders`, `maxAgeSeconds`).
- `S3Service+Stats.swift`: added `fetchCORSRules(bucket:) async -> [CORSRuleDisplay]`.
  Calls `GetBucketCorsInput(bucket:)`, maps each `S3ClientTypes.CORSRule` to a
  `CORSRuleDisplay` (falling back to "Rule N" when no id is set). Returns empty array
  on `NoSuchCORSConfiguration`, `AccessDenied`, or any other error.
- `SettingsView`: added `corsRules`, `isCORSLoading`, `corsLoaded` state. New "CORS Rules"
  `Section` between "Lifecycle Rules" and "Storage & Cache": spinner while loading,
  "No CORS rules configured" when empty, or one `DisclosureGroup` per rule showing id
  as label and origins, methods, allowed headers, expose headers, and max-age inside.
  "Refresh" button and `.task(id: config.bucketName)` auto-reload on bucket name change.

Commit: `5815d5f` feat: add bucket CORS rules viewer to settings

## Phase 47 - Bucket Replication Rules viewer in SettingsView (DONE)

- `Models.swift`: added `ReplicationRuleDisplay` (`id`, `status`, `destinationBucket`,
  `storageClass?`, `priority?`, `isEnabled` computed from status).
- `S3Service+Stats.swift`: added `fetchReplicationRules(bucket:) async -> [ReplicationRuleDisplay]`.
  Calls `GetBucketReplicationInput(bucket:)`, reads `output.replicationConfiguration.rules`,
  strips the `arn:aws:s3:::` prefix from the destination ARN to show the bare bucket name.
  Returns empty array on `ReplicationConfigurationNotFoundError`, `AccessDenied`, or any error.
- `SettingsView`: added `replicationRules`, `isReplicationLoading`, `replicationLoaded` state.
  New "Replication Rules" `Section` between "CORS Rules" and "Storage & Cache": spinner while
  loading, "No replication configured" when empty, or one `DisclosureGroup` per rule with id +
  enabled/disabled status badge as label, and destination bucket, storage class, and priority
  inside. "Refresh" button and `.task(id: config.bucketName)` auto-reload on bucket name change.

Commit: `fcbb281` feat: add bucket replication viewer to settings

## Phase 48 - CloudWatch Metrics viewer in SettingsView (DONE)

- `Models.swift`: added `BucketMetric` (`name`, `value`, `unit`, `id: String` computed from name).
- `Sources/Services/S3Service+Metrics.swift` (new file): added `fetchBucketMetrics(bucket:) async -> [BucketMetric]`.
  Calls `GetBucketMetricsConfigurationInput(bucket:)`, extracts metrics configuration ID
  and displays metric type (request count and data transfer). Returns empty array on
  `NoSuchMetricsConfiguration`, `AccessDenied`, or any error.
- `SettingsView`: added `metrics`, `isMetricsLoading`, `metricsLoaded` state. New "CloudWatch
  Metrics" `Section` between "Replication Rules" and "Storage & Cache": spinner while loading,
  "No metrics configured" when empty, or a scrollable `VStack` with metric entries showing
  metric name (caption, secondary color) and value (body, max 2 lines) separated by dividers.
  "Refresh" button and `.task(id: config.bucketName)` auto-reload on bucket name change.
- Added to Xcode project: `S3Service+Metrics.swift` registered in `project.pbxproj` with
  PBXBuildFile and PBXFileReference entries, and included in the Services group.

Commit: `bfb18fc` feat: add CloudWatch metrics viewer to SettingsView
