#!/usr/bin/env python3
"""Check app-owned bundle declarations; built bundle/SDK proof belongs to E01."""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "TestS3Browser.xcodeproj/project.pbxproj"
API_PREFIX = "NSPrivacyAccessedAPICategory"
MANIFESTS = {
    "TestS3Browser": ROOT / "Sources/PrivacyInfo.xcprivacy",
    "DumpShareExtension": ROOT / "ShareExtension/PrivacyInfo.xcprivacy",
    "TestS3BrowserWidget": ROOT / "WidgetExtension/PrivacyInfo.xcprivacy",
}
REASONS = {
    "TestS3Browser": {"UserDefaults": {"CA92.1", "1C8F.1"}, "FileTimestamp": {"C617.1"}},
    "DumpShareExtension": {"UserDefaults": {"1C8F.1"}},
    "TestS3BrowserWidget": {"UserDefaults": {"1C8F.1"}},
}
SOURCES = [
    "https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype",
    "https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api",
    "https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html",
]


def load_project():
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(PROJECT)],
        capture_output=True, text=True, check=True,
    )
    project = json.loads(result.stdout)
    objects = project["objects"]
    paths = {}

    def walk(identifier, base):
        item = objects[identifier]
        tree = item.get("sourceTree", "<group>")
        if tree == "SOURCE_ROOT":
            base = ROOT
        elif tree not in ("<group>", "<absolute>"):
            return
        path = base / item.get("path", "")
        paths.setdefault(identifier, set()).add(path.resolve())
        if item["isa"] in ("PBXGroup", "PBXVariantGroup"):
            for child in item.get("children", []):
                walk(child, path)

    main_group = objects[project["rootObject"]]["mainGroup"]
    walk(main_group, ROOT)
    return objects, paths


