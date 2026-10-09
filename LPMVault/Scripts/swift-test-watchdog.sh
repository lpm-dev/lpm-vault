#!/usr/bin/env bash
# Runs `swift test` with the given arguments under a time limit. A run that
# hangs prints the stacks of the test process and fails, instead of holding
# the job until its timeout. With SWIFT_TEST_SHARD=K/N, it runs only the Kth
# of N shards of the tests, and fails unless exactly those ran.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
limit="${SWIFT_TEST_TIME_LIMIT:-900}"
report_dir="$(mktemp -d)"
trap 'rm -rf -- "$report_dir"' EXIT
filters=()
expected=""
if [[ -n "${SWIFT_TEST_SHARD:-}" ]]; then
	expected="$report_dir/shard-tests.txt"
	python3 "$script_dir/swift-test-shard.py" "$SWIFT_TEST_SHARD" "$expected" "$report_dir/shard-filters.txt" "$@"
	while IFS= read -r filter; do
		filters+=(--filter "$filter")
	done < "$report_dir/shard-filters.txt"
	echo "Shard $SWIFT_TEST_SHARD runs $(($(wc -l < "$expected"))) tests"
fi
swift test "$@" ${filters[@]+"${filters[@]}"} --enable-swift-testing --disable-xctest --xunit-output "$report_dir/results.xml" &
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
python3 - "$report_dir/results.xml" "$expected" <<'PY'
import sys
import xml.etree.ElementTree as ET


def identifier(case):
    """The case's test as `swift test list` names it: Module.Suite/Nested/test(), or Module.test() outside a suite."""
    module, _, suites = case.get('classname', '').partition('.')
    return module + '.' + '/'.join(suites.split('.') + [case.get('name', '')] if suites else [case.get('name', '')])


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
    if sys.argv[2]:
        with open(sys.argv[2]) as tests:
            expected = {line.strip() for line in tests if line.strip()}
        ran = {identifier(case) for case in root.iter('testcase')}
        if ran != expected:
            missing, extra = sorted(expected - ran), sorted(ran - expected)
            raise ValueError(f'the shard ran {len(ran)} of its {len(expected)} tests; missing {missing[:5]}, unexpected {extra[:5]}')
except (OSError, ET.ParseError, ValueError) as error:
    raise SystemExit('::error::Swift tests did not produce a complete passing report: ' + str(error))
PY
