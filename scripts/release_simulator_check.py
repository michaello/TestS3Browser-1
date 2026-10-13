#!/usr/bin/env python3
"""Verify the real pinned-SDK Release app and its simulator integration tests."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts/audit"
PROJECT = ROOT / "TestS3Browser.xcodeproj"
LOCK = PROJECT / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
UDID = "5B87AEFD-8266-4451-8795-8728177C5241"
DEFAULT_DERIVED = Path.home() / "Library/Developer/Xcode/DerivedData/TestS3BrowserAudit"
SDK_MANIFESTS = (
    ("smithy-swift_ClientRuntime.bundle", "smithy-swift/Sources/ClientRuntime/PrivacyInfo.xcprivacy"),
    ("aws-sdk-swift_AWSClientRuntime.bundle", "aws-sdk-swift/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/Resources/PrivacyInfo.xcprivacy"),
    ("aws-crt-swift_AwsCommonRuntimeKit.bundle", "aws-crt-swift/Source/AwsCommonRuntimeKit/PrivacyInfo.xcprivacy"),
    ("SwiftProtobuf_SwiftProtobuf.bundle", "swift-protobuf/Sources/SwiftProtobuf/PrivacyInfo.xcprivacy"),
)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def source_fingerprint():
    spec = importlib.util.spec_from_file_location("audit_verifier_identity", ROOT / "scripts/verify_audit.py")
    verifier = importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
    return verifier.source_identity()


def derived_data():
    settings = PROJECT / "project.xcworkspace/xcuserdata" / (os.environ.get("USER", "mike") + ".xcuserdatad") / "WorkspaceSettings.xcsettings"
    data = plistlib.loads(settings.read_bytes()) if settings.exists() else {}
    if data.get("DerivedDataLocationStyle") == "AbsolutePath" and data.get("DerivedDataCustomLocation"):
        return Path(data["DerivedDataCustomLocation"]).expanduser().resolve(), settings
    if data and data.get("DerivedDataLocationStyle", "Default") != "Default":
        raise RuntimeError("Unsupported existing IDE DerivedData setting; preserve and resolve it explicitly: " + str(settings))
    data.update(DerivedDataLocationStyle="AbsolutePath", DerivedDataCustomLocation=str(DEFAULT_DERIVED))
    settings.parent.mkdir(parents=True, exist_ok=True);settings.write_bytes(plistlib.dumps(data))
    return DEFAULT_DERIVED, settings


def command_result(command, label, timeout, environment=None):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    log = ARTIFACTS / (label + "-" + stamp + ".log")
    started = time.time()
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        state = {"command": command, "pid": process.pid, "log_path": str(log), "started_at_epoch": started, "timeout_seconds": timeout, "status": "running"}
        write_json(ARTIFACTS / "E01-active-command.json", state)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL);process.wait()
            code = 124
    state.update(status="completed" if code == 0 else "failed", exit_code=code, elapsed_seconds=time.time() - started)
    write_json(ARTIFACTS / "E01-active-command.json", state)
    return state


def wait_for_owned_fetches():
    # A live process, not a stale state file, proves a verified wait. Do not restart it.
    for name in ("E01-resolve-process.json", "E01-shallow-process.json", "E01-filtered-process.json", "E01-codeload-process.json", "E01-zip-process.json", "E01-object-hydration.json", "E01-object-hydration-resume.json"):
        path = ARTIFACTS / name
        if not path.exists(): continue
        while True:
            state = json.loads(path.read_text())
            if state.get("status") != "running": break
            pid = state["pid"]
            actual = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
            if actual.returncode != 0 or not actual.stdout.strip(): break
            if "aws-sdk-swift" not in actual.stdout and str(PROJECT) not in actual.stdout:
                raise RuntimeError("Recorded fetch PID no longer belongs to this run: " + str(pid))
            deadline = state["started_at_epoch"] + state["timeout_seconds"] + 30
            if time.time() > deadline: raise RuntimeError("Existing owned fetch exceeded supervisor deadline: " + str(path))
            time.sleep(1)


def pinned_environment(derived, commands):
    pins = json.loads(LOCK.read_text())["pins"]
    pin = next(p for p in pins if p["identity"] == "aws-sdk-swift")
    revision, version = pin["state"]["revision"], pin["state"]["version"]
    mirror = derived / "PinnedMirrors/aws-sdk-swift.git"
    environment = os.environ.copy()
    additions = []
    mirror_url = None
    if mirror.exists():
        actual = subprocess.run(["git", "-C", str(mirror), "rev-parse", "refs/tags/" + version], capture_output=True, text=True)
        if actual.returncode == 0 and actual.stdout.strip() == revision:
            mirror_url = mirror.as_uri()
            # Redirect only Git transport. SwiftPM still sees the approved original URL,
            # avoiding mirror URLs or identities being written into Package.resolved.
            additions += [("url." + mirror_url + ".insteadOf", pin["location"]),
                          ("url." + mirror_url + ".insteadOf", pin["location"] + ".git")]
    # Git transport setting is process-only; never change the user's global Git config.
    count = int(environment.get("GIT_CONFIG_COUNT", "0"))
    additions.append(("http.version", "HTTP/1.1"))
    for offset, (key, value) in enumerate(additions):
        environment["GIT_CONFIG_KEY_" + str(count + offset)] = key
        environment["GIT_CONFIG_VALUE_" + str(count + offset)] = value
    environment["GIT_CONFIG_COUNT"] = str(count + len(additions))
    return environment, {"aws_sdk_revision": revision, "aws_sdk_version": version, "local_git_transport_mirror": mirror_url}


def inspect_resources(app):
    checks = []
    for relative, original in (("", "Sources"), ("PlugIns/DumpShareExtension.appex", "ShareExtension"), ("PlugIns/TestS3BrowserWidget.appex", "WidgetExtension")):
        bundle = app / relative
        manifest = bundle / "PrivacyInfo.xcprivacy"
        if not manifest.is_file() or manifest.stat().st_size == 0: raise RuntimeError("Missing built privacy manifest: " + str(manifest))
        actual = plistlib.loads(manifest.read_bytes())
        expected = plistlib.loads((ROOT / original / "PrivacyInfo.xcprivacy").read_bytes())
        if actual != expected: raise RuntimeError("Built privacy manifest differs from tested source: " + str(manifest))
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        executable = bundle / info["CFBundleExecutable"]
        if not executable.is_file() or executable.stat().st_size == 0: raise RuntimeError("Missing built executable: " + str(executable))
        checks.append({"bundle": str(bundle), "manifest": str(manifest), "executable": str(executable), "manifest_matches_source": True})
    share = plistlib.loads((app / "PlugIns/DumpShareExtension.appex/Info.plist").read_bytes())
    expected = plistlib.loads((ROOT / "ShareExtension/Info.plist").read_bytes())
    if share["NSExtension"] != expected["NSExtension"]:
        # Xcode resolves the module-name macro in the built principal class.
        if share["NSExtension"]["NSExtensionPrincipalClass"] != "DumpShareExtension.ShareViewController":
            raise RuntimeError("Built share extension principal class is incorrect")
        expected["NSExtension"]["NSExtensionPrincipalClass"] = "DumpShareExtension.ShareViewController"
        if share["NSExtension"] != expected["NSExtension"]: raise RuntimeError("Built share activation differs from supported source types")
    return checks


def validate_test_summary(summary):
    if summary.get("failedTests", 0) or summary.get("skippedTests", 0): raise RuntimeError("Integrated tests failed or skipped: " + json.dumps(summary))
    if summary.get("passedTests", 0) < 13: raise RuntimeError("Expected at least eight integration and five UI tests; got " + json.dumps(summary))


def inspect_sdk_resources(app, derived):
    checks = []
    packages = derived / "SourcePackages/checkouts"
    for target, relative in SDK_MANIFESTS:
        source = packages / relative
        expected = plistlib.loads(source.read_bytes())
        candidates = [path for path in app.rglob("PrivacyInfo.xcprivacy") if path.parent.name == target]
        if not candidates: raise RuntimeError("Pinned SDK privacy resource is missing from app: " + target)
        for path in candidates:
            if plistlib.loads(path.read_bytes()) != expected:
                raise RuntimeError("Built SDK manifest differs from pinned source: " + str(path))
            checks.append({"target": target, "source_manifest": str(source), "built_manifest": str(path), "matches_pinned_source": True})
    return checks


def validate_test_tree(tree):
    bundles = {}
    def visit(node):
        if node.get("nodeType") in ("Unit test bundle", "UI test bundle"):
            bundles[node["name"].removesuffix(".xctest")] = node
        for child in node.get("children", []): visit(child)
    for node in tree.get("testNodes", []): visit(node)
    for name in ("TestS3BrowserIntegrationTests", "TestS3BrowserUITests"):
        if name not in bundles or bundles[name].get("result") != "Passed":
            raise RuntimeError("Required integrated test bundle did not pass: " + name)


def validate_runtime_measurements(snapshot, case):
    for field in ("launchToFirstContentMilliseconds", "cacheToFirstContentMilliseconds", "maximumFrameGapMilliseconds"):
        value = snapshot.get(field)
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise RuntimeError("Missing or invalid runtime measurement: " + case + ":" + field)
    if type(snapshot.get("peakResidentBytes")) is not int or snapshot["peakResidentBytes"] <= 0:
        raise RuntimeError("Missing measured process peak resident memory: " + case)
    for field in ("requestCount", "duplicateBodyRequests", "receivedBytes", "confirmedUploadPayloadBytes", "failedRequests", "scrollingStalls"):
        if type(snapshot.get(field)) is not int or snapshot[field] < 0:
            raise RuntimeError("Invalid runtime aggregate: " + case + ":" + field)
    transfers = snapshot.get("maximumOwnedBodyTransfers")
    if transfers is not None and (type(transfers) is not int or not 0 <= transfers <= 4):
        raise RuntimeError("Measured app-owned body transfer peak exceeds the tested limit: " + case)
    unavailable = snapshot.get("unavailableMeasurements")
    if not isinstance(unavailable, list) or not unavailable or any(not isinstance(value, str) or not value for value in unavailable):
        raise RuntimeError("Runtime report must identify unavailable measurements: " + case)
    scope = snapshot.get("byteMeasurementScope")
    if not isinstance(scope, str) or "sdk" not in scope.lower() or "upload" not in scope.lower():
        raise RuntimeError("Runtime byte measurements have no SDK/upload scope: " + case)
    construction = snapshot.get("viewConstruction")
    allowed_surfaces = {"browse", "recent", "prefix", "dump", "stash", "gallery"}
    if not isinstance(construction, dict) or "recent" not in construction or set(construction) - allowed_surfaces:
        raise RuntimeError("Missing bounded actual view construction measurements: " + case)
    for surface, metric in construction.items():
        if type(metric.get("count")) is not int or metric["count"] < 1:
            raise RuntimeError("Invalid construction sample count: " + case + ":" + surface)
        for field in ("totalMilliseconds", "maximumMilliseconds"):
            if type(metric.get(field)) not in (int, float) or not math.isfinite(metric[field]) or metric[field] < 0:
                raise RuntimeError("Invalid measured construction duration: " + case + ":" + surface)
        if metric["maximumMilliseconds"] > metric["totalMilliseconds"] + 1e-9:
            raise RuntimeError("Construction maximum exceeds the observed total")
    if "excludes layout" not in snapshot.get("viewConstructionScope", ""):
        raise RuntimeError("View construction scope must exclude layout/draw work")
    if snapshot["requestCount"] < 1 or snapshot["duplicateBodyRequests"] != 0:
        raise RuntimeError("Runtime request coalescing evidence failed: " + case)
    refreshes = snapshot.get("refreshMilliseconds")
    if not isinstance(refreshes, list) or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in refreshes):
        raise RuntimeError("Invalid refresh timings: " + case)
    if case in ("cache-success", "offline") and not refreshes:
        raise RuntimeError("Completed refresh was not measured: " + case)
    if case == "offline" and snapshot["failedRequests"] < 1:
        raise RuntimeError("Offline failure did not reach actual transport instrumentation")
    if case == "cache-success" and snapshot["failedRequests"]:
        raise RuntimeError("Successful refresh recorded failed requests")


def collect_runtime_measurements(container, output=ARTIFACTS):
    records = {}
    for case in ("cache-success", "offline", "scrolling", "selection"):
        source = container / "Documents" / ("audit-runtime-" + case + ".json")
        if not source.is_file(): raise RuntimeError("Missing fixture runtime measurements: " + str(source))
        snapshot = json.loads(source.read_bytes());validate_runtime_measurements(snapshot, case)
        destination = output / ("F36-runtime-" + case + ".json")
        write_json(destination, snapshot)
        records[case] = {"path": str(destination), "measurements": snapshot}
    # Only this test fixture's isolated domain is removed. Production preferences
    # and the shared App Group are never read or changed by the verifier.
    removed = []
    preference = container / "Library/Preferences/s3browser-audit-fixture-v1.plist"
    if preference.is_file(): preference.unlink();removed.append(str(preference))
    for source in (container / "Documents").glob("audit-runtime-*.json"):
        source.unlink();removed.append(str(source))
    return {"cases": records, "synthetic_fixture_files_removed": removed,
            "byte_measurement_scope": "App-exported SDK download/confirmed-upload scope; unavailable native AVFoundation and partial-failure wire measurements are not estimated"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--resolve-only", action="store_true")
    modes.add_argument("--check-environment", action="store_true")
    modes.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    if args.self_test:
        good = command_result([sys.executable, "-c", "print('fixture process executed')"], "E01-script-self-test", 10)
        bad = command_result([sys.executable, "-c", "raise SystemExit(7)"], "E01-script-negative-test", 10)
        timeout = command_result([sys.executable, "-c", "import time;time.sleep(5)"], "E01-script-timeout-test", 0.1)
        assert good["exit_code"] == 0 and Path(good["log_path"]).read_text().strip() == "fixture process executed"
        assert bad["exit_code"] == 7 and timeout["exit_code"] == 124
        validate_test_summary({"passedTests": 13, "failedTests": 0, "skippedTests": 0})
        for report in ({"passedTests": 0}, {"passedTests": 12}, {"passedTests": 13, "failedTests": 1}, {"passedTests": 13, "skippedTests": 1}):
            try: validate_test_summary(report)
            except RuntimeError: pass
            else: raise AssertionError("Invalid test report passed")
        tree = {"testNodes": [{"name": name + ".xctest", "nodeType": kind, "result": "Passed"} for name, kind in (("TestS3BrowserIntegrationTests", "Unit test bundle"), ("TestS3BrowserUITests", "UI test bundle"))]}
        validate_test_tree(tree)
        try: validate_test_tree({"testNodes": tree["testNodes"][:1]})
        except RuntimeError: pass
        else: raise AssertionError("Missing UI bundle passed")
        resource_cases = []
        with tempfile.TemporaryDirectory(prefix="s3-release-verifier-") as directory:
            app = Path(directory) / "TestS3Browser.app"
            for relative, original, executable in (("", "Sources", "TestS3Browser"), ("PlugIns/DumpShareExtension.appex", "ShareExtension", "DumpShareExtension"), ("PlugIns/TestS3BrowserWidget.appex", "WidgetExtension", "TestS3BrowserWidget")):
                bundle = app / relative;bundle.mkdir(parents=True)
                (bundle / "PrivacyInfo.xcprivacy").write_bytes((ROOT / original / "PrivacyInfo.xcprivacy").read_bytes())
                info = {"CFBundleExecutable": executable}
                if original == "ShareExtension":
                    info.update(plistlib.loads((ROOT / "ShareExtension/Info.plist").read_bytes()))
                    info["NSExtension"]["NSExtensionPrincipalClass"] = "DumpShareExtension.ShareViewController"
                (bundle / "Info.plist").write_bytes(plistlib.dumps(info));(bundle / executable).write_bytes(b"fixture executable")
            assert len(inspect_resources(app)) == 3
            derived = Path(directory) / "derived"
            for target, relative in SDK_MANIFESTS:
                source = derived / "SourcePackages/checkouts" / relative
                source.parent.mkdir(parents=True);source.write_bytes(plistlib.dumps({"NSPrivacyAccessedAPITypes": [], "fixtureTarget": target}))
                bundle = app / target;bundle.mkdir();(bundle / "PrivacyInfo.xcprivacy").write_bytes(source.read_bytes())
            assert len(inspect_sdk_resources(app, derived)) == len(SDK_MANIFESTS)
            sdk = app / "smithy-swift_ClientRuntime.bundle/PrivacyInfo.xcprivacy";baseline_sdk = sdk.read_bytes();sdk.unlink()
            try: inspect_sdk_resources(app, derived)
            except RuntimeError: resource_cases.append("missing pinned SDK manifest rejected")
            else: raise AssertionError("Missing pinned SDK manifest passed")
            sdk.write_bytes(plistlib.dumps({"wrong": True}))
            try: inspect_sdk_resources(app, derived)
            except RuntimeError: resource_cases.append("different pinned SDK manifest rejected")
            else: raise AssertionError("Different pinned SDK manifest passed")
            sdk.write_bytes(baseline_sdk)
            manifest = app / "PrivacyInfo.xcprivacy";baseline = manifest.read_bytes();manifest.unlink()
            try: inspect_resources(app)
            except RuntimeError: resource_cases.append("missing manifest rejected")
            else: raise AssertionError("Missing built manifest passed")
            manifest.write_bytes(plistlib.dumps({"wrong": True}))
            try: inspect_resources(app)
            except RuntimeError: resource_cases.append("different manifest rejected")
            else: raise AssertionError("Different built manifest passed")
            manifest.write_bytes(baseline)
            share = app / "PlugIns/DumpShareExtension.appex/Info.plist";baseline = share.read_bytes();info = plistlib.loads(baseline)
            info["NSExtension"]["NSExtensionAttributes"]["NSExtensionActivationRule"]["NSExtensionActivationSupportsFileWithMaxCount"] = 10
            share.write_bytes(plistlib.dumps(info))
            try: inspect_resources(app)
            except RuntimeError: resource_cases.append("unsupported file activation rejected")
            else: raise AssertionError("Unsupported file activation passed")
            info = plistlib.loads(baseline);info["NSExtension"]["NSExtensionPrincipalClass"] = "Wrong.Controller";share.write_bytes(plistlib.dumps(info))
            try: inspect_resources(app)
            except RuntimeError: resource_cases.append("incorrect principal rejected")
            else: raise AssertionError("Incorrect principal passed")
            container = Path(directory) / "container";(container / "Documents").mkdir(parents=True);(container / "Library/Preferences").mkdir(parents=True)
            snapshot = {"launchToFirstContentMilliseconds": 120, "cacheToFirstContentMilliseconds": 20, "maximumFrameGapMilliseconds": 17, "peakResidentBytes": 1234, "requestCount": 1, "duplicateBodyRequests": 0, "receivedBytes": 0, "confirmedUploadPayloadBytes": 0, "unavailableMeasurements": ["Native AVFoundation HTTP wire bytes and requests", "Partial failed-upload bytes"], "byteMeasurementScope": "Consumed SDK downloads and confirmed upload payloads", "failedRequests": 0, "scrollingStalls": 0, "refreshMilliseconds": [3000]}
            snapshot.update(viewConstruction={"recent": {"count": 1, "totalMilliseconds": 4, "maximumMilliseconds": 4}},
                            viewConstructionScope="SwiftUI view construction only; excludes layout, drawing and framework work after body returns.")
            for case in ("cache-success", "offline", "scrolling", "selection"):
                value = dict(snapshot);value["failedRequests"] = 1 if case == "offline" else 0
                write_json(container / "Documents" / ("audit-runtime-" + case + ".json"), value)
            preference = container / "Library/Preferences/s3browser-audit-fixture-v1.plist";preference.write_bytes(b"fixture")
            protected = container / "Library/Preferences/production.plist";protected.write_bytes(b"must remain")
            runtime = collect_runtime_measurements(container, Path(directory) / "runtime-proof")
            assert len(runtime["cases"]) == 4 and len(runtime["synthetic_fixture_files_removed"]) == 5
            assert not preference.exists() and protected.read_bytes() == b"must remain"
            for invalid in ({}, {**snapshot, "peakResidentBytes": 0}, {**snapshot, "duplicateBodyRequests": 1}, {**snapshot, "refreshMilliseconds": []}, {**snapshot, "maximumOwnedBodyTransfers": 5}, {**snapshot, "unavailableMeasurements": []}, {**snapshot, "viewConstruction": {}}, {**snapshot, "viewConstructionScope": "full rendering"}):
                try: validate_runtime_measurements(invalid, "cache-success")
                except RuntimeError: pass
                else: raise AssertionError("Invalid runtime proof passed")
        write_json(ARTIFACTS / "E01-script-self-test.json", {"passed": True, "commands": [good, bad, timeout], "resource_negative_cases": resource_cases, "scope": "Verifier process/result/resource/runtime handling with temporary synthetic bundles only; no app build or simulator claim"})
        print("PASS: verifier process, timeout, test bundles, resource gates, runtime evidence and fixture cleanup")
        return 0
    derived, settings = derived_data()
    environment = {"derived_data_path": str(derived), "ide_workspace_metadata": str(settings), "simulator_udid": UDID,
                   "xcode_version": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
                   "simulator_runtime": json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))}
    if not any(device.get("udid") == UDID and device.get("isAvailable") for devices in environment["simulator_runtime"]["devices"].values() for device in devices):
        raise RuntimeError("Required installed simulator is unavailable: " + UDID)
    write_json(ARTIFACTS / "E01-environment.json", environment)
    if args.check_environment:
        print(json.dumps(environment, indent=2));return 0
    commands = []
    proof = {"id": "E01", "passed": False, "commands": commands, "environment": environment, "source_fingerprint": source_fingerprint()}
    lock_hash = hashlib.sha256(LOCK.read_bytes()).hexdigest()
    try:
        wait_for_owned_fetches()
        env, pinned = pinned_environment(derived, commands);proof.update(pinned)
        base = ["xcodebuild", "-project", str(PROJECT), "-scheme", "TestS3Browser", "-derivedDataPath", str(derived), "-scmProvider", "system"]
        resolved = command_result(base + ["-resolvePackageDependencies", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates", "CODE_SIGNING_ALLOWED=NO"], "E01-resolve", 1200, env);commands.append(resolved)
        if resolved["exit_code"] != 0: raise RuntimeError("Pinned package resolution failed: " + resolved["log_path"])
        if hashlib.sha256(LOCK.read_bytes()).hexdigest() != lock_hash: raise RuntimeError("Resolution changed the approved dependency lockfile")
        if args.resolve_only:
            proof["resolution_passed"] = True;write_json(ARTIFACTS / "E01-resolution.json", proof)
            print("PASS: pinned package resolution; integration build remains required");return 0
        destination = ["-configuration", "Release", "-destination", "platform=iOS Simulator,id=" + UDID, "-disableAutomaticPackageResolution", "-skipPackageUpdates", "CODE_SIGNING_ALLOWED=NO", "-parallel-testing-enabled", "NO"]
        built = command_result(base + destination + ["build-for-testing"], "E01-release-build", 1800, env);commands.append(built)
        if built["exit_code"] != 0: raise RuntimeError("Release build failed: " + built["log_path"])
        proof["built_resource_checks"] = inspect_resources(derived / "Build/Products/Release-iphonesimulator/TestS3Browser.app")
        proof["built_sdk_resource_checks"] = inspect_sdk_resources(derived / "Build/Products/Release-iphonesimulator/TestS3Browser.app", derived)
        result_path = ARTIFACTS / ("E01-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".xcresult")
        tested = command_result(base + destination + ["-resultBundlePath", str(result_path), "test-without-building"], "E01-simulator-tests", 1800, env);commands.append(tested);proof["xcresult_path"] = str(result_path)
        if tested["exit_code"] != 0: raise RuntimeError("Simulator integration tests failed: " + tested["log_path"])
        summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_path)], text=True));validate_test_summary(summary);proof["test_summary"] = summary
        tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_path)], text=True));validate_test_tree(tree);proof["test_tree"] = tree
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", UDID, "com.crispytoast.TestS3Browser", "data"], text=True).strip())
        proof["runtime_performance"] = collect_runtime_measurements(container)
        if source_fingerprint() != proof["source_fingerprint"]: raise RuntimeError("App/build/test inputs changed during E01; rerun against final source")
        proof["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        proof["failure"] = str(error)
    write_json(ARTIFACTS / ("E01-resolution.json" if args.resolve_only else "E01.json"), proof)
    print(("PASS" if proof["passed"] else "FAIL") + ": E01; " + str(ARTIFACTS / "E01.json"))
    if not proof["passed"]: print(proof.get("failure", "Verification incomplete"), file=sys.stderr)
    return 0 if proof["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
