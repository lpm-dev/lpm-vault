#!/usr/bin/env bash
# Runs `swift test` with the given arguments under a time limit. A run that
# hangs prints the stacks of the test process and fails, instead of holding
# the job until its timeout.
set -euo pipefail

limit="${SWIFT_TEST_TIME_LIMIT:-900}"
report_dir="$(mktemp -d)"
trap 'rm -rf -- "$report_dir"' EXIT
swift test "$@" --enable-swift-testing --disable-xctest --xunit-output "$report_dir/results.xml" &
runner=$!
deadline=$((SECONDS + limit))
while kill -0 "$runner" 2>/dev/null; do
	if ((SECONDS >= deadline)); then
		echo "::error::swift test ran longer than ${limit}s; sampling the test process"
		for pid in $(pgrep -f swiftpm-testing-helper || true); do
			report="${RUNNER_TEMP:-/tmp}/swift-test-hang-$pid.txt"
			if sample "$pid" 3 -file "$report" >/dev/null 2>&1; then
				cat "$report"
			fi
		done
		pkill -f swiftpm-testing-helper || true
		kill "$runner" 2>/dev/null || true
		exit 1
	fi
	sleep "${SWIFT_TEST_POLL_INTERVAL:-1}"
done
wait "$runner"

# AppKit can end the process successfully before Swift Testing finishes.
python3 - "$report_dir/results.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
    suites = [suite for suite in root.iter('testsuite') if not suite.findall('testsuite')]
    completed = 0
    for suite in suites:
        cases = suite.findall('testcase')
        skipped = sum(case.find('skipped') is not None for case in cases)
        active = len(cases) - skipped
        # Swift Testing reports skipped cases separately from its test count.
        if int(suite.get('tests', '0')) not in [active, len(cases)] or int(suite.get('skipped', '0')) != skipped:
            raise ValueError('missing or incomplete test cases')
        completed += active
    if completed == 0:
        raise ValueError('no completed test cases')
    if any(int(suite.get(field, '0')) for suite in suites for field in ['failures', 'errors']):
        raise ValueError('reported test failures')
    if next(root.iter('failure'), None) is not None or next(root.iter('error'), None) is not None:
        raise ValueError('reported test failures')
except (OSError, ET.ParseError, ValueError) as error:
    raise SystemExit('::error::Swift tests did not produce a complete passing report: ' + str(error))
PY
