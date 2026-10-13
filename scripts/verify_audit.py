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
    "F11": ("F11MediaTransferTests", 3),
    "F12": ("F12MediaIdentityTests", 2),
    "F13": ("F13DecodedCacheTests", 1),
    "F14": ("F14GalleryWindowTests", 2),
    "F15": ("F15OriginalFileTests", 4),
    "F18": ("F18OriginalExportTests", 2),
    "F19": ("F19MediaPathTests", 1),
    "N13": ("N13VersionRestoreTests", 4),
    "N25": ("N25MediaCacheResetTests", 2),
    "F36": ("F36PerformanceTests", 3),
    "N33": ("N33ObjectVersionHistoryTests", 5),
    "N32": ("N32MultipartCopyTests", 5),
    "N31": ("N31CopyPropertyTests", 5),
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
}
SEMANTIC_CHECKS = {"N43", "N49"}


def source_identity():
    digest = hashlib.sha256()
    paths = [ROOT / "Package.swift", ROOT / "Info.plist", *sorted(ROOT.glob("*.entitlements")),
             *sorted((ROOT / "scripts").glob("*.py"))]
    for folder in ("Sources", "ShareExtension", "WidgetExtension", "Tests", "TestS3Browser.xcodeproj",
                   "TestS3BrowserIntegrationTests", "TestS3BrowserUITests"):
        paths += sorted(p for p in (ROOT / folder).rglob("*") if p.is_file() and "xcuserdata" not in p.parts)
    for path in sorted(paths):
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode())
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--id")
    mode.add_argument("--all", action="store_true")
    mode.add_argument("--release-simulator", action="store_true")
    mode.add_argument("--delivery", action="store_true")
    args = parser.parse_args()
    queue = json.loads((ROOT / "AUDIT_QUEUE.json").read_text())
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
        return 0 if all(outcomes) else 1
    if args.release_simulator:
        return subprocess.run([sys.executable, str(ROOT / "scripts/release_simulator_check.py")], cwd=ROOT).returncode
    print("FAIL: delivery verification is not implemented yet", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
