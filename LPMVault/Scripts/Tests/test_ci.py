import importlib.util
from pathlib import Path
import tempfile
import unittest


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


cache = module('ci_cache', 'ci-cache-key.py')
results = module('ci_results', 'ci-results.py')


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for path in ['.github/workflows/ci.yml', 'LPMVault/Scripts/ci-cache-key.py',
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
                     'LPMVault/Vendor/EnvEngine/provenance.json', '.github/workflows/ci.yml']:
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


if __name__ == '__main__':
    unittest.main()
