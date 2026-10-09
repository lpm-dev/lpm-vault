import os
from pathlib import Path
import subprocess
import tempfile
import unittest


# A `swift` that lists FAKE_SWIFT_TESTS and, when run, reports the tests its
# filters select the way Swift Testing does: FAKE_SWIFT_DROP leaves the first
# out and FAKE_SWIFT_EXTRA adds one. FAKE_SWIFT_RAN collects what it reported.
FAKE_SWIFT = '''#!/usr/bin/env python3
import os
from pathlib import Path
import re
import sys
from xml.sax.saxutils import quoteattr
arguments = sys.argv[1:]
if arguments[:2] == ['test', 'list']:
    sys.stdout.write(os.environ.get('FAKE_SWIFT_TESTS', ''))
    sys.exit(0)
if '--xunit-output' in arguments:
    path = arguments[arguments.index('--xunit-output') + 1]
    if 'FAKE_SWIFT_REPORT' in os.environ:
        Path(path).write_text(os.environ['FAKE_SWIFT_REPORT'])
    elif 'FAKE_SWIFT_TESTS' in os.environ:
        filters = [arguments[index + 1] for index, argument in enumerate(arguments) if argument == '--filter']
        tests = [test for test in os.environ['FAKE_SWIFT_TESTS'].split() if not filters or any(re.search(f, test) for f in filters)]
        if os.environ.get('FAKE_SWIFT_DROP'):
            tests = tests[1:]
        tests += os.environ.get('FAKE_SWIFT_EXTRA', '').split()
        cases = []
        for test in tests:
            module, _, path_ = test.partition('.')
            *suites, name = path_.split('/')
            cases.append(f'<testcase classname={quoteattr(".".join([module, *suites]))} name={quoteattr(name)}/>')
        Path(path).write_text(f'<testsuites><testsuite tests="{len(cases)}" failures="0" errors="0">{"".join(cases)}</testsuite></testsuites>')
        if 'FAKE_SWIFT_RAN' in os.environ:
            with open(os.environ['FAKE_SWIFT_RAN'], 'a') as ran:
                ran.writelines(test + '\\n' for test in tests)
sys.exit(int(os.environ['FAKE_SWIFT_EXIT']))
'''

TESTS = [
    'LPMVaultTests.AddVariableDraftTests/caseCollision()',
    'LPMVaultTests.SchemaGroupModelTests/singleMember(mode:hint:)',
    'LPMVaultTests.SchemaGroupModelTests/single()',
    'LPMVaultTests.SheetInteractionTests/SchemaGroupInteractionTests/largeGroupFiltered()',
    'LPMVaultTests.SheetInteractionTests/rendersSheet()',
    'LPMVaultTests.unknownCliApprovalPresentationIsTruthful()',
] + [f'LPMVaultTests.GeneratedTests/test{index}()' for index in range(30)] + [
    f'LPMVaultTests.SheetInteractionTests/Nested/screen{index}()' for index in range(12)]


class SwiftWatchdogTests(unittest.TestCase):
    def launch(self, report=None, exit_code=0, **environment):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = root / 'swift'
            swift.write_text(FAKE_SWIFT)
            swift.chmod(0o755)
            environment = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                           'FAKE_SWIFT_EXIT': str(exit_code), 'SWIFT_TEST_POLL_INTERVAL': '0.01', **environment}
            if report is not None:
                environment['FAKE_SWIFT_REPORT'] = report
            return subprocess.run(['bash', str(Path(__file__).resolve().parents[1] / 'swift-test-watchdog.sh')],
                                  env=environment, capture_output=True, text=True, timeout=15)

    def test_shards_run_every_test_exactly_once(self):
        with tempfile.TemporaryDirectory() as directory:
            shards = []
            for shard in range(1, 4):
                ran = Path(directory) / f'ran-{shard}'
                result = self.launch(FAKE_SWIFT_TESTS='\n'.join(TESTS), SWIFT_TEST_SHARD=f'{shard}/3', FAKE_SWIFT_RAN=str(ran))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                shards.append(ran.read_text().split() if ran.exists() else [])
            self.assertEqual(sorted(test for shard in shards for test in shard), sorted(TESTS))
            self.assertTrue(all(shards), 'Every shard has tests')

    def test_an_isolated_suite_runs_apart_from_every_other_test(self):
        suite = 'LPMVaultTests.SheetInteractionTests'
        inside = sorted(test for test in TESTS if test.startswith(suite + '/'))
        with tempfile.TemporaryDirectory() as directory:
            shards = []
            for shard in range(1, 4):
                ran = Path(directory) / f'ran-{shard}'
                result = self.launch(FAKE_SWIFT_TESTS='\n'.join(TESTS), SWIFT_TEST_SHARD=f'{shard}/3',
                                     SWIFT_TEST_ISOLATED_SUITE=suite, FAKE_SWIFT_RAN=str(ran))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                shards.append(sorted(ran.read_text().split()) if ran.exists() else [])
            self.assertEqual(shards[0], sorted(set(TESTS) - set(inside)), 'The first shard runs everything outside the suite')
            self.assertEqual(sorted(shards[1] + shards[2]), inside, 'The other shards split the suite')
        for shard, isolated in [('1/1', suite), ('1/2', 'LPMVaultTests.MissingTests')]:
            with self.subTest(shard=shard, isolated=isolated):
                result = self.launch(FAKE_SWIFT_TESTS='\n'.join(TESTS), SWIFT_TEST_SHARD=shard, SWIFT_TEST_ISOLATED_SUITE=isolated)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_shard_that_runs_other_tests_than_its_own_fails(self):
        for extra in [{'FAKE_SWIFT_DROP': '1'}, {'FAKE_SWIFT_EXTRA': 'LPMVaultTests.Elsewhere/stray()'}]:
            with self.subTest(extra=extra):
                result = self.launch(FAKE_SWIFT_TESTS='\n'.join(TESTS), SWIFT_TEST_SHARD='1/2', **extra)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('the shard ran', result.stdout + result.stderr)

    def test_invalid_shards_and_ambiguous_test_names_fail_before_running(self):
        for shard, tests in [('0/3', TESTS), ('4/3', TESTS), ('2', TESTS), ('1/3', []),
                             ('1/1', ['LPMVaultTests.Suite/test()', 'LPMVaultTests.Suite/test()Extra']),
                             ('1/1', ['LPMVaultTests.Suite/LPMVaultTests.test()'])]:
            with self.subTest(shard=shard, tests=tests):
                result = self.launch(FAKE_SWIFT_TESTS='\n'.join(tests), SWIFT_TEST_SHARD=shard)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Could not choose the tests', result.stdout + result.stderr)

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
