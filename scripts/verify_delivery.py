#!/usr/bin/env python3
"""Verify committed source and ledger against the configured remote branch."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_audit import ROOT, ARTIFACTS, source_identity

INPUT_FOLDERS = ("Sources", "ShareExtension", "WidgetExtension", "Tests", "TestS3BrowserIntegrationTests",
                 "TestS3BrowserUITests", "TestS3Browser.xcodeproj", "scripts")


def is_source_input(name):
    path = Path(name)
    return (path.parts and path.parts[0] in INPUT_FOLDERS and "xcuserdata" not in path.parts) or (
        name in ("Package.swift", "Info.plist") or path.suffix == ".entitlements")


def verify(root=ROOT, artifacts=ARTIFACTS):
    root, artifacts = Path(root), Path(artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    proof = {"id": "E02", "passed": False, "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "source_fingerprint": source_identity(root), "commands": [], "assertions": []}
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")

    def git(*args, allow_failure=False):
        command = ["git", "-C", str(root), *args]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=120, env=environment)
            record = {"command": command, "exit_code": result.returncode,
                      "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
        except subprocess.TimeoutExpired as error:
            record = {"command": command, "exit_code": 124, "stdout": "", "stderr": str(error)}
        proof["commands"].append(record)
        if record["exit_code"] and not allow_failure:
            raise RuntimeError("Git verification failed: " + " ".join(args) + ": " + record["stderr"])
        return record

    try:
        head = git("rev-parse", "HEAD")["stdout"]
        branch = git("symbolic-ref", "--short", "HEAD")["stdout"]
        remote = git("config", "--get", "branch." + branch + ".remote")["stdout"]
        ref = git("config", "--get", "branch." + branch + ".merge")["stdout"]
        if remote in ("", ".") or not ref.startswith("refs/heads/"):
            raise RuntimeError("The current branch needs a configured external push/upstream branch")
        dirty = git("diff", "--name-only", "HEAD")["stdout"].splitlines()
        dirty += git("ls-files", "--others", "--exclude-standard")["stdout"].splitlines()
        unsettled = [name for name in dirty if is_source_input(name) or name == "AUDIT_QUEUE.json"]
        if unsettled: raise RuntimeError("Uncommitted source or ledger: " + ", ".join(unsettled))
        remote_result = git("ls-remote", "--exit-code", remote, ref, allow_failure=True)
        if remote_result["exit_code"]:
            remote_result = git("-c", "http.version=HTTP/1.1", "ls-remote", "--exit-code", remote, ref)
        remote_commit = remote_result["stdout"].split()[0]
        if remote_commit != head:
            # Refresh only the object/FETCH_HEAD evidence; never reset or change the checkout.
            git("fetch", "--no-tags", remote, ref)
        git("merge-base", "--is-ancestor", head, remote_commit)
        input_paths = [*INPUT_FOLDERS, "Package.swift", "Info.plist", "*.entitlements"]
        source_commit = git("log", "-1", "--format=%H", "HEAD", "--", *input_paths)["stdout"]
        if not source_commit: raise RuntimeError("No delivered source commit could be identified")
        git("merge-base", "--is-ancestor", source_commit, remote_commit)
        ledger = root / "AUDIT_QUEUE.json"
        local_ledger = git("rev-parse", "HEAD:AUDIT_QUEUE.json")["stdout"]
        remote_ledger = git("rev-parse", remote_commit + ":AUDIT_QUEUE.json")["stdout"]
        if local_ledger != remote_ledger:
            raise RuntimeError("Remote ledger differs from this checkout's committed ledger")
        if source_identity(root) != proof["source_fingerprint"]:
            raise RuntimeError("Source changed during delivery verification")
        proof.update(passed=True, branch=branch, remote=remote, remote_ref=ref, remote_commit=remote_commit,
                     delivered_source_commit=source_commit, delivered_ledger_commit=head,
                     ledger_blob=local_ledger, ledger_sha256=hashlib.sha256(ledger.read_bytes()).hexdigest())
        proof["assertions"] = ["Source/build/test inputs are committed", "The ledger is committed",
            "Configured remote branch contains the local source commit and ledger commit",
            "Remote ledger blob matches the committed local ledger", "Source fingerprint stayed unchanged"]
    except (OSError, ValueError, IndexError, RuntimeError, subprocess.SubprocessError) as error:
        proof["failure"] = str(error)
    result = artifacts / "E02.json"
    result.write_text(json.dumps(proof, indent=2) + "\n")
    return proof


def self_test():
    with tempfile.TemporaryDirectory(prefix="s3-delivery-test-") as folder:
        base = Path(folder); repo = base / "repo"; remote = base / "remote.git"
        subprocess.run(["git", "init", "--bare", "--quiet", str(remote)], check=True)
        subprocess.run(["git", "init", "--quiet", "-b", "main", str(repo)], check=True)
        def git(*args):
            return subprocess.run(["git", "-C", str(repo), *args], check=True, text=True, capture_output=True)
        git("config", "user.email", "audit-fixture@example.invalid");git("config", "user.name", "Audit Fixture")
        (repo / "Sources").mkdir();(repo / "Sources/state.swift").write_text("let syntheticFixture = 1\n")
        (repo / "AUDIT_QUEUE.json").write_text('{"synthetic_fixture":true}\n')
        git("add", "-A");git("commit", "--quiet", "-m", "Synthetic fixture")
        git("remote", "add", "origin", str(remote));git("push", "--quiet", "-u", "origin", "main")
        assert verify(repo, base / "proof-1")["passed"]
        (repo / "Sources/state.swift").write_text("let syntheticFixture = 2\n")
        assert not verify(repo, base / "proof-2")["passed"]
        git("add", "-A");git("commit", "--quiet", "-m", "Unpushed synthetic source")
        assert not verify(repo, base / "proof-3")["passed"]
        git("push", "--quiet", "origin", "main")
        assert verify(repo, base / "proof-4")["passed"]
        (repo / "AUDIT_QUEUE.json").write_text('{"synthetic_fixture":true,"new_ledger":true}\n')
        assert not verify(repo, base / "proof-5")["passed"]
        git("add", "-A");git("commit", "--quiet", "-m", "Synthetic ledger")
        git("push", "--quiet", "origin", "main")
        assert verify(repo, base / "proof-6")["passed"]
    return {"passed": True, "assertions": ["Pushed source and matching ledger pass", "Dirty source fails",
        "Unpushed source fails", "Pushed updated source passes", "Dirty ledger fails", "Pushed ledger passes"],
        "scope": "Actual temporary local Git repositories/remotes; no credentials or configured project remote writes"}


def main():
    parser = argparse.ArgumentParser(description=__doc__);parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        result = self_test();ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (ARTIFACTS / "delivery-selftest.json").write_text(json.dumps(result, indent=2) + "\n")
        print("PASS: delivery verifier self-test; 6 actual Git scenarios")
        return 0
    proof = verify()
    print(("PASS" if proof["passed"] else "FAIL") + ": E02; " + str(ARTIFACTS / "E02.json"))
    if not proof["passed"]: print(proof["failure"])
    return 0 if proof["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
