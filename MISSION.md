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
