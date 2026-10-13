#!/usr/bin/env python3
"""Verify an exact-commit source archive against Git before completing a local mirror."""
import argparse
import hashlib
import io
import json
import os
import signal
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import stat
import time
import zipfile
import zlib


def git(mirror, *arguments):
    return subprocess.check_output(["git", "-C", str(mirror), *arguments], env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})


def tree(mirror, revision):
    if git(mirror, "rev-parse", revision).decode().strip() != revision:
        raise ValueError("The supplied revision must be the complete existing commit hash")
    entries = {}
    for raw in git(mirror, "ls-tree", "-rz", "-r", revision).split(b"\0"):
        if not raw: continue
        metadata, path = raw.split(b"\t", 1)
        mode, kind, digest = metadata.decode().split()
        if kind != "blob" or mode not in ("100644", "100755", "120000"):
            raise ValueError("Unsupported pinned tree entry: " + metadata.decode())
        entries[path.decode()] = (mode, digest)
    if not entries: raise ValueError("Pinned Git tree is empty")
    return entries


def archive_entries(archive, revision):
    prefix = "aws-sdk-swift-" + revision + "/"
    def relative_path(name):
        if not name.startswith(prefix): raise ValueError("Unexpected archive root: " + name)
        relative = name[len(prefix):]
        parts = PurePosixPath(relative).parts
        if relative and (relative.startswith("/") or any(part in (".", "..") for part in parts) or str(PurePosixPath(relative)) != relative.rstrip("/")):
            raise ValueError("Unsafe or noncanonical archive path: " + name)
        return relative
    def entry(relative, mode, data):
        encoded = b"blob " + str(len(data)).encode() + b"\0" + data
        return relative, mode, hashlib.sha1(encoded).hexdigest(), encoded
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                relative = relative_path(member.filename)
                if member.is_dir(): continue
                permission = member.external_attr >> 16
                mode = "120000" if stat.S_ISLNK(permission) else "100755" if permission & 0o111 else "100644"
                if stat.S_IFMT(permission) not in (0, stat.S_IFREG, stat.S_IFLNK): raise ValueError("Unsupported ZIP entry: " + member.filename)
                yield entry(relative, mode, source.read(member))
        return
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            relative = relative_path(member.name)
            if member.isdir(): continue
            if member.issym(): data, mode = member.linkname.encode(), "120000"
            elif member.isfile():
                handle = source.extractfile(member)
                if handle is None: raise ValueError("Unreadable archive entry: " + member.name)
                data, mode = handle.read(), "100755" if member.mode & 0o111 else "100644"
            else: raise ValueError("Unsupported archive entry: " + member.name)
            yield entry(relative, mode, data)


def verify(archive, mirror, revision, materialize=False, version=None):
    expected = tree(mirror, revision)
    seen = set();total_bytes = 0
    for path, mode, digest, encoded in archive_entries(archive, revision):
        if path in seen: raise ValueError("Duplicate archive path: " + path)
        if expected.get(path) != (mode, digest): raise ValueError("Archive differs from exact Git blob/mode: " + path)
        seen.add(path);total_bytes += len(encoded)
    if seen != set(expected): raise ValueError("Archive is missing pinned paths: " + repr(sorted(set(expected) - seen)[:10]))
    result = {"revision": revision, "tree": git(mirror, "rev-parse", revision + "^{tree}").decode().strip(),
              "verified_blob_paths": len(seen), "verified_git_object_bytes": total_bytes,
              "archive_path": str(archive), "archive_sha256": hashlib.file_digest(archive.open("rb"), "sha256").hexdigest(),
              "all_paths_contents_and_executable_modes_match": True, "materialized": False}
    if materialize:
        if not version: raise ValueError("Materializing requires the existing pinned version tag")
        # No mirror changes occur until the entire archive has passed the first pass.
        objects = mirror / "objects"
        for path, mode, digest, encoded in archive_entries(archive, revision):
            if expected[path] != (mode, digest): raise ValueError("Archive changed after verification: " + path)
            destination = objects / digest[:2] / digest[2:]
            destination.parent.mkdir(exist_ok=True)
            try:
                with destination.open("xb") as output: output.write(zlib.compress(encoded))
            except FileExistsError:
                if hashlib.sha1(zlib.decompress(destination.read_bytes())).hexdigest() != digest:
                    raise ValueError("Existing local Git object is corrupt: " + digest)
        existing = subprocess.run(["git", "-C", str(mirror), "rev-parse", "refs/tags/" + version], capture_output=True, text=True)
        if existing.returncode == 0 and existing.stdout.strip() != revision: raise ValueError("Preserve conflicting existing version tag")
        git(mirror, "update-ref", "refs/tags/" + version, revision)
        missing = [line for line in git(mirror, "rev-list", "--objects", "--missing=print", revision).decode().splitlines() if line.startswith("?")]
        if missing: raise ValueError("Mirror still contains missing pinned objects: " + repr(missing[:10]))
        fsck = subprocess.run(["git", "-C", str(mirror), "fsck", "--full", "--no-reflogs"], env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}, capture_output=True, text=True)
        if fsck.returncode != 0: raise ValueError("Materialized mirror failed Git fsck: " + fsck.stdout + fsck.stderr)
        result.update(materialized=True, mirror_path=str(mirror), version_tag=version, git_fsck_exit_code=fsck.returncode)
    return result


