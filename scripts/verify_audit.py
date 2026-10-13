#!/usr/bin/env python3
"""Run production-linked regressions; absent/unexecuted audit checks fail closed."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts" / "audit"
SWIFT_SUITES = {
    "N02": ("AuditN02", 6),
    "N04": ("N04ShortcutIdentityTests", 5),
    "N03": ("N03ShortcutDeleteTests", 4),
    "N05": ("N05ObjectTransferTests", 10),
    "F25": ("F25SameObjectTransferTests", 3),
    "N01": ("N01UploadPreparationTests", 5),
    "N15": ("N15ShortcutCountTests", 5),
    "N26": ("AuditN26", 7),
    "N27": ("AuditN27", 2),
    "N29": ("AuditN29", 3),
    "N45": ("N45HTMLDocumentTests", 3),
    "N47": ("N47NumberedTextTests", 3),
    "N28": ("AuditN28", 7),
    "F17": ("F17UploadProgressTests", 4),
    "F01": ("F01CachedRecentTests", 2),
    "F05": ("F05MetadataCatalogTests", 6),
    "F07": ("F07ResourceOwnershipTests|F07PagedListingTests", 8),
    "F09": ("F09ServiceSessionTests|F09MetadataNamespaceTests", 6),
    "F35": ("F35FileUploadQueueTests", 5),
    "F21": ("F21UniqueUploadKeyTests", 1),
    "N10": ("N10MultiDropTests", 2),
    "N11": ("N11InvalidImageUploadTests", 2),
    "N07": ("AuditN07", 13),
    "F22": ("F22FileImportTests", 4),
    "F24": ("F24ObjectAddressTests", 5),
    "N30": ("N30CopySourceEncodingTests", 3),
    "N06": ("N06BoundedBatchExportTests", 3),
    "N36": ("N36PartialBatchExportTests", 2),
    "N44": ("N44MediaLeaseTests|N44BatchExportCleanupTests", 3),
    "F10": ("F10MediaPreviewTests", 2),
    "F11": ("F11MediaTransferTests", 5),
    "F12": ("F12MediaIdentityTests|F12ConfirmedMutationTests", 7),
    "F13": ("F13DecodedCacheTests", 1),
    "F14": ("F14GalleryWindowTests", 2),
    "F15": ("F15OriginalFileTests", 4),
    "F18": ("F18OriginalExportTests", 2),
    "F19": ("F19MediaPathTests", 1),
    "N13": ("N13VersionRestoreTests", 4),
    "N25": ("N25MediaCacheResetTests", 2),
    "F36": ("F36PerformanceTests|F36MediaBodyObservationTests", 7),
    "N33": ("N33ObjectVersionHistoryTests", 5),
    "N32": ("N32MultipartCopyTests", 7),
    "N31": ("N31CopyPropertyTests|N31EncryptionPolicyTests", 14),
    "F26": ("AuditF26", 6),
    "F29": ("AuditF29", 6),
    "N20": ("AuditN20", 3),
    "N22": ("AuditN22", 4),
    "N23": ("AuditN23", 4),
    "F02": ("F02BrowseStartupTests", 2),
    "F03": ("F03TabRetentionTests", 3),
    "F04": ("F04SharedCatalogQueryTests", 2),
    "F06": ("F06CanonicalCatalogTests", 2),
    "F33": ("F33FullCatalogSearchTests", 2),
    "F16": ("F16DetailDemandTests", 4),
    "F23": ("F23FramesRefreshTests", 3),
    "F27": ("F27ConfirmedNavigationTests", 3),
    "N34": ("N34ConfiguredPrefixTests", 2),
    "N37": ("N37DumpDeleteFeedbackTests", 3),
    "N46": ("N46ACLAccessSummaryTests", 5),
    "N48": ("N48FolderValidationTests", 3),
    "F20": ("F20ListingPaginationTests", 3),
    "N16": ("N16PartialFolderSortTests", 1),
    "N17": ("N17PartialFolderSearchTests", 1),
    "N39": ("N39DestinationListingTests", 2),
    "F32": ("F32BucketCountCacheTests", 4),
    "N19": ("AuditN19", 3),
    "N21": ("AuditN21", 3),
    "N12": ("AuditN12", 4),
    "N24": ("AuditN24", 4),
    "N42": ("AuditN42", 14),
    "F28": ("F28ScreensIndexTests", 5),
    "N40": ("N40ManifestFailureTests", 3),
    "N38": ("N38MetadataFailureTests", 3),
    "N14": ("N14MediaZoomTests", 3),
    "F31": ("F31SharePipelineTests|F31FilePromiseTests", 8),
    "N35": ("N35ShareOutcomeTests", 3),
    "N18": ("N18TransferDismissalTests", 3),
    "N41": ("AuditN41", 6),
    "F08": ("F08ConcurrencyBoundaryTests", 4),
    "F30": ("F30ListPresentationTests", 2),
    "F34": ("F34DerivedRowsCacheTests", 4),
    "N08": ("N08FileCardAccessibilityTests", 3),
    "N09": ("N09TabAccessibilityTests", 2),
}
SEMANTIC_CHECKS = {"N43", "N49"}


def load_queue():
    queue = json.loads((ROOT / "AUDIT_QUEUE.json").read_text())
    expected = {f"F{i:02d}" for i in range(1, 37)} | {f"N{i:02d}" for i in range(1, 50)}
    items = queue["implementation_items"]
    ids = [item["id"] for item in items]
    if len(ids) != 85 or set(ids) != expected or queue["scope_finding_count"] != 85:
        raise ValueError("The queue must retain exactly F01-F36 and N01-N49")
    external = queue["verification_delivery_items"]
    if len(external) != 2 or {item["id"] for item in external} != {"E01", "E02"}:
        raise ValueError("The queue must retain E01 and E02 independently")
    statuses = {"Open", "In Progress", "Done", "Blocked - External"}
    for item in items + external:
        behavior = item.get("acceptance_behavior") if item in items else item.get("required_behavior")
        if item["status"] not in statuses or not behavior:
            raise ValueError("Invalid status or missing acceptance behavior: " + item["id"])
    return queue


def source_identity(root=None):
    root = ROOT if root is None else root
    digest = hashlib.sha256()
    paths = [root / "Package.swift", root / "Info.plist", *sorted(root.glob("*.entitlements")),
             *sorted((root / "scripts").glob("*.py"))]
    for folder in ("Sources", "ShareExtension", "WidgetExtension", "Tests", "TestS3Browser.xcodeproj",
                   "TestS3BrowserIntegrationTests", "TestS3BrowserUITests"):
        paths += sorted(p for p in (root / folder).rglob("*") if p.is_file() and "xcuserdata" not in p.parts)
    for path in sorted(paths):
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
    return digest.hexdigest()


def run_id(item, source_retries=3):
    identity = source_identity()
    item_id = item["id"]
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    log = ARTIFACTS / (item_id + ".log")
    result = ARTIFACTS / (item_id + ".json")
    xml = ARTIFACTS / (item_id + ".xml")
    if item_id not in SWIFT_SUITES and item_id not in SEMANTIC_CHECKS:
        print("FAIL: no implemented verification registered for " + item_id, file=sys.stderr)
        return False
    # Remove only this runner's previous test report, never build/package caches.
    xml.unlink(missing_ok=True)
    if item_id in SEMANTIC_CHECKS:
        minimum = 1
        command = [sys.executable, str(ROOT / "scripts" / "check_extension_resources.py"), "--id", item_id]
    else:
        suite, minimum = SWIFT_SUITES[item_id]
        command = ["xcrun", "swift", "test", "--package-path", str(ROOT), "--disable-xctest",
                   "--enable-swift-testing", "--filter", suite, "--xunit-output", str(xml)]
    with log.open("w") as output:
        completed = subprocess.run(command, cwd=ROOT, text=True, stdout=output, stderr=subprocess.STDOUT)
    output = log.read_text()
    cases = []
    failures = []
    scope = "Production core with fake boundaries; full app integration is E01."
    if item_id in SEMANTIC_CHECKS and completed.returncode == 0:
        report = json.loads(output)
        cases = [assertion for check in report["checks"] if check["id"] == item_id for assertion in check["assertions"]]
        failures = report["failures"]
        scope = report["limits"]
    elif xml.exists():
        report = ET.parse(xml).getroot()
        cases = [c.attrib for c in report.iter("testcase")]
        failures = list(report.iter("failure")) + list(report.iter("error")) + list(report.iter("skipped"))
    unchanged = source_identity() == identity
    passed = completed.returncode == 0 and len(cases) >= minimum and not failures and unchanged
    proof = {
        "id": item_id, "expected_behavior": item["acceptance_behavior"],
        "passed": passed, "source_fingerprint": identity,
        "source_unchanged_during_check": unchanged,
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "command": command, "exit_code": completed.returncode,
        "test_count": len(cases), "actual_assertions": cases,
        "log_path": str(log), "test_report_path": str(xml) if xml.exists() else None,
        "scope": scope
    }
    result.write_text(json.dumps(proof, indent=2) + "\n")
    if completed.returncode == 0 and len(cases) >= minimum and not failures and not unchanged and source_retries:
        print("RECHECK: " + item_id + "; source inputs changed during successful checks", flush=True)
        return run_id(item, source_retries - 1)
    print(("PASS" if passed else "FAIL") + ": " + item_id + "; executed " + str(len(cases)) + " tests; " + str(result))
    if not passed:
        print(output[-8000:])
        if not unchanged:
            print("Source inputs changed during verification; rerun against stable inputs.")
    return passed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--id")
    mode.add_argument("--all", action="store_true")
    mode.add_argument("--release-simulator", action="store_true")
    mode.add_argument("--delivery", action="store_true")
    args = parser.parse_args(argv)
    try:
        queue = load_queue()
    except (ValueError, KeyError, TypeError, OSError) as error:
        print("FAIL: invalid audit queue: " + str(error), file=sys.stderr)
        return 1
    items = queue["implementation_items"]
    if args.id:
        item = next((x for x in items if x["id"] == args.id), None)
        if item is None:
            parser.error("Unknown local audit ID: " + args.id)
        return 0 if run_id(item) else 1
    if args.all:
        missing = [x["id"] for x in items if x["id"] not in SWIFT_SUITES and x["id"] not in SEMANTIC_CHECKS]
        if missing:
            print("FAIL: unimplemented audit checks: " + ", ".join(missing), file=sys.stderr)
            return 1
        outcomes = [run_id(x) for x in items]
        identity = source_identity()
        current = all(json.loads((ARTIFACTS / (x["id"] + ".json")).read_text())["source_fingerprint"]
                      == identity for x in items)
        if not current:
            print("FAIL: source inputs changed across --all; rerun against stable inputs", file=sys.stderr)
        return 0 if all(outcomes) and current else 1
    if args.release_simulator:
        return subprocess.run([sys.executable, str(ROOT / "scripts/release_simulator_check.py")], cwd=ROOT).returncode
    return subprocess.run([sys.executable, str(ROOT / "scripts/verify_delivery.py")], cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main())
