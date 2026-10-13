#!/usr/bin/env python3
"""Exercise audit-runner rejection paths using actual child-process results."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile

import verify_audit as runner


def main():
    original_root, original_artifacts = runner.ROOT, runner.ARTIFACTS
    queue = runner.load_queue()
    checks = []

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    with tempfile.TemporaryDirectory(prefix="audit-runner-selftest-") as temporary:
        root = Path(temporary)
        (root / "Sources").mkdir()
        (root / "Sources" / "production.swift").write_text("// Synthetic runner input\n")
        queue_path = root / "AUDIT_QUEUE.json"
        queue_path.write_text(json.dumps(queue))
        executable = root / "xcrun"
        executable.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
mode = os.environ.get("AUDIT_RUNNER_FIXTURE", "pass")
path = Path(sys.argv[sys.argv.index("--xunit-output") + 1])
count = 1 if mode == "few" else 6
extra = '<skipped/>' if mode == "skipped" else '<failure message="fixture"/>' if mode == "failure" else ''
if mode != "no-report":
    path.write_text('<testsuites><testsuite>' + ''.join('<testcase name="case' + str(i) + '">' + extra + '</testcase>' for i in range(count)) + '</testsuite></testsuites>')
if mode == "changed":
    source = Path.cwd() / "Sources" / "production.swift"
    source.write_text(source.read_text() + '// changed during check\\n')
raise SystemExit(1 if mode == "exit-failure" else 0)
''')
        executable.chmod(0o755)
        old_path = os.environ["PATH"]
        runner.ROOT, runner.ARTIFACTS = root, root / "artifacts" / "audit"
        os.environ["PATH"] = str(root) + os.pathsep + old_path
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                check("exact 85-item queue accepted", len(runner.load_queue()["implementation_items"]) == 85)
                malformed = json.loads(json.dumps(queue))
                malformed["implementation_items"].pop()
                queue_path.write_text(json.dumps(malformed))
                check("missing required ID rejected", runner.main(["--all"]) == 1)
                queue_path.write_text(json.dumps(queue))
                try:
                    runner.main(["--id", "UNKNOWN"])
                except SystemExit as error:
                    check("unknown ID rejected", error.code == 2)
                else:
                    raise AssertionError("unknown ID accepted")
                registered = runner.SWIFT_SUITES.pop("N02")
                try:
                    check("unregistered all-check rejected", runner.main(["--all"]) == 1)
                finally:
                    runner.SWIFT_SUITES["N02"] = registered
                item = next(x for x in queue["implementation_items"] if x["id"] == "N02")
                for mode in ("pass", "few", "skipped", "failure", "exit-failure", "no-report", "changed"):
                    os.environ["AUDIT_RUNNER_FIXTURE"] = mode
                    outcome = runner.run_id(item, source_retries=0)
                    check(mode + " process result handled", outcome == (mode == "pass"))
                    proof = json.loads((runner.ARTIFACTS / "N02.json").read_text())
                    check(mode + " proof agrees with process", proof["passed"] == outcome)
                check("changed source cannot retain passing proof", not proof["source_unchanged_during_check"])
        finally:
            runner.ROOT, runner.ARTIFACTS = original_root, original_artifacts
            os.environ["PATH"] = old_path
            os.environ.pop("AUDIT_RUNNER_FIXTURE", None)
    output = original_artifacts / "audit-runner-selftest.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"passed": True, "assertion_count": len(checks), "assertions": checks,
        "command": [sys.executable, str(Path(__file__).resolve())],
        "scope": "Runner orchestration with real synthetic child processes; not production behavior or app integration."}, indent=2) + "\n")
    print("PASS: audit runner self-test; " + str(len(checks)) + " assertions; " + str(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
