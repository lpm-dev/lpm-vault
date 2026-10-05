#!/usr/bin/env bash
# Runs `swift test` with the given arguments under a time limit. A run that
# hangs prints the stacks of the test process and fails, instead of holding
# the job until its timeout.
set -euo pipefail

limit="${SWIFT_TEST_TIME_LIMIT:-900}"
swift test "$@" &
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
	sleep 5
done
wait "$runner"
