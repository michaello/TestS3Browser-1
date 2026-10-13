<goal>
Resolve all 85 approved TestS3Browser audit findings with preserved SwiftUI features, deterministic local regression proof, a real Release simulator integration build and verified Git delivery. Use AUDIT_QUEUE.json as the fixed scope and completion ledger. The source work begins at N02; contract approval is not evidence that implementation has started.
</goal>

<context>
Repository: /Users/mike/Developer/test-projects/TestS3Browser-1
Audit source revision: ccd33ae (full revision is in AUDIT_QUEUE.json).
Canonical scope: AUDIT_QUEUE.json, implementation_items F01-F36 and N01-N49. All 85 items contain source locations, observed failure, required behavior, acceptance_behavior, verification command and proof requirements. The original audit/report outside this repository is provenance only; this contract does not depend on accessing it.
Read SPEC.md, AUDIT_QUEUE.json, applicable AGENTS.md and CLAUDE.md before edits.
Core paths: Sources/S3Service.swift; Sources/Services/S3Service+*.swift; Sources/Services/ImageCacheActor.swift; Sources/Models.swift; Sources/ContentView.swift; Sources/TestS3BrowserApp.swift.
Feature paths: Sources/BucketBrowserView.swift; Sources/PrefixBrowserView.swift; Sources/RecentFilesView.swift; Sources/FileDetailView.swift; Sources/ImageGalleryView.swift; Sources/ScreensDesignAppsView.swift; Sources/DumpFilesView.swift; Sources/StashView.swift; Sources/StatsView.swift; Sources/SettingsView.swift; picker/row/grid/tag/star files.
Integration paths: Sources/Intents/*.swift; Sources/Widget/TestS3BrowserWidget.swift; Sources/UploadQueueManager.swift; Sources/UploadQueueSheet.swift; Sources/DropUploadView.swift; ShareExtension/; WidgetExtension/; TestS3Browser.xcodeproj/project.pbxproj; Info.plist; entitlements; pinned Package.resolved.
Current baseline has no app test target or Swift test sources. Create scripts/verify_audit.py and production-linked tests as implementation work; the commands below are the required future interface, not checks claimed to exist now.
Discovery: rg --files Sources ShareExtension WidgetExtension; rg -n 'func |Task|listObjects|downloadObject|uploadObject|CopyObjectInput|recentUploads' Sources ShareExtension; git status --short.
</context>

<constraints>
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
</constraints>

<done_when>
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
</done_when>

<work_queue>
- A blocker on one item means you work everything else. The run ends only when every remaining item is a blocker.
- The item list lives in /Users/mike/Developer/test-projects/TestS3Browser-1/AUDIT_QUEUE.json, arrays implementation_items and verification_delivery_items. Status field: status. Progress/proof/failure fields: proof, blocker and optional progress notes on the same item.
- Statuses: Open, In Progress, Done, Blocked - External. No other status words. Unproved work cannot be Done; use In Progress only for active work and Blocked - External only with demonstrated external failure.
- Count command, runnable now; run it at the start and end of every turn:
python3 -c 'import json,collections; d=json.load(open("/Users/mike/Developer/test-projects/TestS3Browser-1/AUDIT_QUEUE.json")); a=d["implementation_items"]+d["verification_delivery_items"]; c=collections.Counter(x["status"] for x in a); print(" | ".join(s+": "+str(c[s]) for s in d["allowed_statuses"])); n=next(iter(sorted((x for x in a if x["status"] in ("Open","In Progress")),key=lambda x:(x["tier"]!="Self-contained",x["status"]!="In Progress",x["order"]))),None); print("Next: "+(n["id"] if n else "none"))'
- Each turn: consider executable local items before E items. Within that tier, resume the lowest-order In Progress item first, otherwise pick the lowest-order Open item. Name its ID out loud, work it, verify it, atomically write status/proof, then take the next item in the same turn. Initial next item is N02.
- Write the result before starting the next item. An unwritten result counts as not done. Shared fixes may resolve several IDs, but run and record every affected ID check before marking any of them Done.
- Tier 1 items come first. Tier 2 items never gate tier 1 items. A real unknown product decision is isolated to the affected item while all other executable work continues.
- If the user restricts a tool or file format, keep the same queue and scope and change the mechanism. A recording restriction never changes what must be done.
- Do not substitute release proof, deploys, cleanup or summaries for the next open implementation item.
- Identical counts two turns running means the run has stalled. Name what is stuck, pick a different executable item and continue.
- End every report with the counts and next item ID. When none is executable, list every remaining blocked ID and its failing command/output/access need.
- If an unexpected external proof obligation must be split out, retain the original ID, preserve its scope and proof linkage, and append an independently checkable E item with its own fallback. Never remove the obligation or rename an unverified local item Done.
</work_queue>

<workflow>
1. Read context, check git status and run the count command. Confirm 85 audit IDs and approved defaults. Do not restart the audit or ask for already-approved scope.
2. Start N02. Establish only the minimal production-linked local verification interface needed for this first fix: scripts/verify_audit.py --id N02 and its failing regression. Add runner registry/--all/schema checks progressively; unavailable checks must fail, not be marked passing. Keep local test modules/test hosts independent of remote SDK fetching.
3. Work the ordered local queue. Protect tag saves, overwrites, destinations, shortcut identity and account/request state first; then cached display/catalogs, shared transfer/cache budgets, pagination/errors, remaining integration/UX/packaging and the finished queue/instrumentation. Use exact source locations and acceptance_behavior for each ID.
4. For each item: reproduce with deterministic fixtures, make the narrow production change, run focused checks, investigate/fix/retry failures, record proof and status, then continue. Verify affected previously Done items when shared interfaces change.
5. Add/test every runner mode end-to-end. --id rejects unknown IDs; --all checks every required ID/result without external credentials; --release-simulator runs E01; --delivery verifies E02 after an actual push. Proof records must match real process results and source inputs.
6. Run the full local suite and checks. Attempt E01 using exact pinned dependencies, installed simulator and IDE DerivedData. Test app/share/widget resource membership, migration compatibility and integrated error/refresh/selection/media flows. Record simulator timing/request/memory results without claiming phone measurements.
7. Commit and push finished authorized work, including the full working tree. Verify remote delivery. Record E02 proof and deliver the final proof ledger as a metadata-only commit if needed, verifying its push too. Avoid self-referential commit-hash requirements: record the delivered app-source commit/fingerprint and separately verify the final ledger commit.
8. Finish only when all obligations are Done, or when no executable item remains and every residual item has its own demonstrated external failure, completed fallback and recheck. Report counts and the next ID or all blocked IDs.
</workflow>

<verification_loop>
Required future runner interface (implement it; these commands are not claimed passing at contract creation):
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --id N02
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --all
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --release-simulator
python3 /Users/mike/Developer/test-projects/TestS3Browser-1/scripts/verify_audit.py --delivery

- For each ID: the expected fixture is its acceptance_behavior. Cover the old failure and at least the relevant success/error/cancellation boundary using changed production code, not a copied algorithm. Fake only external transport, clock, file/credential-store boundaries. No authenticated live S3 calls.
- Core fixture matrix: cached cold/revisit/offline/partial results; out-of-order account/prefix/filter responses; duplicate requests and byte bounds; 1,001+ listing/report/version entries; invalid counts; equal names/keys across accounts/buckets; special/Unicode/repeated-slash keys; short-second uploads; failed tag read; destination conflict accepted/declined/unknown; multipart success/failure/cancel; late provider input; export byte hashes and types; seen/filter/selection states; zoom reset; blank/CRLF text; lifecycle rule/date/UTC cases; widget/shared-config migration; resource and accessibility semantics.
- Retain deterministic clocks/gates and temporary isolated fixture stores. Clean test payloads and never touch production S3 objects or user credentials. Test file existence, sizes, signatures/hash outcomes and cleanup rather than trusting exit zero alone.
- Proof JSON includes id, expected behavior, actual assertions, command, exit code, source fingerprint/commit and log/artifact paths. The runner must fail for missing registry entries, stale evidence or tests that did not run. One fixture may support several IDs only when each has its own checked outcome/proof record.
- E01 uses xcodebuild with project /Users/mike/Developer/test-projects/TestS3Browser-1/TestS3Browser.xcodeproj, scheme TestS3Browser, configuration Release, simulator destination, explicit IDE DerivedData and CODE_SIGNING_ALLOWED=NO. The runner discovers/configures the matching IDE path without opening Xcode; no cache deletion. Build app/share/widget and run the integrated test scheme created for F36; retain .xcresult and built PrivacyInfo.xcprivacy checks.
- E02 verifies the configured origin/current branch contains delivered source and ledger commits. Source changes after verification invalidate affected results; documentation/ledger-only commits do not pretend to change compiled app inputs.
- If web-facing files or HTML reports are added, serve them locally and run curl -I and an HTML payload fetch, keep the verification server running, and report its URL without opening a browser.
- Run focused checks first and the full suite after shared changes. Once the relevant checks pass, repeat only for new changes, failures or unresolved concerns.
</verification_loop>

<blocker_policy>
- A blocker on one item means you work everything else. The run ends only when every remaining item is a blocker, each with its own failing command and output.
- A blocker is scoped to the exact done_when items it makes impossible. It never stops the rest of the run.
- If a blocker turns up inside an item, split the item: the part that finished is Done with its proof, and only the part needing the missing access becomes Blocked - External.
- Missing external access is never a reason to stop the run. This includes release or distribution signing, App Store Connect and TestFlight upload, store review, a physical device, a paid provider or API account, production credentials, an unreachable host, and approval from another person.
- When one is hit: run the fallback ladder for that item first, record the exact failing command and its output, mark only that item "Blocked - External", and continue with the next executable item in the same turn.
- Never swap remaining implementation work for release, deploy, or upload proof. Release evidence is one criterion, never the goal.
- Never call the whole goal blocked while any item can still move through source edits, local tests, fixtures, local services, or checks that do not need the missing access.
- Stopping is allowed only when every remaining item is marked "Blocked - External" and each one carries its own failing command, its output, and its recorded fallback evidence. Before that report, re-run each blocked item's command once to confirm it still fails, since a host or an account can come back. Then state which items are blocked and what access would unblock them.
- Do not mark an item blocked from a guess. Run the thing, quote what it printed, then mark it.
- Before writing any report that says blocked, print the status counts. If anything is still Open, the report is wrong. Work the next item instead.
- If many items block on the same missing access, the criteria were bundled wrong. Split the access-gated part into its own item and keep going on the rest.
- Repo-specific E01 ladder: use exact-version caches/installed runtimes; retry pinned resolution with bounded logged attempts while local work continues; run all package-independent production regressions/resource/syntax checks; retain the exact failing build command/output; recheck once before any external-only stop. Slowness alone is not proof of absent access. Never delete DerivedData/SPM caches, upgrade dependencies merely to bypass evidence or relabel a fake test as a real build.
- Repo-specific E02 ladder: use the configured remote/branch and existing authorized authentication; retry transient failure; keep finished work committed, retain the failed push and remote-check output; continue all executable work and recheck before any external-only stop. Do not retrieve credentials from Keychain or change access controls.
- Distribution signing, store accounts/review, physical devices and live production S3 are excluded, so their absence is not a blocker or a reason to widen the goal.
- If another external proof need genuinely appears, split only that proof into its own E item with a concrete command and fallback; retain all original local obligations and cross-reference the split. Do not park the 85-item queue behind one shared external step.
</blocker_policy>

<execution_rules>
- Check git status before edits.
- Preserve unrelated user changes.
- Prefer `rg` over `grep` when available.
- Use the Edit and Write tools for manual edits. Read a file before editing it.
- Read context files before implementation.
- Batch independent file reads and searches in parallel in a single message.
- Run focused tests before broad tests.
- Do not paper over failures.
- Do not widen scope.
- Name the `done_when` item being worked at the start of each turn, and write its result before starting the next one.
- A restriction on tools, file formats, or how progress is recorded changes the mechanism, never the scope.
- A blocker on one item means you work everything else. The run ends only when every remaining item is a blocker, each with its own failing command and output.
- A blocked item blocks only itself. Move to the next executable `done_when` item in the same turn.
- If a blocker turns up inside an item, split it: the finished part is done with its proof, only the access-gated part is blocked.
- Missing external access blocks only the criteria that need it. Signing, store upload, a physical device, a paid account, an unreachable host, or another person's approval never end the run.
- Do not stop while any `done_when` item is still executable through source edits, local tests, fixtures, or local services.
- Record the failing command and its output on the item you mark blocked. Never mark an item blocked from a guess.
- Do not pause for permission on work already inside the goal's scope.
- Keep the final answer concise.
- Current task is repository work; use explicit absolute paths. New app Swift code belongs under Sources; test/tool targets/helpers are allowed where the contract requires them. Read files before every edit and respect local AGENTS/CLAUDE constraints.
- Use applicable SwiftUI, Swift concurrency, persistence, accessibility and testing skill instructions when their work is reached. Independent subagent work is permitted by the repository instructions; give disjoint ownership and do not allow concurrent edits to the shared queue.
- Keep progress updates under 60-second gaps during active work. Reports state actual tests/builds/results and material limits, not suggestions that Mike should verify for you.
- Validate generated artifacts exist and have nonzero size, report absolute paths, and never auto-open them. No report --open, open, qlmanage, Finder reveals or browser/desktop automation.
- Run requested app tests/launches through supported CLI/test APIs. Use no CLI Keychain credential retrieval or fallback; fake stores and synthetic credentials suffice for this contract. Signing authorization does not authorize reading unrelated credentials.
- Do not create unsolicited documentation or add unrelated refactors. This contract authorizes SPEC.md, GOAL.md, the queue and necessary test/proof artifacts. Do not open a PR without an explicit current-turn request.
</execution_rules>

<output_contract>
- Final repository contains the fixed app/extension/integration code, production-linked tests, scripts/verify_audit.py, updated AUDIT_QUEUE.json and retained machine-readable evidence under artifacts/audit/.
- Every Done local item has a passing per-ID proof; E01 contains real Release build/integrated-test proof; E02 contains verified remote delivery. No item is closed by a summary, deleted feature, unexecuted test or substituted fixture-only app-build claim.
- Final response states concrete changes, actual focused/full test results, Release build status, delivered commit/remote state and absolute evidence paths. Distinguish local fixture proof from simulator integration and unperformed phone/live-S3/store work.
- Use COMPLETE only when all current queue items are Done. If the external-only stopping rule is reached, say INCOMPLETE, list every blocked item with its failing command/output and fallback evidence, and do not claim the goal achieved.
- Every progress/final report ends with counts for Open, In Progress, Done and Blocked - External, then the next executable ID. If there is no executable ID, state Next: none and enumerate all remaining blocked IDs with their exact failures. Never omit a remaining obligation.
</output_contract>
