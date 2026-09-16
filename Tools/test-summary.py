#!/usr/bin/env python3
"""Prints a one-line verdict for an .xcresult bundle, plus any failures.

xcodebuild's own output is unusable under -quiet, so `make test-app` runs this
against the result bundle instead.
"""
import json
import subprocess
import sys

bundle = sys.argv[1] if len(sys.argv) > 1 else ".build/TestResults.xcresult"

raw = subprocess.run(
    ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
    capture_output=True, text=True, check=True,
).stdout
summary = json.loads(raw)

print(
    f"{summary['result']}: {summary['passedTests']} passed, "
    f"{summary['failedTests']} failed, {summary['skippedTests']} skipped"
)

for failure in summary.get("testFailures", []):
    print(f"  FAIL {failure.get('testName', '?')}: {failure.get('failureText', '')}")

sys.exit(0 if summary["result"] == "Passed" else 1)