def hydrate(mirror, revision, version, proof, maximum_seconds):
    expected = tree(mirror, revision)
    identifiers = sorted({digest for _, digest in expected.values()})
    def missing():
        output = subprocess.check_output(["git", "-C", str(mirror), "cat-file", "--batch-check"],
            input=("\n".join(identifiers) + "\n").encode(), env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
        return [line.split()[0].decode() for line in output.splitlines() if line.endswith(b" missing")]
    result = {"revision": revision, "tree": git(mirror, "rev-parse", revision + "^{tree}").decode().strip(),
              "mirror_path": str(mirror), "verified_blob_paths": len(expected), "commands": [],
              "pid": os.getpid(), "status": "running", "started_at_epoch": time.time(), "timeout_seconds": maximum_seconds + 30,
              "strategy": "Fetch exact pinned Git blob objects in resumable bounded batches", "passed": False}
    remaining = missing();result["initial_missing_blobs"] = len(remaining)
    started = time.monotonic()
    try:
        while remaining:
            budget = maximum_seconds - (time.monotonic() - started)
            if budget <= 0: raise RuntimeError("Bounded hydration deadline reached; verified fetched objects retained")
            batch = remaining[:32]
            command = ["git", "-C", str(mirror), "-c", "http.version=HTTP/1.1", "fetch", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance", "https://github.com/awslabs/aws-sdk-swift", *batch]
            log = proof.with_name(proof.stem + "-batch-" + str(len(result["commands"]) + 1).zfill(3) + ".log")
            with log.open("w") as output:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                state = {"command": command, "pid": process.pid, "log_path": str(log), "status": "running"}
                result["commands"].append(state);proof.write_text(json.dumps(result, indent=2) + "\n")
                try: code = process.wait(timeout=min(120, budget))
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM);process.wait();code = 124
                state.update(status="completed" if code == 0 else "failed", exit_code=code)
            remaining = missing();result["remaining_missing_blobs"] = len(remaining)
            proof.write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({"batch": len(result["commands"]), "remaining_missing_blobs": len(remaining), "exit_code": code}), flush=True)
            if code != 0: raise RuntimeError("Exact-object batch failed; successful previous objects retained: " + str(log))
        if not version: raise ValueError("Hydration requires the approved version tag")
        existing = subprocess.run(["git", "-C", str(mirror), "rev-parse", "refs/tags/" + version], capture_output=True, text=True)
        if existing.returncode == 0 and existing.stdout.strip() != revision: raise ValueError("Preserve conflicting existing version tag")
        git(mirror, "update-ref", "refs/tags/" + version, revision)
        fsck = subprocess.run(["git", "-C", str(mirror), "fsck", "--full", "--no-reflogs"], env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}, capture_output=True, text=True)
        result["git_fsck_exit_code"] = fsck.returncode
        if fsck.returncode != 0: raise RuntimeError("Hydrated mirror failed full Git integrity check: " + fsck.stdout + fsck.stderr)
        result.update(passed=True, all_paths_contents_and_executable_modes_match=True, version_tag=version)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        result["failure"] = str(error)
    result["elapsed_seconds"] = time.monotonic() - started
    result["status"] = "completed" if result["passed"] else "failed"
    result["remaining_missing_blobs"] = len(missing())
    proof.write_text(json.dumps(result, indent=2) + "\n")
    return result


