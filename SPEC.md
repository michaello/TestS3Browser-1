# TestS3Browser audit remediation specification

Approved by Mike on 2026-10-13 after the goal-forge interview. Contract generation is complete when these files are validated/delivered; implementing the app fixes is a separate explicitly started run.

## Goal and scope

Resolve all 85 distinct audit findings while preserving the existing SwiftUI app, browser/media workflows, app/share/widget/Shortcuts integrations and user data. The canonical item list is [AUDIT_QUEUE.json](AUDIT_QUEUE.json): F01-F36 and N01-N49. Five earlier findings include confirmed refinements; the two excluded audit candidates are not added back to this scope. Additional obligations E01 and E02 independently cover integrated Release verification and remote delivery.

The queue embeds every finding, source location, required behavior, concrete acceptance_behavior, per-ID verification command and proof requirements. An external audit report is provenance only and is not needed to execute this specification.

## Approved product behavior

- Last-successful account-scoped listings render before network responses; empty-cache loading remains explicit. Background refresh is allowed at most once per 60 seconds per listing identity. Explicit refresh forces freshness; duplicate active work joins or schedules the needed replacement. Successful mutations update/invalidate affected state without unnecessary whole-account scans.
- Rename/move/copy prompts before replacing an existing destination. Declining or an unknown conflict-check error causes no silent overwrite. Capture destination/account before asynchronous input loading. Failed tag reads cannot authorize replacement saves. Provider-supported conditions and honest partial/cancellation states are required; do not promise cross-request S3 atomicity or rollback that is unavailable.
- Clear All becomes an explicit Recent cache reset/rebuild, not remote deletion. Retain the last good snapshot until replacement succeeds. Finish and connect the existing upload queue rather than remove it: file-backed payloads, captured destination, retry/cancel and cleanup.
- Preserve exact account/bucket/key/version identity, original export bytes and truthful MIME types. Correct pagination, selection/filter reset, mutation/error states, gallery gestures, text lines, lifecycle/metrics/permissions information and widget delivery as required by the individual IDs.
- Preserve existing configuration, stars/tags, seen state and widget/shared snapshots through explicit migration. Native app credential storage is secured; local tests use fake stores and dummy values, never macOS CLI credential extraction.

## Architecture and implementation constraints

- The scope changes only when Mike changes it in words. Tool, format, progress or reporting instructions never shrink the 85-item queue. Easier activities, audits, summaries, release work and cleanup cannot substitute for an open item.
- Preserve existing SwiftUI features and the AWS SDK. Do not remove features, disable failing paths, return canned data, delete tests or narrow the queue to make completion easier. No new backend/provider or unrelated redesign/refactor. Add only the interfaces, storage, helpers and tests needed for these fixes.
- Destination collisions require confirmation before replacement. Capture account/bucket/prefix before awaited representation loading. Failed tag reads cannot authorize replacement writes. Use exact object/key/version identities rather than filenames, normalized paths or display labels.
- Show last-successful cached data before network results; automatic refresh starts at most once per 60 seconds per listing identity. Explicit refresh bypasses freshness, joins identical active work or schedules the required replacement without losing intent. Successful mutations may invalidate/update the affected snapshots without a redundant account scan.
- Clear All becomes an explicit Recent cache reset/rebuild, never S3 deletion. Keep good saved/visible data until a replacement succeeds. Finish/wire the existing upload queue; retain its feature rather than remove it.
- Isolate UI-facing mutable state to MainActor, transfer/cache work to explicit ownership boundaries, and validate request generations after awaits. Use structured/owned cancellation. Do not silence real isolation errors with unchecked Sendable or blanket preconcurrency annotations.
- Starting engineering limits: 4 app-owned body transfers per process; 3 bucket-metadata scans; 64 MiB decoded-image cache; 16 MiB speculative bytes with 2 MiB per speculative object; 512 MiB reusable original-file cache; at most current and two adjacent gallery originals, reduced by the byte policy. These are configurable tested ceilings, not claims of actual RSS. Downsample oversized images; do not let one item bypass the memory policy. Keep active file leases safe during eviction. Record any justified limit adjustment and its measured evidence.
- Preserve actual original bytes for export; use file-backed large transfers, collision-safe bounded local names, truthful MIME types and complete/explicit partial results. Do not add S3-side thumbnail/index objects or other live remote mutations for verification.
- Keep account-scoped migrations for metadata, stars/tags, seen state and shared/widget configuration. App runtime may use its secure credential store; regression tests use fake stores and dummy values. Never retrieve user credentials from Keychain in a macOS CLI/helper, print secrets, invoke credential loaders with Keychain fallbacks or click through prompts.
- Local regression checks must execute changed production modules/state/transport boundaries. Old extracted-method audit harnesses and source-pattern assertions are not final functional verification. Pure production modules or a minimal Apple-framework test host must remain runnable without fetching the AWS SDK. Relevant executable semantic/resource checks are allowed for accessibility and packaging, with runtime limits stated. Integrated real-SDK/app/UI verification is E01 only.
- No physical-device deployment, live S3 mutation, store upload/review, domain or remote-host work is required. Preserve backend API behavior in local fixtures; do not claim actual production or store verification.
- Never open/reveal artifacts, images, documents, reports, webpages or browsers. No desktop computer use, mouse/keyboard/pixel tools or permission prompts. Native simulator app/test-host launch for requested tests is allowed; inspect through test/CLI APIs with synthetic fixtures. Store screenshots in /tmp with YY-MM-DD-HH-MM-SS names; validate existence/size and report paths without opening.
- Every xcodebuild build uses an explicit IDE DerivedData path. Locate it from IDE metadata, or configure a consistent IDE path through CLI settings if absent. Never delete DerivedData or SPM caches. Simulator signing is disabled. Use tuist generate --no-open if Tuist becomes necessary.
- Preserve unrelated user changes and deliver the whole working tree as instructed. Do not stash, split or discard work. Commit/push finished work without a permission gate; do not create a pull request unless Mike explicitly requests one in that turn. No em dash in added code, comments, logs or strings.