def target_paths(objects, paths, target, phase_type):
    result = []
    for phase_id in target["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] != phase_type:
            continue
        for build_id in phase.get("files", []):
            file_id = objects[build_id].get("fileRef")
            if file_id:
                candidates = paths.get(file_id, set())
                if len(candidates) != 1:
                    # A privacy manifest/source reference must resolve unambiguously.
                    reference_path = Path(objects[file_id].get("path", ""))
                    if reference_path.name == "PrivacyInfo.xcprivacy" or reference_path.suffix == ".swift":
                        raise ValueError(f"Ambiguous project file reference {file_id}: {candidates}")
                    continue
                result.append(next(iter(candidates)))
    return result


def inventory(source_paths):
    """Inventory direct app-owned symbols, not SDK internals or runtime calls."""
    patterns = {
        "UserDefaults": r"\bUserDefaults\s*(?:\(|\.)|@AppStorage\b",
        "FileTimestamp": r"\b(?:contentModificationDateKey|creationDateKey|fileModificationDate)\b|\.\s*(?:modificationDate|creationDate)\b|\b(?:getattrlist|getattrlistbulk|fgetattrlist|fgetattrlistat|getattrlistat|stat|fstat|fstatat|lstat)\s*\(",
        "SystemBootTime": r"\b(?:systemUptime|mach_absolute_time)\b",
        "DiskSpace": r"\b(?:volumeAvailableCapacityKey|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|volumeTotalCapacityKey|systemFreeSize|systemSize)\b|\b(?:statfs|statvfs|fstatfs|fstatvfs)\s*\(",
        "ActiveKeyboards": r"\bactiveInputModes\b",
    }
    found = {}
    private_defaults = False
    group_defaults = False
    for path in source_paths:
        text = path.read_text()
        text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
        private_defaults |= bool(re.search(r"\bUserDefaults\s*\.\s*standard|@AppStorage\b", text))
        group_defaults |= bool(re.search(r"\bUserDefaults\s*\(\s*suiteName\s*:", text))
        for category, pattern in patterns.items():
            if re.search(pattern, text):
                found.setdefault(category, []).append(str(path.relative_to(ROOT)))
    return found, private_defaults, group_defaults


def check_privacy(objects, paths):
    assertions = []
    api_inventory = {}
    targets = {item["name"]: item for item in objects.values() if item["isa"] == "PBXNativeTarget"}
    for name, manifest in MANIFESTS.items():
        target = targets[name]
        resources = target_paths(objects, paths, target, "PBXResourcesBuildPhase")
        bundled = [p for p in resources if p.name == "PrivacyInfo.xcprivacy"]
        assert bundled == [manifest], f"{name}: expected one own manifest resource, got {bundled}"
        assert manifest.is_file() and manifest.stat().st_size > 0, f"Missing manifest: {manifest}"
        with manifest.open("rb") as handle:
            data = plistlib.load(handle)
        assert set(data) == {"NSPrivacyAccessedAPITypes"}, f"{name}: unexpected privacy claims"
        entries = data["NSPrivacyAccessedAPITypes"]
        assert isinstance(entries, list) and entries, f"{name}: missing required API entries"
        declared = {}
        for entry in entries:
            assert set(entry) == {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}
            category = entry["NSPrivacyAccessedAPIType"]
            assert isinstance(category, str) and category.startswith(API_PREFIX)
            category = category.removeprefix(API_PREFIX)
            assert category not in declared, f"{name}: duplicate category {category}"
            reasons = entry["NSPrivacyAccessedAPITypeReasons"]
            assert isinstance(reasons, list) and reasons and all(isinstance(x, str) for x in reasons)
            assert len(set(reasons)) == len(reasons), f"{name}: duplicate reasons"
            declared[category] = set(reasons)
        assert declared == REASONS[name], f"{name}: unsupported or inaccurate reasons {declared}"
        source_paths = target_paths(objects, paths, target, "PBXSourcesBuildPhase")
        assert source_paths and all(p.is_file() for p in source_paths), f"{name}: missing compiled source"
        usage, private_defaults, group_defaults = inventory(source_paths)
        assert set(usage) == set(declared), f"{name}: direct API inventory differs from manifest: {usage}"
        if "UserDefaults" in declared:
            expected_defaults = ({"CA92.1"} if private_defaults else set()) | ({"1C8F.1"} if group_defaults else set())
            assert declared["UserDefaults"] == expected_defaults, f"{name}: defaults domain reasons differ from calls"
        api_inventory[name] = usage
        assertions.append(f"{name}: one valid own manifest in Resources; direct API categories and reviewed reasons agree")
    return {"id": "N43", "assertions": assertions, "api_inventory": api_inventory}


def check_activation():
    with (ROOT / "ShareExtension/Info.plist").open("rb") as handle:
        data = plistlib.load(handle)
    extension = data["NSExtension"]
    assert extension["NSExtensionPointIdentifier"] == "com.apple.share-services"
    assert extension["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).ShareViewController"
    rule = extension["NSExtensionAttributes"]["NSExtensionActivationRule"]
    expected = {
        "NSExtensionActivationSupportsImageWithMaxCount": 10,
        "NSExtensionActivationSupportsMovieWithMaxCount": 10,
    }
    assert isinstance(rule, dict) and rule == expected, f"Unsupported or missing activation capabilities: {rule}"
    assert all(type(value) is int and value > 0 for value in rule.values())
    return {
        "id": "N49",
        "assertions": [
            "Share services activation advertises up to ten images and ten movies",
            "Generic files, text, web pages and web URLs have no activation support declaration",
            "Activation rule is a typed dictionary, with no always-true predicate or generic attachment override",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", choices=("N43", "N49"))
    args = parser.parse_args()
    results = []
    failures = []
    for identifier in ([args.id] if args.id else ["N43", "N49"]):
        try:
            result = check_privacy(*load_project()) if identifier == "N43" else check_activation()
            results.append(result)
        except (AssertionError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
            failures.append({"id": identifier, "error": str(error)})
    print(json.dumps({
        "checks": results,
        "failures": failures,
        "sources": SOURCES,
        "limits": "Local plist/resource semantics and direct app-owned Swift API inventory only. E01 separately verifies real built app/share/widget bundles and SDK manifests. This does not claim App Store approval or host share-sheet runtime behavior.",
    }, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
