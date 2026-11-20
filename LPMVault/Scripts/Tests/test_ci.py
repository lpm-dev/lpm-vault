import importlib.util
import json
import os
from pathlib import Path
import re
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
engine = module('engine_changes', 'engine-changes.py')
passed_tree = module('ci_passed_tree', 'ci-passed-tree.py')
results = module('ci_results', 'ci-results.py')
retry = module('ci_runner_retry', 'ci-runner-retry.py')
ui_suite = module('ui_suite_changes', 'ui-suite-changes.py')


class CacheIdentityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for path in ['.github/workflows/ci.yml', '.github/workflows/swift-tests.yml', '.github/workflows/release-bundle.yml',
                     'LPMVault/Scripts/ci-cache-key.py',
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
                     'LPMVault/Scripts/ci-cache-key.py', '.github/workflows/swift-tests.yml']:
            with self.subTest(path=path):
                self.write(path, 'changed')
                self.assertNotEqual(before[0], self.identity()[0])
                self.write(path, 'initial')

    def test_a_cache_follows_only_the_workflow_that_holds_its_build_command(self):
        builds = {'engine': 'ci.yml', 'swift': 'swift-tests.yml', 'release': 'release-bundle.yml'}
        before = {kind: self.identity(kind) for kind in builds}
        for workflow in ['ci.yml', 'swift-tests.yml', 'release-bundle.yml']:
            self.write('.github/workflows/' + workflow, 'changed')
            for kind, build in builds.items():
                with self.subTest(workflow=workflow, kind=kind):
                    (self.assertNotEqual if build == workflow else self.assertEqual)(before[kind][0], self.identity(kind)[0])
            self.write('.github/workflows/' + workflow, 'initial')
        for path in cache.cache_files('release', Path(__file__).resolve().parents[3])[0]:
            self.assertTrue(path.is_file(), path)

    def test_an_engine_change_reuses_compatible_intermediates_with_a_new_save_key(self):
        for kind in ['swift', 'release']:
            with self.subTest(kind=kind):
                before = self.identity(kind)
                self.write('LPMVault/Vendor/EnvEngine/provenance.json', 'new revision')
                after = self.identity(kind)
                self.write('LPMVault/Vendor/EnvEngine/provenance.json', 'initial')
                self.assertEqual(before[0], after[0])
                self.assertNotEqual(before[1], after[1])

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

    def test_a_changed_engine_keeps_a_timestamp_that_invalidates_the_build(self):
        engine = 'LPMVault/Vendor/EnvEngine/LPMEnv.xcframework'
        for kind in ['swift', 'release']:
            for relative in [engine + '/Headers/lpm_env.h', engine + '/macos-arm64_x86_64/libLPMEnv.a']:
                with self.subTest(kind=kind, file=relative):
                    self.write(relative, 'old engine')
                    cache.source_times(kind, self.root, restore=False)
                    path = self.root / relative
                    recorded = path.stat().st_mtime_ns
                    path.write_text('new engine')
                    os.utime(path, ns=(recorded, recorded))
                    cache.source_times(kind, self.root, restore=True)
                    self.assertGreater(path.stat().st_mtime_ns, recorded)

    def engine_fixture(self):
        """A package whose engine is an xcframework, as LPM Vault's, and a way to export another."""
        package = self.root / 'LPMVault'
        self.write('LPMVault/Package.swift', '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EngineFixture", platforms: [.macOS(.v14)], targets: [
    .binaryTarget(name: "LPMEnv", path: "Vendor/EnvEngine/LPMEnv.xcframework"),
    .executableTarget(name: "EngineFixture", dependencies: ["LPMEnv"], path: "Sources"),
])
''')
        self.write('LPMVault/Package.resolved', '{"pins":[],"version":2}')
        # Xcode 26 builds an executable's top-level code only from main.swift.
        (package / 'Sources/View.swift').unlink()
        (package / 'Sources/main.swift').write_text('import LPMEnv\nprint(lpm_env_fixture_value())\n')

        def export(value):
            work = Path(tempfile.mkdtemp(dir=self.root))
            headers = work / 'Headers'
            headers.mkdir()
            (headers / 'lpm_env.h').write_text(f'int lpm_env_fixture_value(void); // engine {value}\n')
            (headers / 'module.modulemap').write_text('module LPMEnv {\n  header "lpm_env.h"\n  export *\n}\n')
            (work / 'value.c').write_text(f'int lpm_env_fixture_value(void) {{ return {value}; }}\n')
            for command in [['xcrun', 'clang', '-mmacosx-version-min=14.0', '-c', str(work / 'value.c'), '-o', str(work / 'value.o')],
                            ['xcrun', 'libtool', '-static', '-o', str(work / 'libLPMEnv.a'), str(work / 'value.o')],
                            ['xcodebuild', '-create-xcframework', '-library', str(work / 'libLPMEnv.a'),
                             '-headers', str(headers), '-output', str(work / 'LPMEnv.xcframework')]]:
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return work / 'LPMEnv.xcframework'

        engine = package / 'Vendor/EnvEngine/LPMEnv.xcframework'
        shutil.copytree(export(1), engine)

        def re_export():
            """Replaces the engine's files with another export's, keeping their recorded times, as a checkout restored from cache has them."""
            replacement = export(2)
            for path in [path for path in engine.rglob('*') if path.is_file()]:
                mtime = path.stat().st_mtime_ns
                shutil.copyfile(replacement / path.relative_to(engine), path)
                os.utime(path, ns=(mtime, mtime))

        return package, re_export

    def run_fixture(self, command, product=None):
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            errors = [line for line in (result.stdout + result.stderr).splitlines() if 'error' in line.lower()]
            self.fail('\n'.join(errors[:40]) or result.stderr[-4000:])
        if product is None:
            return result.stdout.strip().splitlines()[-1]
        run = subprocess.run([str(product)], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout.strip()

    @unittest.skipUnless(shutil.which('swift') and shutil.which('xcodebuild'), 'Swift and Xcode required')
    def test_a_re_exported_engine_is_used_by_swift_after_cache_restoration(self):
        package, re_export = self.engine_fixture()
        command = ['swift', 'run', '--package-path', str(package), '--disable-index-store',
                   '-Xswiftc', '-warnings-as-errors', 'EngineFixture']
        self.assertEqual(self.run_fixture(command), '1')
        cache.source_times('swift', self.root, restore=False)
        re_export()
        cache.source_times('swift', self.root, restore=True)
        self.assertEqual(self.run_fixture(command), '2')

    @unittest.skipUnless(shutil.which('xcodebuild'), 'Xcode required')
    def test_a_re_exported_engine_is_used_by_xcodebuild_after_cache_restoration(self):
        package, re_export = self.engine_fixture()
        derived = self.root / 'build-check'
        command = ['xcodebuild', '-quiet', '-scheme', 'EngineFixture', '-destination', 'platform=macOS',
                   '-derivedDataPath', str(derived), 'COMPILER_INDEX_STORE_ENABLE=NO', 'CODE_SIGNING_ALLOWED=NO', 'build']
        product = derived / 'Build/Products/Debug/EngineFixture'

        def build():
            # xcodebuild builds the package only where no project sits beside it.
            project, aside = package / 'LPMVault.xcodeproj', self.root / 'LPMVault.xcodeproj'
            project.rename(aside)
            try:
                return self.run_fixture(command, product)
            finally:
                aside.rename(project)

        cwd = os.getcwd()
        os.chdir(package)
        self.addCleanup(os.chdir, cwd)
        self.assertEqual(build(), '1')
        cache.source_times('release', self.root, restore=False)
        re_export()
        cache.source_times('release', self.root, restore=True)
        self.assertEqual(build(), '2')

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
    JOBS = ['plan', 'swift', 'engine', 'release']
    MACOS = ['swift', 'engine', 'release']

    def passed(self, engine_needed=True):
        results = {name: {'result': 'success', 'outputs': {}} for name in self.JOBS}
        results['plan']['outputs'] = {'engine': str(engine_needed).lower()}
        return results

    def verified(self):
        """A merge group's results where a pull request's run passed the same tree."""
        skipped = {name: {'result': 'skipped', 'outputs': {}} for name in self.MACOS}
        return {**skipped, 'plan': {'result': 'success', 'outputs': {'engine': 'true', 'verified': 'true', 'run': 'https://example.com/run'}}}

    def test_every_parallel_job_must_succeed(self):
        passed = self.passed()
        self.assertEqual(results.failures(passed), [])
        for job in self.MACOS:
            for result in ['failure', 'cancelled', 'skipped', 'abandoned', None]:
                with self.subTest(job=job, result=result):
                    changed = {**passed, job: {'result': result}}
                    self.assertEqual(results.failures(changed), [job])
            with self.subTest(missing=job):
                self.assertEqual(results.failures({name: value for name, value in passed.items() if name != job}), [job])

    def test_the_engine_rebuild_is_skipped_only_when_the_plan_job_says_so(self):
        skipped = {**self.passed(engine_needed=False), 'engine': {'result': 'skipped'}}
        self.assertEqual(results.failures(skipped), [])
        self.assertEqual(results.failures(self.passed(engine_needed=False)), [])
        for result in ['failure', 'cancelled', None]:
            with self.subTest(engine=result):
                self.assertEqual(results.failures({**skipped, 'engine': {'result': result}}), ['engine'])
        for outputs in [{'engine': 'true'}, {'engine': ''}, {'engine': 'False'}, {}, None]:
            with self.subTest(outputs=outputs):
                changed = {**skipped, 'plan': {'result': 'success', 'outputs': outputs}}
                self.assertEqual(results.failures(changed), ['engine'])

    def test_a_plan_job_that_did_not_succeed_skips_nothing(self):
        skipped = {**self.passed(engine_needed=False), 'engine': {'result': 'skipped'}}
        for result in ['failure', 'cancelled', 'skipped', None]:
            with self.subTest(plan=result):
                changed = {**skipped, 'plan': {'result': result, 'outputs': {'engine': 'false'}}}
                self.assertEqual(results.failures(changed), ['engine', 'plan'])
                changed = {**self.verified(), 'plan': {'result': result, 'outputs': self.verified()['plan']['outputs']}}
                self.assertEqual(results.failures(changed), ['engine', 'plan', 'release', 'swift'])
        self.assertEqual(results.failures({name: value for name, value in skipped.items() if name != 'plan'}), ['engine', 'plan'])

    def test_every_macos_job_is_skipped_only_where_a_pull_request_run_passed_the_tree(self):
        verified = self.verified()
        self.assertEqual(results.failures(verified), [])
        for outputs in [{'verified': 'false'}, {'verified': ''}, {'verified': 'True'}, {'run': 'https://example.com/run'}, {}, None]:
            with self.subTest(outputs=outputs):
                changed = {**verified, 'plan': {'result': 'success', 'outputs': outputs}}
                self.assertEqual(results.failures(changed), ['engine', 'release', 'swift'])
        for job in self.MACOS:
            for result in ['failure', 'cancelled', 'abandoned', None]:
                with self.subTest(job=job, result=result):
                    self.assertEqual(results.failures({**verified, job: {'result': result}}), [job])

    def test_renaming_a_dependency_cannot_silently_bypass_its_gate(self):
        changed = {**self.passed(), 'renamed_release': {'result': 'success'}}
        del changed['release']
        self.assertEqual(results.failures(changed), ['release', 'renamed_release'])

    def test_the_check_waits_for_each_job_it_requires_and_runs_when_they_do_not(self):
        lines = (Path(__file__).resolve().parents[3] / '.github/workflows/ci.yml').read_text().splitlines()
        job = lines[lines.index('  macos:') + 1:]
        needs = next(line for line in job if line.startswith('    needs:'))
        self.assertEqual(set(re.findall(r'\w+', needs.split(':', 1)[1])), results.REQUIRED)
        self.assertEqual(next(line for line in job if line.startswith('    if:')), '    if: always()')


class EngineChangeTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[3]

    def test_a_change_to_the_bundled_engine_needs_the_rebuild(self):
        for path in ['LPMVault/Vendor/EnvEngine/provenance.json', 'LPMVault/Vendor/EnvEngine/THIRD_PARTY_NOTICES.html',
                     'LPMVault/Vendor/EnvEngine/LPMEnv.xcframework/macos-arm64_x86_64/libLPMEnv.a',
                     'LPMVault/Vendor/EnvEngine/fixtures/companion/markers.json']:
            with self.subTest(path=path):
                self.assertIsNotNone(engine.reason(path))

    def test_a_change_to_how_the_rebuild_runs_needs_it(self):
        for path in engine.RUNNER:
            with self.subTest(path=path):
                self.assertIsNotNone(engine.reason(path))

    def test_app_code_tests_and_other_files_do_not(self):
        for path in ['LPMVault/Sources/Services/CompanionEngine.swift', 'LPMVault/Tests/CompanionStorageTests.swift',
                     'LPMVault/Package.swift', 'LPMVault/Vendor/EnvEngine.md', 'LPMVault/Scripts/ci-results.py',
                     '.github/workflows/ui.yml', 'web/nginx.conf']:
            with self.subTest(path=path):
                self.assertIsNone(engine.reason(path))

    def test_runner_files_match_the_repository_and_the_engine_job(self):
        for path in engine.RUNNER:
            with self.subTest(path=path):
                self.assertTrue((self.ROOT / path).is_file())
        self.assertTrue((self.ROOT / engine.ENGINE / 'provenance.json').is_file())
        lines = (self.ROOT / '.github/workflows/ci.yml').read_text().splitlines()
        start = lines.index('  engine:') + 1
        end = next(i for i in range(start, len(lines)) if re.match(r'  \S', lines[i]))
        job = '\n'.join(lines[start:end])
        self.assertIn("    needs: plan\n    if: needs.plan.outputs.verified != 'true' && needs.plan.outputs.engine == 'true'\n", job)
        scripts = set(re.findall(r'LPMVault/Scripts/[\w./-]+\.(?:py|sh)', job))
        self.assertEqual(scripts, {path for path in engine.RUNNER if path.startswith('LPMVault/Scripts/')} - {'LPMVault/Scripts/engine-changes.py'})
        self.assertEqual(set(re.findall(r'LPMVault/Vendor/[\w./-]+', job)), {engine.ENGINE + 'provenance.json'})

    def repository(self):
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
        return root, git, commit

    def test_a_pull_requests_merge_commit_is_compared_with_its_base(self):
        root, git, commit = self.repository()
        commit({'LPMVault/Vendor/EnvEngine/provenance.json': 'one\n', 'LPMVault/Vendor/EnvEngine/fixtures/old.json': 'old\n',
                'LPMVault/Sources/App.swift': 'app\n'}, 'base')
        git('switch', '--quiet', '--create', 'feature')
        commit({'LPMVault/Sources/App.swift': 'changed\n'}, 'app')
        git('switch', '--quiet', 'main')
        commit({'LPMVault/Vendor/EnvEngine/provenance.json': 'two\n'}, 'base re-exports the engine')
        git('merge', '--quiet', '--no-ff', '--no-edit', 'feature')
        self.assertEqual(engine.engine_changes(root, 'HEAD^1', 'HEAD'), [])

        git('switch', '--quiet', 'feature')
        git('mv', 'LPMVault/Vendor/EnvEngine/fixtures/old.json', 'LPMVault/Sources/old.json')
        commit({'LPMVault/Scripts/verify-env-engine.py': 'verify\n'}, 'engine')
        git('switch', '--quiet', 'main')
        git('merge', '--quiet', '--no-ff', '--no-edit', 'feature')
        self.assertEqual([path for path, _ in engine.engine_changes(root, 'HEAD^1', 'HEAD')],
                         ['LPMVault/Scripts/verify-env-engine.py', 'LPMVault/Vendor/EnvEngine/fixtures/old.json'])

    def decision(self, root, event, *commits):
        """What a copy of the script in the repository at `root` decides for a run of `event`."""
        output = root / 'output'
        output.write_text('')
        script = root / 'LPMVault/Scripts/engine-changes.py'
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(__file__).resolve().parents[1] / 'engine-changes.py', script)
        subprocess.run(['python3', str(script), '--event', event, '--github-output', str(output), *commits], check=True, capture_output=True)
        return output.read_text()

    def test_only_a_change_that_has_not_merged_can_skip_the_rebuild(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        for event in ['push', 'schedule', 'workflow_dispatch', 'pull_request_target', '']:
            with self.subTest(event=event):
                self.assertEqual(self.decision(Path(directory.name), event), 'needed=true\n')

    def test_a_merge_group_is_compared_with_the_base_its_run_names(self):
        root, git, commit = self.repository()
        (root / '.gitignore').write_text('output\nLPMVault/Scripts/engine-changes.py\n')
        commit({'LPMVault/Sources/App.swift': 'app\n', 'LPMVault/Vendor/EnvEngine/provenance.json': 'one\n'}, 'base')
        git('tag', 'base')
        commit({'LPMVault/Sources/App.swift': 'first pull request\n'}, 'first')
        git('tag', 'first')
        self.assertEqual(self.decision(root, 'merge_group', 'base'), 'needed=false\n')
        commit({'LPMVault/Vendor/EnvEngine/provenance.json': 'two\n'}, 'second')
        commit({'LPMVault/Sources/App.swift': 'third pull request\n'}, 'third')
        self.assertEqual(self.decision(root, 'merge_group', 'first'), 'needed=true\n')
        self.assertEqual(self.decision(root, 'pull_request'), 'needed=false\n')

    def test_the_plan_job_reports_what_the_script_decides_for_the_runs_event(self):
        workflow = (self.ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('      engine: ${{ steps.engine.outputs.needed }}\n', workflow)
        self.assertIn("          fetch-depth: ${{ github.event_name == 'merge_group' && 0 || 2 }}\n", workflow)
        self.assertIn('          BASE: ${{ github.event.merge_group.base_sha }}\n        run: python3 LPMVault/Scripts/engine-changes.py'
                      ' --event "$GITHUB_EVENT_NAME" --github-output "$GITHUB_OUTPUT" ${BASE:+"$BASE"}\n', workflow)


class Context(dict):
    """A GitHub expression context, in which a property that isn't there is empty."""

    def __getattr__(self, name):
        value = self.get(name, Context())
        return Context(value) if isinstance(value, dict) else value


def expanded(text, github):
    """`text` with each `${{ }}` expression in it evaluated for a run with this `github` context."""
    def evaluate(match):
        source = match.group(1).replace('&&', ' and ').replace('||', ' or ')
        value = eval(source, {'__builtins__': {}}, {'github': Context(github), 'format': lambda text, *values: text.format(*values)})
        return str(value).lower() if isinstance(value, bool) else str(value)

    return re.sub(r'\$\{\{(.*?)\}\}', evaluate, text)


class ConcurrencyTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[3]

    def concurrency(self, workflow, github):
        """A workflow's concurrency group and whether it cancels a run in progress, for a run with this `github` context."""
        lines = (self.ROOT / '.github/workflows' / workflow).read_text().splitlines()
        start = lines.index('concurrency:') + 1
        settings = dict(line.strip().split(': ', 1) for line in lines[start:start + 2])
        return expanded(settings['group'], github), expanded(settings['cancel-in-progress'], github) == 'true'

    def pull_request(self, run, number=7, action='synchronize', label=None):
        event = {'action': action, 'pull_request': {'number': number}}
        if label:
            event['label'] = {'name': label}
        return {'event_name': 'pull_request', 'run_id': run, 'event': event}

    def test_a_pull_requests_newer_run_replaces_its_older_one(self):
        for workflow in ['ci.yml', 'ui.yml']:
            with self.subTest(workflow=workflow):
                older, newer = (self.concurrency(workflow, self.pull_request(run)) for run in [1, 2])
                self.assertEqual(older, newer)
                self.assertTrue(newer[1])
                self.assertNotEqual(newer[0], self.concurrency(workflow, self.pull_request(3, number=8))[0])

    def test_every_other_run_finishes(self):
        for workflow in ['ci.yml', 'ui.yml']:
            for event in ['push', 'schedule', 'workflow_dispatch', 'merge_group']:
                with self.subTest(workflow=workflow, event=event):
                    first, second = (self.concurrency(workflow, {'event_name': event, 'run_id': run, 'event': {}}) for run in [1, 2])
                    self.assertNotEqual(first[0], second[0])
                    self.assertFalse(first[1] or second[1])

    def test_workflows_a_release_calls_from_one_run_do_not_share_a_group(self):
        release = (self.ROOT / '.github/workflows/release.yml').read_text()
        called = re.findall(r'uses: \./\.github/workflows/(\S+)', release)
        self.assertEqual(sorted(called), ['ci.yml', 'ui.yml'])
        github = {'event_name': 'schedule', 'run_id': 5, 'event': {}, 'workflow': 'Signed release'}
        groups = [self.concurrency(workflow, github)[0] for workflow in called + ['release.yml']]
        self.assertEqual(len(set(groups)), len(groups))

    def test_opening_a_labeled_pull_request_runs_the_ui_suite_once(self):
        opened = self.concurrency('ui.yml', self.pull_request(1, action='opened'))
        labeled = self.concurrency('ui.yml', self.pull_request(2, action='labeled', label='ui-tests'))
        self.assertEqual(opened, labeled)
        self.assertTrue(labeled[1])

    def test_another_label_does_not_end_a_ui_run(self):
        running = self.concurrency('ui.yml', self.pull_request(1))[0]
        for run in [2, 3]:
            other = self.concurrency('ui.yml', self.pull_request(run, action='labeled', label='dependencies'))[0]
            self.assertNotEqual(other, running)
        self.assertNotEqual(self.concurrency('ui.yml', self.pull_request(2, action='labeled', label='dependencies'))[0],
                            self.concurrency('ui.yml', self.pull_request(3, action='labeled', label='dependencies'))[0])


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


def job(workflow, name):
    """The lines of the job `name` in a workflow's text."""
    lines = workflow.splitlines()
    start = lines.index(f'  {name}:') + 1
    end = next((i for i in range(start, len(lines)) if re.match(r'  \S', lines[i])), len(lines))
    return lines[start:end]


def events(workflow):
    """The events a workflow's text says start it."""
    lines = workflow.splitlines()
    start = lines.index('on:') + 1
    end = next(i for i in range(start, len(lines)) if not lines[i].startswith(' '))
    return {line.strip().rstrip(':') for line in lines[start:end] if re.fullmatch(r'  \w+:', line)}


class MergeQueueTests(unittest.TestCase):
    WORKFLOWS = Path(__file__).resolve().parents[3] / '.github/workflows'
    BEFORE_MERGE = ['pull_request', 'merge_group']

    def test_the_required_checks_report_for_a_merge_group(self):
        self.assertEqual(events((self.WORKFLOWS / 'ci.yml').read_text()), {'pull_request', 'merge_group', 'workflow_call'})

    def test_a_pull_request_and_its_merge_group_compile_one_architecture_and_a_release_both(self):
        release = job((self.WORKFLOWS / 'ci.yml').read_text(), 'release')
        setting = next(line.split(': ', 1)[1] for line in release if line.startswith('      architectures:'))
        name = next(line.split(': ', 1)[1] for line in release if line.startswith('    name:'))
        for event in self.BEFORE_MERGE:
            with self.subTest(event=event):
                self.assertEqual(expanded(setting, {'event_name': event}), 'arm64')
                self.assertEqual(expanded(name, {'event_name': event}), 'arm64 release bundle verification')
        for event in ['push', 'schedule', 'workflow_dispatch']:
            with self.subTest(event=event):
                self.assertEqual(expanded(setting, {'event_name': event}), 'arm64 x86_64')
                self.assertEqual(expanded(name, {'event_name': event}), 'Universal release bundle verification')
        build = (self.WORKFLOWS / 'release-bundle.yml').read_text()
        self.assertIn('          ARCHITECTURES: ${{ inputs.architectures }}\n', build)
        self.assertEqual(len(re.findall(r'xcodebuild .* ARCHS="\$ARCHITECTURES" .* build\n', build)), 1)

    def test_a_merge_groups_run_restores_caches_and_saves_none(self):
        for workflow in ['ci.yml', 'swift-tests.yml', 'release-bundle.yml']:
            with self.subTest(workflow=workflow):
                lines = (self.WORKFLOWS / workflow).read_text().splitlines()
                uses = [line.strip() for line in lines if 'actions/cache' in line]
                self.assertEqual(sum('actions/cache/restore@' in line for line in uses), 1)
                saves = [index for index, line in enumerate(lines) if 'actions/cache/save@' in line]
                self.assertEqual(len(saves), 1)
                self.assertEqual(len(uses), 2)
                for index in saves:
                    self.assertEqual(lines[index - 1].strip(), "if: github.event_name != 'merge_group' && steps.cache.outputs.cache-hit != 'true'")


class PassedTreeTests(unittest.TestCase):
    WORKFLOWS = Path(__file__).resolve().parents[3] / '.github/workflows'
    TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
    NAME = passed_tree.PREFIX + TREE

    def artifact(self, run=1, **changes):
        source = {'id': run, 'repository_id': 10, 'head_repository_id': 10, **changes.pop('workflow_run', {})}
        return {'name': self.NAME, 'expired': False, 'workflow_run': source, **changes}

    def run_record(self, **changes):
        return {'id': 1, 'path': '.github/workflows/ci.yml', 'event': 'pull_request', 'status': 'completed', 'conclusion': 'success', **changes}

    def found(self, artifacts, records=None):
        """The ID of the run that counts among those `artifacts` name, with `records` by run ID, and the IDs asked about."""
        asked = []

        def run(identifier):
            asked.append(identifier)
            return (records or {}).get(identifier, self.run_record(id=identifier))

        result = passed_tree.passing_run(self.NAME, artifacts, run)
        return result and result['id'], asked

    def test_a_successful_pull_request_run_of_the_ci_workflow_counts(self):
        self.assertEqual(self.found([self.artifact()]), (1, [1]))
        self.assertEqual(self.found([]), (None, []))

    def test_a_run_that_did_not_pass_or_is_not_the_pull_request_checks_does_not(self):
        for changes in [{'conclusion': 'failure'}, {'conclusion': 'cancelled'}, {'conclusion': None, 'status': 'in_progress'},
                        {'status': 'in_progress'}, {'event': 'merge_group'}, {'event': 'pull_request_target'},
                        {'event': 'workflow_dispatch'}, {'path': '.github/workflows/ui.yml'}, {'path': None}]:
            with self.subTest(changes=changes):
                self.assertEqual(self.found([self.artifact()], {1: self.run_record(**changes)}), (None, [1]))

    def test_a_forks_run_is_not_even_asked_about(self):
        for source in [{'head_repository_id': 11}, {'head_repository_id': None}, {'repository_id': None, 'head_repository_id': None},
                       {'repository_id': 0, 'head_repository_id': 0}, {'id': None}]:
            with self.subTest(source=source):
                self.assertEqual(self.found([self.artifact(workflow_run=source)]), (None, []))
        self.assertEqual(self.found([{'name': self.NAME, 'expired': False}]), (None, []))

    def test_an_expired_artifact_or_one_named_for_another_tree_does_not_count(self):
        for changes in [{'expired': True}, {'expired': None}, {'name': passed_tree.PREFIX + 'f' * 40}, {'name': self.TREE}]:
            with self.subTest(changes=changes):
                self.assertEqual(self.found([self.artifact(**changes)]), (None, []))

    def test_a_later_artifact_counts_where_an_earlier_one_does_not(self):
        artifacts = [self.artifact(run=1), self.artifact(run=2, workflow_run={'head_repository_id': 11}), self.artifact(run=3)]
        self.assertEqual(self.found(artifacts, {1: self.run_record(id=1, conclusion='failure')}), (3, [1, 3]))

    def test_a_lookup_that_fails_finds_nothing(self):
        original = passed_tree.api, passed_tree.tree
        self.addCleanup(lambda: (setattr(passed_tree, 'api', original[0]), setattr(passed_tree, 'tree', original[1])))
        passed_tree.tree = lambda root: self.TREE
        asked = []

        def answers(pages):
            def api(endpoint):
                asked.append(endpoint)
                answer = pages[len(asked) - 1]
                if isinstance(answer, Exception):
                    raise answer
                return answer
            return api

        for pages in [[subprocess.CalledProcessError(1, 'gh')], [{}], [{'artifacts': None}], [[]],
                      [{'artifacts': [self.artifact()]}, subprocess.TimeoutExpired('gh', 60)],
                      [{'artifacts': [self.artifact()]}, []]]:
            with self.subTest(pages=pages):
                asked.clear()
                passed_tree.api = answers(pages)
                run, reason = passed_tree.find(Path('.'), 'owner/name')
                self.assertIsNone(run)
                self.assertIn('lookup failed', reason)
        asked.clear()
        passed_tree.api = answers([{'artifacts': [self.artifact(run=7)]}, self.run_record(id=7)])
        self.assertEqual(passed_tree.find(Path('.'), 'owner/name'), (self.run_record(id=7), None))
        self.assertEqual(asked, [f'repos/owner/name/actions/artifacts?name={self.NAME}&per_page=100', 'repos/owner/name/actions/runs/7'])
        asked.clear()
        passed_tree.api = answers([{'artifacts': []}])
        self.assertEqual(passed_tree.find(Path('.'), 'owner/name')[0], None)

    def repository(self):
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
                (root / path).write_text(text)
            git('add', '--all')
            git('commit', '--quiet', '--message', message)

        git('init', '--quiet', '--initial-branch', 'main')
        return root, git, commit

    def test_a_merge_group_has_its_pull_requests_tree_only_while_the_base_has_not_moved(self):
        root, git, commit = self.repository()
        commit({'LPMVault/Sources/App.swift': 'app\n', 'README.md': 'read\n'}, 'base')
        git('switch', '--quiet', '--create', 'feature')
        commit({'LPMVault/Sources/App.swift': 'changed\n'}, 'first')
        commit({'LPMVault/Sources/New.swift': 'new\n'}, 'second')

        def pull_request():
            """The tree of the pull request's merge with main, as its run checks out."""
            git('switch', '--quiet', '--detach', 'main')
            git('merge', '--quiet', '--no-ff', '--no-edit', 'feature')
            return passed_tree.tree(root)

        def merge_group():
            """The tree of the pull request squashed onto main, as the merge queue builds it."""
            git('switch', '--quiet', '--detach', 'main')
            git('merge', '--quiet', '--squash', 'feature')
            git('commit', '--quiet', '--message', 'squashed')
            return passed_tree.tree(root)

        checked = pull_request()
        self.assertEqual(merge_group(), checked)
        git('switch', '--quiet', 'main')
        commit({'README.md': 'another pull request landed\n'}, 'main moves')
        self.assertNotEqual(merge_group(), checked)
        self.assertEqual(merge_group(), pull_request())

    def test_recording_names_the_checked_out_tree(self):
        root, git, commit = self.repository()
        (root / '.gitignore').write_text('output\nmarker\nLPMVault/Scripts/ci-passed-tree.py\n')
        commit({'LPMVault/Sources/App.swift': 'app\n'}, 'base')
        script = root / 'LPMVault/Scripts/ci-passed-tree.py'
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(__file__).resolve().parents[1] / 'ci-passed-tree.py', script)
        (root / 'output').write_text('')
        subprocess.run(['python3', str(script), 'record', '--marker', str(root / 'marker'), '--github-output', str(root / 'output')],
                       check=True, capture_output=True)
        checked = passed_tree.tree(root)
        self.assertRegex(checked, r'\A[0-9a-f]{40}\Z')
        self.assertEqual((root / 'output').read_text(), f'name=ci-passed-tree-{checked}\n')
        self.assertEqual((root / 'marker').read_text(), checked + '\n')

    def test_only_a_merge_group_looks_for_a_run_and_only_a_pull_request_that_passed_records_one(self):
        workflow = (self.WORKFLOWS / 'ci.yml').read_text()
        plan = '\n'.join(job(workflow, 'plan'))
        self.assertIn("        id: passed\n        if: github.event_name == 'merge_group'\n", plan)
        self.assertIn('      verified: ${{ steps.passed.outputs.verified }}\n', plan)
        self.assertEqual(len(re.findall(r'ci-passed-tree\.py find ', workflow)), 1)
        gate = job(workflow, 'macos')
        steps = [line.strip() for line in gate if line.startswith('      - ') or line.startswith('        if:')]
        required = steps.index('- name: Require every macOS verification job')
        self.assertEqual(steps[required + 1:], ['- name: Name the tree these checks passed', "if: github.event_name == 'pull_request'",
                                                '- name: Record that these checks passed this tree', "if: github.event_name == 'pull_request'"])
        self.assertIn('          name: ${{ steps.tree.outputs.name }}\n', '\n'.join(gate) + '\n')

    def test_the_macos_jobs_wait_for_the_plan_and_run_unless_it_found_a_run(self):
        workflow = (self.WORKFLOWS / 'ci.yml').read_text()
        for name in sorted(results.MACOS):
            with self.subTest(job=name):
                lines = job(workflow, name)
                self.assertIn('    needs: plan', lines)
                condition = next(line for line in lines if line.startswith('    if:'))
                self.assertTrue(condition.startswith("    if: needs.plan.outputs.verified != 'true'"), condition)
        web = job(workflow, 'web')
        self.assertFalse([line for line in web if line.startswith('    needs:') or line.startswith('    if:')])

    def test_the_run_that_passed_checked_what_the_merge_group_would(self):
        """Nothing but the lookup, the record and what a merge group's run can't save tells the two events apart."""
        workflow = (self.WORKFLOWS / 'ci.yml').read_text()
        apart = [line.strip() for line in workflow.splitlines() if not line.strip().startswith('#')
                 and re.search(r"event_name [!=]= '(pull_request|merge_group)'", line)
                 and not re.search(r"\(github\.event_name == 'pull_request' \|\| github\.event_name == 'merge_group'\)", line)]
        self.assertEqual(sorted(set(apart)), sorted([
            "group: ci-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number) || github.run_id }}",
            "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            "fetch-depth: ${{ github.event_name == 'merge_group' && 0 || 2 }}",
            "if: github.event_name == 'merge_group'",
            "if: github.event_name != 'merge_group' && steps.cache.outputs.cache-hit != 'true'",
            "if: github.event_name == 'pull_request'",
        ]))
        for called in ['swift-tests.yml', 'release-bundle.yml']:
            with self.subTest(workflow=called):
                lines = [line.strip() for line in (self.WORKFLOWS / called).read_text().splitlines() if 'github.event' in line]
                self.assertEqual(lines, ["if: github.event_name != 'merge_group' && steps.cache.outputs.cache-hit != 'true'"])

    def test_every_workflow_that_calls_the_checks_grants_what_the_plan_job_asks_for(self):
        plan = '\n'.join(job((self.WORKFLOWS / 'ci.yml').read_text(), 'plan'))
        self.assertIn('    permissions:\n      contents: read\n', plan)
        self.assertIn('      actions: read\n', plan)
        callers = [path for path in sorted(self.WORKFLOWS.glob('*.yml')) if 'uses: ./.github/workflows/ci.yml' in path.read_text()]
        self.assertEqual([path.name for path in callers], ['release.yml', 'verify-release.yml'])
        for path in callers:
            with self.subTest(workflow=path.name):
                self.assertIn('    permissions:\n      contents: read\n      actions: read\n    uses: ./.github/workflows/ci.yml\n', path.read_text())


class PostMergeTests(unittest.TestCase):
    WORKFLOWS = Path(__file__).resolve().parents[3] / '.github/workflows'

    def test_only_the_post_merge_checks_follow_a_push_to_main(self):
        started = {path.name for path in self.WORKFLOWS.glob('*.yml')
                   if re.search(r'^  push:\n    branches:', path.read_text(), re.MULTILINE)}
        self.assertEqual(started, {'post-merge.yml'})
        workflow = (self.WORKFLOWS / 'post-merge.yml').read_text()
        self.assertEqual(events(workflow), {'push'})
        self.assertIn('  push:\n    branches: [main]\n', workflow)

    def test_they_run_what_the_merge_queue_left_out_and_each_commit_keeps_its_result(self):
        workflow = (self.WORKFLOWS / 'post-merge.yml').read_text()
        self.assertNotIn('concurrency:', workflow)
        self.assertEqual(re.findall(r'^  (\w+):$', workflow.split('jobs:\n', 1)[1], re.MULTILINE), ['ui', 'release'])
        ui, release = '\n'.join(job(workflow, 'ui')), '\n'.join(job(workflow, 'release'))
        self.assertIn('    uses: ./.github/workflows/swift-tests.yml\n    with:\n      shard: 1/1\n', ui)
        self.assertNotIn('cooperative', ui)
        self.assertIn('    uses: ./.github/workflows/release-bundle.yml\n    with:\n      architectures: arm64 x86_64', release)

    def test_they_save_the_caches_a_pull_request_restores(self):
        for called in ['swift-tests.yml', 'release-bundle.yml']:
            with self.subTest(workflow=called):
                self.assertIn("if: github.event_name != 'merge_group' && steps.cache.outputs.cache-hit != 'true'",
                              (self.WORKFLOWS / called).read_text())


class RunnerRetryTests(unittest.TestCase):
    WORKFLOWS = Path(__file__).resolve().parents[3] / '.github/workflows'

    def job(self, name, conclusion, runner=True):
        """A job's record: one a runner took, or one GitHub gave up on, as its API reports it."""
        if runner:
            return {'name': name, 'conclusion': conclusion, 'runner_id': 1000050429, 'runner_name': 'GitHub Actions 1000050429',
                    'steps': [{'name': 'Set up job', 'conclusion': 'success'}]}
        return {'name': name, 'conclusion': conclusion, 'runner_id': 0, 'runner_name': '', 'steps': []}

    def test_a_run_whose_only_failures_had_no_runner_is_run_again(self):
        jobs = [self.job('Plan', 'success'), self.job('Swift tests / Run', 'success'),
                self.job('Bundled env engine reproduction', 'cancelled', runner=False),
                self.job('Universal release bundle verification / Build', 'cancelled', runner=False),
                self.job('macOS tests and release bundle', 'failure'), self.job('Public update routes', 'success')]
        self.assertEqual(retry.decision(jobs), (['Bundled env engine reproduction', 'Universal release bundle verification / Build'], []))
        self.assertEqual(retry.decision([self.job('UI regressions / Run', 'failure', runner=False)]), (['UI regressions / Run'], []))

    def test_a_job_that_ran_and_failed_keeps_the_run_as_it_is(self):
        for conclusion in ['failure', 'cancelled', 'timed_out', None]:
            with self.subTest(conclusion=conclusion):
                jobs = [self.job('Swift tests / Run', conclusion), self.job('UI regressions / Run', 'cancelled', runner=False),
                        self.job('macOS tests and release bundle', 'failure')]
                self.assertEqual(retry.decision(jobs), (['UI regressions / Run'], ['Swift tests / Run']))

    def test_a_run_whose_jobs_all_had_runners_has_none_to_run_again(self):
        jobs = [self.job('Swift tests / Run', 'failure'), self.job('Engine', 'skipped', runner=False),
                self.job('macOS tests and release bundle', 'failure')]
        self.assertEqual(retry.decision(jobs), ([], ['Swift tests / Run']))
        for field, value in [('runner_id', 7), ('runner_name', 'GitHub Actions 7'), ('steps', [{'name': 'Set up job'}])]:
            with self.subTest(field=field):
                taken = {**self.job('UI regressions / Run', 'cancelled', runner=False), field: value}
                self.assertEqual(retry.decision([taken]), ([], ['UI regressions / Run']))

    def run_script(self, jobs, attempt, dry_run=False):
        """What the script prints and whether it asks for a rerun, for an attempt with these `jobs`."""
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'calls'
            gh = Path(folder) / 'gh'
            gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GH_CALLS"\ncase "$*" in *jobs*) cat "$GH_JOBS";; esac\n')
            gh.chmod(0o755)
            (Path(folder) / 'jobs').write_text(json.dumps([{'jobs': jobs[:1]}, {'jobs': jobs[1:]}]))
            result = subprocess.run(
                ['python3', str(Path(__file__).resolve().parents[1] / 'ci-runner-retry.py'), '--repository', 'owner/name',
                 '--run', '42', '--attempt', str(attempt), *(['--dry-run'] if dry_run else [])],
                env={**os.environ, 'PATH': f'{folder}:{os.environ["PATH"]}', 'GH_CALLS': str(log), 'GH_JOBS': str(Path(folder) / 'jobs')},
                capture_output=True, text=True, check=True)
            calls = log.read_text().splitlines()
        self.assertEqual(calls[0], f'api --paginate --slurp repos/owner/name/actions/runs/42/attempts/{attempt}/jobs?per_page=100')
        self.assertIn(calls[1:], [[], ['api --method POST repos/owner/name/actions/runs/42/rerun-failed-jobs']])
        return result.stdout, len(calls) == 2

    def test_it_runs_the_jobs_again_until_the_last_attempt(self):
        unrun = [self.job('Swift tests / Run', 'success'), self.job('UI regressions / Run', 'cancelled', runner=False)]
        self.assertEqual(retry.LAST_ATTEMPT, 3)
        for attempt in [1, 2]:
            with self.subTest(attempt=attempt):
                output, rerun = self.run_script(unrun, attempt)
                self.assertTrue(rerun, output)
                self.assertIn(f'attempt {attempt + 1} of 3', output)
        for attempt in [3, 4]:
            with self.subTest(attempt=attempt):
                self.assertFalse(self.run_script(unrun, attempt)[1])
        self.assertFalse(self.run_script(unrun, 1, dry_run=True)[1])
        failed = [self.job('Swift tests / Run', 'failure'), self.job('UI regressions / Run', 'cancelled', runner=False)]
        self.assertFalse(self.run_script(failed, 1)[1])
        self.assertFalse(self.run_script([self.job('Swift tests / Run', 'failure'), self.job('Plan', 'success')], 1)[1])

    def test_it_answers_the_workflows_whose_jobs_wait_for_macos_runners(self):
        workflow = (self.WORKFLOWS / 'runner-retry.yml').read_text()
        watched = re.search(r'^    workflows: \[(.*)\]$', workflow, re.MULTILINE).group(1).split(', ')
        names = {path.name: re.search(r'^name: (.*)$', path.read_text(), re.MULTILINE).group(1) for path in self.WORKFLOWS.glob('*.yml')}
        self.assertEqual(sorted(watched), sorted(names[file] for file in ['ci.yml', 'ui.yml', 'post-merge.yml']))
        self.assertIn("    if: github.event.workflow_run.conclusion == 'failure' && github.event.workflow_run.event != 'merge_group'\n", workflow)
        self.assertNotIn('workflow_run.head', workflow)
        self.assertNotIn('ref:', workflow)

    def test_the_job_that_reports_the_others_is_the_required_check(self):
        gate = job((self.WORKFLOWS / 'ci.yml').read_text(), 'macos')
        self.assertEqual({next(line.split(': ', 1)[1] for line in gate if line.startswith('    name:'))}, retry.REPORTS)


class WebCheckTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[3]

    def test_web_checks_install_the_browser_without_waiting_on_system_packages(self):
        installs = [line.strip() for workflow in sorted((self.ROOT / '.github/workflows').glob('*.yml'))
                    for line in workflow.read_text().splitlines() if 'playwright install' in line]
        self.assertEqual(installs, ['- run: npx --prefix web playwright install chromium'])


class EngineToolchainTests(unittest.TestCase):
    def step_script(self, name):
        lines = (WebCheckTests.ROOT / '.github/workflows/ci.yml').read_text().splitlines()
        start = lines.index(f'      - name: {name}') + 1
        run = next(line for line in lines[start:] if line.startswith('        run:'))
        if run.strip() != 'run: |':
            return run.split(':', 1)[1].strip()
        body = []
        for line in lines[lines.index(run, start) + 1:]:
            if line.strip() and not line.startswith(' ' * 10):
                break
            body.append(line[10:])
        return '\n'.join(body)

    def test_the_engine_job_installs_the_toolchain_and_targets_the_bundled_engine_was_built_with(self):
        provenance = json.loads((WebCheckTests.ROOT / 'LPMVault/Vendor/EnvEngine/provenance.json').read_text())
        with tempfile.TemporaryDirectory() as folder:
            rustup = Path(folder) / 'rustup'
            rustup.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            rustup.chmod(0o755)
            installed = subprocess.run(
                ['bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', self.step_script('Install pinned env engine toolchain')],
                cwd=WebCheckTests.ROOT, env={**os.environ, 'PATH': f'{folder}:{os.environ["PATH"]}'},
                capture_output=True, text=True, check=True).stdout.split()
        self.assertEqual(installed, ['toolchain', 'install', provenance['toolchain'], '--profile', 'minimal',
                                     '--component', 'llvm-tools-preview', '--target', ','.join(provenance['targets'])])


class ReleaseBundleCheckTests(unittest.TestCase):
    def time_limit(self, workflow, job):
        lines = (WebCheckTests.ROOT / '.github/workflows' / workflow).read_text().splitlines()
        start = lines.index(f'  {job}:') + 1
        end = next((i for i in range(start, len(lines)) if re.match(r'  \S', lines[i])), len(lines))
        return int(next(line.split(':', 1)[1] for line in lines[start:end] if line.startswith('    timeout-minutes:')))

    def test_the_universal_check_waits_as_long_as_the_release_build_does(self):
        self.assertGreaterEqual(self.time_limit('release-bundle.yml', 'build'), self.time_limit('release.yml', 'release'))


class SigningWorkflowTests(unittest.TestCase):
    WORKFLOWS = Path(__file__).resolve().parents[3] / '.github/workflows'
    SIGNERS = {'release.yml': 'release', 'verify-release.yml': 'verify'}

    def test_only_the_release_environment_holds_the_signing_secrets(self):
        holders = {}
        for path in sorted(self.WORKFLOWS.glob('*.yml')):
            workflow = path.read_text()
            for name in re.findall(r'^  ([\w-]+):$', workflow.split('\njobs:\n', 1)[-1], re.MULTILINE):
                lines = job(workflow, name)
                if any(re.search(r'secrets\.(?!GITHUB_TOKEN\b)', line) for line in lines):
                    holders[(path.name, name)] = next(
                        (line.split(':', 1)[1].strip() for line in lines if line.startswith('    environment:')), None)
        self.assertEqual(holders, {(path, name): 'release' for path, name in self.SIGNERS.items()})

    def test_signing_workflows_start_only_from_main_by_schedule_or_by_hand(self):
        self.assertEqual(events((self.WORKFLOWS / 'release.yml').read_text()), {'schedule', 'workflow_dispatch'})
        self.assertEqual(events((self.WORKFLOWS / 'verify-release.yml').read_text()), {'workflow_dispatch'})
        for path in self.SIGNERS:
            with self.subTest(workflow=path):
                self.assertNotIn('tags:', (self.WORKFLOWS / path).read_text())

    def test_a_stable_release_names_its_version_and_a_scheduled_run_is_a_nightly(self):
        workflow = (self.WORKFLOWS / 'release.yml').read_text()
        self.assertIn('    inputs:\n      version:\n', workflow)
        release = '\n'.join(job(workflow, 'release'))
        self.assertIn('          RELEASE_VERSION: ${{ inputs.version }}\n', release)
        self.assertIn('if [[ -n "$RELEASE_VERSION" ]]; then\n'
                      '            python3 LPMVault/Scripts/ci-release.py --channel stable --version "$RELEASE_VERSION"\n'
                      '          else\n'
                      '            python3 LPMVault/Scripts/ci-release.py --channel nightly\n', release)
        self.assertNotIn('GITHUB_EVENT_NAME', release)


if __name__ == '__main__':
    unittest.main()
