import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SwiftWatchdogTests(unittest.TestCase):
    def launch(self, report=None, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = root / 'swift'
            swift.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if '--xunit-output' in sys.argv and 'FAKE_SWIFT_REPORT' in os.environ:
    path = sys.argv[sys.argv.index('--xunit-output') + 1]
    Path(path).write_text(os.environ['FAKE_SWIFT_REPORT'])
sys.exit(int(os.environ['FAKE_SWIFT_EXIT']))
''')
            swift.chmod(0o755)
            environment = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                           'FAKE_SWIFT_EXIT': str(exit_code), 'SWIFT_TEST_POLL_INTERVAL': '0.01'}
            if report is not None:
                environment['FAKE_SWIFT_REPORT'] = report
            return subprocess.run(['bash', str(Path(__file__).resolve().parents[1] / 'swift-test-watchdog.sh')],
                                  env=environment, capture_output=True, text=True, timeout=15)

    def test_success_without_a_complete_report_fails(self):
        for report in [None, '', '<testsuites>', '<testsuites><testsuite tests="0"/></testsuites>',
                       '<testsuites><testsuite tests="2"><testcase/></testsuite></testsuites>',
                       '<testsuites><testsuite tests="1" failures="1"><testcase><failure/></testcase></testsuite></testsuites>']:
            with self.subTest(report=report):
                result = self.launch(report)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_complete_passing_report_succeeds(self):
        result = self.launch('<testsuites><testsuite tests="2" failures="0" errors="0"><testcase/><testcase/></testsuite></testsuites>')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_complete_report_with_skipped_benchmarks_succeeds(self):
        for total in [1, 2]:
            with self.subTest(total=total):
                result = self.launch(f'<testsuites><testsuite tests="{total}" skipped="1" failures="0" errors="0"><testcase/><testcase><skipped/></testcase></testsuite></testsuites>')
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_skipped_or_failing_cases_cannot_hide_an_incomplete_run(self):
        for report in [
            '<testsuites><testsuite tests="1" skipped="1"><testcase><skipped/></testcase></testsuite></testsuites>',
            '<testsuites><testsuite tests="2" skipped="1"><testcase/><testcase/></testsuite></testsuites>',
            '<testsuites><testsuite tests="1"><testcase><failure/></testcase></testsuite></testsuites>',
            '<testsuites><testsuite tests="1"><testcase><error/></testcase></testsuite></testsuites>',
        ]:
            with self.subTest(report=report):
                result = self.launch(report)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_test_process_failure_is_preserved(self):
        result = self.launch(exit_code=7)
        self.assertEqual(result.returncode, 7, result.stderr)


if __name__ == '__main__':
    unittest.main()