def self_test():
    with tempfile.TemporaryDirectory(prefix="s3-pinned-archive-") as directory:
        working = Path(directory) / "repo";working.mkdir()
        subprocess.run(["git", "init", "-q", str(working)], check=True)
        (working / "test.swift").write_text("pinned fixture\n")
        git(working, "add", "test.swift")
        git(working, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        revision = git(working, "rev-parse", "HEAD").decode().strip();archive = Path(directory) / "source.tar.gz"
        def make(data=b"pinned fixture\n", mode=0o644, name="test.swift"):
            with tarfile.open(archive, "w:gz") as output:
                member = tarfile.TarInfo("aws-sdk-swift-" + revision + "/" + name);member.size = len(data);member.mode = mode
                output.addfile(member, io.BytesIO(data))
        make();assert verify(archive, working, revision)["verified_blob_paths"] == 1
        rejected = []
        for case, arguments in (("modified blob", {"data": b"different"}), ("changed executable mode", {"mode": 0o755}), ("extra path", {"name": "extra.swift"}), ("path traversal", {"name": "../test.swift"})):
            make(**arguments)
            try: verify(archive, working, revision)
            except ValueError: rejected.append(case)
            else: raise AssertionError("Invalid archive passed: " + case)
        make();mirror = Path(directory) / "mirror.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(working), str(mirror)], check=True)
        assert verify(archive, mirror, revision, materialize=True, version="fixture")["git_fsck_exit_code"] == 0
        archive = Path(directory) / "source.zip"
        def make_zip(data=b"pinned fixture\n", mode=0o100644, name="test.swift"):
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
                member = zipfile.ZipInfo("aws-sdk-swift-" + revision + "/" + name);member.create_system = 3;member.external_attr = mode << 16
                output.writestr(member, data)
        make_zip();assert verify(archive, mirror, revision, materialize=True, version="fixture")["git_fsck_exit_code"] == 0
        for case, arguments in (("ZIP modified blob", {"data": b"different"}), ("ZIP changed executable mode", {"mode": 0o100755}), ("ZIP extra path", {"name": "extra.swift"}), ("ZIP path traversal", {"name": "../test.swift"})):
            make_zip(**arguments)
            try: verify(archive, mirror, revision)
            except ValueError: rejected.append(case)
            else: raise AssertionError("Invalid ZIP archive passed: " + case)
        hydration_proof = Path(directory) / "hydration.json"
        assert hydrate(mirror, revision, "fixture", hydration_proof, 10)["passed"]
        blob = git(working, "rev-parse", "HEAD:test.swift").decode().strip()
        # Remove one object from this temporary fixture only, never an SDK/cache.
        (mirror / "objects" / blob[:2] / blob[2:]).unlink()
        incomplete = hydrate(mirror, revision, "fixture", hydration_proof, 0)
        assert not incomplete["passed"] and incomplete["remaining_missing_blobs"] == 1
        assert git(working, "cat-file", "blob", blob) == b"pinned fixture\n"
        rejected.append("incomplete exact-object hydration cannot pass")
        return {"passed": True, "scope": "Temporary local Git fixtures only", "rejected": rejected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path);parser.add_argument("--mirror", type=Path)
    parser.add_argument("--revision");parser.add_argument("--version")
    parser.add_argument("--materialize", action="store_true");parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--hydrate", action="store_true");parser.add_argument("--maximum-seconds", type=int, default=900)
    parser.add_argument("--proof", type=Path)
    args = parser.parse_args()
    if args.self_test: result = self_test()
    elif args.hydrate:
        if not all((args.mirror, args.revision, args.version, args.proof)): parser.error("Hydration requires --mirror, --revision, --version and --proof")
        result = hydrate(args.mirror, args.revision, args.version, args.proof, args.maximum_seconds)
    else:
        if not all((args.archive, args.mirror, args.revision)): parser.error("--archive, --mirror and --revision are required")
        result = verify(args.archive, args.mirror, args.revision, args.materialize, args.version)
    if args.proof:
        args.proof.parent.mkdir(parents=True, exist_ok=True);args.proof.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "commands"}, indent=2))
    return 0 if result.get("passed", True) else 1


if __name__ == "__main__": raise SystemExit(main())
