import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


cache = module('ci_cache', 'ci-cache-key.py')
results = module('ci_results', 'ci-results.py')
ui_suite = module('ui_suite_changes', 'ui-suite-changes.py')


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for path in ['.github/workflows/ci.yml', '.github/workflows/swift-tests.yml', 'LPMVault/Scripts/ci-cache-key.py',
                     'LPMVault/Scripts/verify-env-engine.py', 'LPMVault/Vendor/EnvEngine/provenance.json',
                     'LPMVault/Package.swift', 'LPMVault/Package.resolved',
                     'LPMVault/LPMVault.xcodeproj/project.pbxproj', 'LPMVault/Info.plist',
                     'LPMVault/LPMVault.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
                     'LPMVault/Sources/View.swift', 'LPMVault/Tests/ViewTests.swift']:
            self.write(path, 'initial')

    def write(self, path, value):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def identity(self, kind='swift', toolchain='macOS-arm64-Xcode-fixture'):
        return cache.cache_identity(kind, self.root, toolchain)

    def test_source_changes_reuse_compatible_intermediates_with_a_new_save_key(self):
        before = self.identity()
        self.write('LPMVault/Sources/View.swift', 'changed')
        after = self.identity()
        self.assertEqual(before[0], after[0])
        self.assertNotEqual(before[1], after[1])

    def test_new_and_removed_source_files_invalidate_the_save_key(self):
        before = self.identity()
        self.write('LPMVault/Sources/New.swift', 'new')
        self.assertNotEqual(before[1], self.identity()[1])
        (self.root / 'LPMVault/Sources/New.swift').unlink()
        self.assertEqual(before, self.identity())

    def test_tests_invalidate_swift_but_do_not_rebuild_release_outputs(self):
        swift, release = self.identity(), self.identity('release')
        self.write('LPMVault/Tests/ViewTests.swift', 'changed')
        self.assertNotEqual(swift[1], self.identity()[1])
        self.assertEqual(release, self.identity('release'))

    def test_toolchain_dependencies_and_flags_reject_incompatible_intermediates(self):
        before = self.identity()
        self.assertNotEqual(before[0], self.identity(toolchain='other-SDK-build')[0])
        for path in ['LPMVault/Package.swift', 'LPMVault/Package.resolved',
                     'LPMVault/Vendor/EnvEngine/provenance.json', '.github/workflows/ci.yml', '.github/workflows/swift-tests.yml']:
            with self.subTest(path=path):
                self.write(path, 'changed')
                self.assertNotEqual(before[0], self.identity()[0])
                self.write(path, 'initial')

    def test_engine_cache_cannot_restore_outputs_of_a_different_pinned_revision(self):
        before = self.identity('engine')
        self.write('LPMVault/Vendor/EnvEngine/provenance.json', 'new revision')
        self.assertNotEqual(before[0], self.identity('engine')[0])

    def test_release_dependency_resolution_invalidates_intermediates(self):
        before = self.identity('release')
        self.write('LPMVault/LPMVault.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'updated')
        self.assertNotEqual(before[0], self.identity('release')[0])

    def test_other_files_and_mtimes_do_not_invalidate_the_cache(self):
        before = self.identity()
        self.write('README.md', 'unrelated')
        self.write('LPMVault/.build/generated.swift', 'generated')
        (self.root / 'LPMVault/Sources/View.swift').touch()
        self.assertEqual(before, self.identity())

    def test_unchanged_checkout_inputs_retain_their_build_timestamps(self):
        source = self.root / 'LPMVault/Sources/View.swift'
        os.utime(source, ns=(1_000_000_000, 1_000_000_000))
        cache.source_times('swift', self.root, restore=False)
        source.touch()
        cache.source_times('swift', self.root, restore=True)
        self.assertEqual(source.stat().st_mtime_ns, 1_000_000_000)

    def test_changed_inputs_keep_a_timestamp_that_invalidates_the_build(self):
        source = self.root / 'LPMVault/Sources/View.swift'
        cache.source_times('swift', self.root, restore=False)
        recorded = source.stat().st_mtime_ns
        source.write_text('changed')
        os.utime(source, ns=(recorded, recorded))
        cache.source_times('swift', self.root, restore=True)
        self.assertGreater(source.stat().st_mtime_ns, recorded)

    def test_unchanged_engine_headers_retain_their_build_timestamps(self):
        relative = 'LPMVault/Vendor/EnvEngine/LPMEnv.xcframework/Headers/module.modulemap'
        self.write(relative, 'module LPMEnv {}')
        header = self.root / relative
        previous = header.stat().st_mtime_ns
        cache.source_times('swift', self.root, restore=False)
        header.touch()
        cache.source_times('swift', self.root, restore=True)
        self.assertEqual(header.stat().st_mtime_ns, previous)

    @unittest.skipUnless(shutil.which('swift'), 'Swift compiler required')
    def test_changed_source_rebuilds_after_cache_restoration(self):
        package = self.root / 'LPMVault'
        self.write('LPMVault/Package.swift', '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TimestampFixture", targets: [.executableTarget(name: "TimestampFixture", path: "Sources")])
''')
        self.write('LPMVault/Package.resolved', '{"pins":[],"version":2}')
        source = package / 'Sources/View.swift'
        source.write_text('print(1)\n')
        command = ['swift', 'run', '--package-path', str(package), '--disable-index-store',
                   '-Xswiftc', '-warnings-as-errors', 'TimestampFixture']

        def output():
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout.strip().splitlines()[-1]

        self.assertEqual(output(), '1')
        cache.source_times('swift', self.root, restore=False)
        previous = source.stat().st_mtime_ns
        source.write_text('print(2)\n')
        os.utime(source, ns=(previous, previous))
        cache.source_times('swift', self.root, restore=True)
        self.assertEqual(output(), '2')

    def test_new_deleted_or_unrelated_files_are_not_restored(self):
        cache.source_times('release', self.root, restore=False)
        (self.root / 'LPMVault/Sources/View.swift').unlink()
        for path in ['LPMVault/Sources/New.swift', 'LPMVault/Tests/ViewTests.swift', 'README.md']:
            self.write(path, 'new')
            target = self.root / path
            previous = target.stat().st_mtime_ns
            cache.source_times('release', self.root, restore=True)
            self.assertEqual(target.stat().st_mtime_ns, previous)

    def test_absent_or_invalid_timestamp_metadata_leaves_the_checkout_fresh(self):
        source = self.root / 'LPMVault/Sources/View.swift'
        previous = source.stat().st_mtime_ns
        cache.source_times('swift', self.root, restore=True)
        self.assertEqual(source.stat().st_mtime_ns, previous)
        cache.source_times('swift', self.root, restore=False)
        metadata = self.root / 'LPMVault/.build/ci-source-times.json'
        for value in ['{', '{}', '{"version":1,"files":{"LPMVault/Sources/View.swift":{"hash":"initial","mtime_ns":-1}}}']:
            with self.subTest(value=value):
                metadata.write_text(value)
                cache.source_times('swift', self.root, restore=True)
                self.assertEqual(source.stat().st_mtime_ns, previous)


class RequiredCheckTests(unittest.TestCase):
    def test_every_parallel_job_must_succeed(self):
        passed = {name: {'result': 'success'} for name in ['swift', 'engine', 'release']}
        self.assertEqual(results.failures(passed), [])
        for job in passed:
            for result in ['failure', 'cancelled', 'skipped', None]:
                with self.subTest(job=job, result=result):
                    changed = {**passed, job: {'result': result}}
                    self.assertEqual(results.failures(changed), [job])
            with self.subTest(missing=job):
                self.assertEqual(results.failures({name: value for name, value in passed.items() if name != job}), [job])

    def test_renaming_a_dependency_cannot_silently_bypass_its_gate(self):
        changed = {name: {'result': 'success'} for name in ['swift', 'engine', 'renamed_release']}
        self.assertEqual(results.failures(changed), ['release', 'renamed_release'])


class UISuiteChangeTests(unittest.TestCase):
    UI_TESTS = 'extension SheetInteractionTests {\n\t@Suite("Quitting")\n\tstruct QuitTests {}\n}\n'
    OTHER_TESTS = '@Suite("Store")\nstruct StoreTests {\n\t@Test func loads() {}\n}\n'
    SUPPORT = 'func waitUntil() {}\n'

    def reason(self, path, before=None, after=None):
        return ui_suite.reason(path, before, after)

    def test_a_change_to_the_suite_or_a_suite_nested_in_it_needs_the_suite(self):
        suite = '@Suite("Sheet interaction regressions", .serialized)\nstruct SheetInteractionTests {}\n'
        self.assertIsNotNone(self.reason('LPMVault/Tests/SheetInteractionTests.swift', suite, suite + '// changed\n'))
        self.assertIsNotNone(self.reason('LPMVault/Tests/QuitTests.swift', self.OTHER_TESTS + self.UI_TESTS, self.OTHER_TESTS + self.UI_TESTS + '// changed\n'))

    def test_adding_removing_or_moving_ui_tests_needs_the_suite(self):
        self.assertIsNotNone(self.reason('LPMVault/Tests/New.swift', after=self.UI_TESTS))
        self.assertIsNotNone(self.reason('LPMVault/Tests/Old.swift', before=self.UI_TESTS))
        self.assertIsNotNone(self.reason('LPMVault/Tests/Moved.swift', self.OTHER_TESTS + self.UI_TESTS, self.OTHER_TESTS))

    def test_test_support_code_needs_the_suite(self):
        self.assertIsNotNone(self.reason('LPMVault/Tests/Waiting.swift', self.SUPPORT, self.SUPPORT + '// changed\n'))

    def test_a_change_to_how_the_suite_runs_needs_it(self):
        for path in ui_suite.RUNNER:
            with self.subTest(path=path):
                self.assertIsNotNone(self.reason(path, 'before', 'after'))

    def test_other_tests_app_code_and_other_files_leave_it_to_the_label(self):
        self.assertIsNone(self.reason('LPMVault/Tests/StoreTests.swift', self.OTHER_TESTS, self.OTHER_TESTS + '// changed\n'))
        self.assertIsNone(self.reason('LPMVault/Tests/XCStoreTests.swift', after='final class StoreTests: XCTestCase {}\n'))
        for path in ['LPMVault/Sources/Views/Sheet.swift', '.github/workflows/ci.yml', 'web/nginx.conf', 'LPMVault/Tests/Fixtures/notes.txt']:
            with self.subTest(path=path):
                self.assertIsNone(self.reason(path, 'before', 'after'))

    def test_runner_files_and_suite_name_match_the_repository(self):
        root = Path(__file__).resolve().parents[3]
        for path in ui_suite.RUNNER:
            with self.subTest(path=path):
                self.assertTrue((root / path).is_file())
        workflow = (root / '.github/workflows/swift-tests.yml').read_text()
        self.assertIn(f'SWIFT_TEST_ISOLATED_SUITE: LPMVaultTests.{ui_suite.SUITE}\n', workflow)

    def test_a_pull_requests_merge_commit_is_compared_with_its_base(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        environment = {**os.environ, 'GIT_AUTHOR_NAME': 'Test', 'GIT_AUTHOR_EMAIL': 'test@example.com',
                       'GIT_COMMITTER_NAME': 'Test', 'GIT_COMMITTER_EMAIL': 'test@example.com'}

        def git(*arguments):
            subprocess.run(['git', *arguments], cwd=root, env=environment, check=True, capture_output=True)

        def commit(files, message):
            for path, text in files.items():
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                if text is None:
                    (root / path).unlink()
                else:
                    (root / path).write_text(text)
            git('add', '--all')
            git('commit', '--quiet', '--message', message)

        git('init', '--quiet', '--initial-branch', 'main')
        commit({'LPMVault/Tests/QuitTests.swift': self.UI_TESTS, 'LPMVault/Tests/StoreTests.swift': self.OTHER_TESTS,
                'LPMVault/Tests/Old.swift': self.UI_TESTS}, 'base')
        git('switch', '--quiet', '--create', 'feature')
        commit({'LPMVault/Tests/StoreTests.swift': self.OTHER_TESTS + '// changed\n'}, 'other tests')
        git('switch', '--quiet', 'main')
        commit({'LPMVault/Sources/App.swift': 'app\n'}, 'base moves on')
        git('merge', '--quiet', '--no-ff', '--no-edit', 'feature')
        self.assertEqual(ui_suite.ui_suite_changes(root, 'HEAD^1', 'HEAD'), [])

        git('switch', '--quiet', 'feature')
        commit({'LPMVault/Tests/QuitTests.swift': self.UI_TESTS + '// changed\n', 'LPMVault/Tests/Old.swift': None}, 'ui tests')
        git('switch', '--quiet', 'main')
        git('merge', '--quiet', '--no-ff', '--no-edit', 'feature')
        self.assertEqual([path for path, _ in ui_suite.ui_suite_changes(root, 'HEAD^1', 'HEAD')],
                         ['LPMVault/Tests/Old.swift', 'LPMVault/Tests/QuitTests.swift'])


if __name__ == '__main__':
    unittest.main()