## Likely files and modules

Repository: /Users/mike/Developer/test-projects/TestS3Browser-1
Audit source revision: ccd33ae (full revision is in AUDIT_QUEUE.json).
Canonical scope: AUDIT_QUEUE.json, implementation_items F01-F36 and N01-N49. All 85 items contain source locations, observed failure, required behavior, acceptance_behavior, verification command and proof requirements. The original audit/report outside this repository is provenance only; this contract does not depend on accessing it.
Read SPEC.md, AUDIT_QUEUE.json, applicable AGENTS.md and CLAUDE.md before edits.
Core paths: Sources/S3Service.swift; Sources/Services/S3Service+*.swift; Sources/Services/ImageCacheActor.swift; Sources/Models.swift; Sources/ContentView.swift; Sources/TestS3BrowserApp.swift.
Feature paths: Sources/BucketBrowserView.swift; Sources/PrefixBrowserView.swift; Sources/RecentFilesView.swift; Sources/FileDetailView.swift; Sources/ImageGalleryView.swift; Sources/ScreensDesignAppsView.swift; Sources/DumpFilesView.swift; Sources/StashView.swift; Sources/StatsView.swift; Sources/SettingsView.swift; picker/row/grid/tag/star files.
Integration paths: Sources/Intents/*.swift; Sources/Widget/TestS3BrowserWidget.swift; Sources/UploadQueueManager.swift; Sources/UploadQueueSheet.swift; Sources/DropUploadView.swift; ShareExtension/; WidgetExtension/; TestS3Browser.xcodeproj/project.pbxproj; Info.plist; entitlements; pinned Package.resolved.
Current baseline has no app test target or Swift test sources. Create scripts/verify_audit.py and production-linked tests as implementation work; the commands below are the required future interface, not checks claimed to exist now.
Discovery: rg --files Sources ShareExtension WidgetExtension; rg -n 'func |Task|listObjects|downloadObject|uploadObject|CopyObjectInput|recentUploads' Sources ShareExtension; git status --short.

## Edge cases and required fixtures

Use the matrix in GOAL.md verification_loop and every item acceptance_behavior. It includes delayed/offline/partial responses, account/path changes mid-request, shared downloads, 1,001+ objects/reports/versions, invalid counts, same keys across buckets, exact special/Unicode byte keys, long local names, short-second uploads, invalid media, provider errors, failed tag loads, destination conflicts, multipart success/failure/cancel, selection/filter changes, cache reset in flight, zoom/line handling, lifecycle filters/dates/UTC, shared migration, widget updates and resource/accessibility semantics.

Scope excludes a backend/index service, provider migration, unrelated redesign, physical-device proof, live S3 verification mutations, store submission, distribution signing, domains and new remote hosts. No routine in-scope work needs another approval. The approved cache/queue defaults are binding.

## User-approved done_when

Approval: Mike explicitly approved these criteria and product defaults on 2026-10-13. The 85 local items and the two access-gated items are independent obligations.

Tier 1 - Self-contained, F01-F36 and N01-N49:
- Every one of the 85 original IDs is retained in AUDIT_QUEUE.json and satisfies its own acceptance_behavior and done_when entries with recorded local regression evidence. Each ID command exits zero and writes artifacts/audit/ID.json. No generic pass-through or missing/unrun check may pass.
- python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --all exits zero, proves all 85 IDs are registered and exercised, and validates migrations, error/cancellation states, data integrity, request/byte limits and fixture outcomes. No feature deletion or unsupported scope reduction counts as resolution.
- Cached-display, 60-second refresh, overwrite confirmation, captured destinations, safe tag writes and exact identity behavior match the approved SPEC.md and each local regression case.
- scripts/verify_audit.py, the production-linked tests, machine-readable results and the final queue exist. Every local Done row records its tested source fingerprint/commit, commands, exit codes and retained proof paths. Accessibility/resource checks clearly distinguish semantic proof from unmeasured runtime layout.

Tier 2 - Access-gated, E01:
- python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --release-simulator passes a real pinned-SDK Release build for app/share/widget, integrated simulator tests and built-resource checks. artifacts/audit/E01.json retains build/test commands, .xcresult/log paths, SDK/runtime details and the tested app-source fingerprint.
- The tested app-source fingerprint matches delivered source. Ledger/log-only commits may follow; any app/build/test input change requires affected checks again. Never claim a stub/source-extraction check as a successful app build.
- Its mandatory fallback ladder is recorded on E01 in AUDIT_QUEUE.json. Failure blocks E01 alone, not the 85 local items.

Tier 2 - Access-gated, E02:
- All authorized work is committed/pushed to the configured remote branch and remote verification proves it contains the delivered app-source commit and final ledger. python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --delivery exits zero with retained evidence.
- Its mandatory fallback ladder is recorded on E02. Remote failure blocks only delivery. No PR is opened.

Whole-contract completion requires all current queue items Done. If all remaining obligations are genuinely Blocked - External after their ladders and rechecks, report incomplete with their exact failures; never use the complete signal.

## Verification and evidence

Create and test the following runner interface during implementation. It does not exist or pass merely because this spec names it:

```sh
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --id N02
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --all
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --release-simulator
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --delivery
```

Local functional checks execute changed production code through deterministic fake external boundaries. Do not copy/extract methods or inspect source strings to simulate functional proof. Semantic/resource checks may be appropriate for packaging/accessibility and must state their runtime limits. Keep local tests independent of SDK network availability. Real app/extension/UI integration with the pinned SDK is E01.

Each proof records ID, expected behavior, observed assertions, exact command/exit code, tested source identity and retained artifact paths under artifacts/audit/. Original audit harnesses are diagnostic seeds, not final implementation verification. Missing/unrun/stale evidence fails. Documented/ledger-only commits may follow the tested app-source revision; app/test/build input changes require affected checks again.

## External dependency sweep and fallback

Before compilation, the sweep found only two required external dependencies: E01 needs pinned SDK/package sources plus the installed simulator integration environment; E02 needs Git remote reachability/existing authorized authentication. Both have mandatory fallback ladders in AUDIT_QUEUE.json and GOAL.md. Neither can gate the 85 local items. The earlier SDK fetch timeout is diagnostic history, not a pre-marked blocker. Run actual commands before declaring external failure.

The absence of store/device/live-S3 credentials is not a blocker because those checks are excluded. If an unforeseen external proof obligation appears, preserve the local item and split only the unavailable proof into a new independently checkable E item with a fallback; retain the total scope and every obligation.

## Queue and execution

Allowed status values are Open, In Progress, Done and Blocked - External. All 87 items start Open. Consider executable local items before E items. Within that tier, resume the lowest-order In Progress item first, otherwise choose the lowest-order Open item. Initial item: N02. Write proof/status before moving on. A shared fix may close several IDs only after each ID's actual check passes.

Run this working count/next command at the start and end of every execution turn:

```sh
python3 -c 'import json,collections; d=json.load(open("/Users/mike/Developer/test-projects/TestS3Browser-1/AUDIT_QUEUE.json")); a=d["implementation_items"]+d["verification_delivery_items"]; c=collections.Counter(x["status"] for x in a); print(" | ".join(s+": "+str(c[s]) for s in d["allowed_statuses"])); n=next(iter(sorted((x for x in a if x["status"] in ("Open","In Progress")),key=lambda x:(x["tier"]!="Self-contained",x["status"]!="In Progress",x["order"]))),None); print("Next: "+(n["id"] if n else "none"))'
```

A blocker on one item means work everything else. A run may stop incomplete only when every residual item is individually Blocked - External with a failing command/output, completed fallback and a final recheck. Whole-contract completion requires all obligations Done. Never trade implementation for summaries or release activity.

Recommended run path: a fresh coding session instructed to execute GOAL.md. No app implementation is started by generating or approving these files.
