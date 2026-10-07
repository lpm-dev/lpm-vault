import base64
import copy
import importlib.util
import json
import os
import plistlib
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import release_channels as channels

spec = importlib.util.spec_from_file_location('metadata', SCRIPTS / 'validate-release-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
SHA = 'abcdef0' + 'a' * 33


def manifest(version='1.0.1', build='6', channel='stable', release_version=None, legacy=False):
    release_version = release_version or version
    result = dict(version=version, build=build, minimumSystemVersion='14.0', bundleIdentifier='dev.lpm.vault',
                  teamIdentifier='823S8YKMRW', artifacts=[
                      dict(kind='dmg', file=f'LPM-Vault-{release_version}.dmg', size=123, sha256='a' * 64),
                      dict(kind='update-zip', file=f'LPM-Vault-{release_version}-macos-universal.zip', size=234, sha256='b' * 64)])
    if not legacy:
        result.update(channel=channel, releaseVersion=release_version, sourceCommit=SHA,
                      releaseDate='2026-10-07' if channel == 'nightly' else '')
    return result


def feed(value):
    root = ET.Element('rss')
    item = ET.SubElement(ET.SubElement(root, 'channel'), 'item')
    for key, text in [('version', value['build']), ('shortVersionString', channels.display_version(value)),
                      ('minimumSystemVersion', '14.0')]:
        ET.SubElement(item, channels.SPARKLE + key).text = text
    if value.get('channel') == 'nightly':
        ET.SubElement(item, channels.SPARKLE + 'channel').text = 'nightly'
    artifact = value['artifacts'][0]
    ET.SubElement(item, 'enclosure', url=f"https://vault.lpm.dev/releases/v{value.get('releaseVersion', value['version'])}/{artifact['file']}",
                  length=str(artifact['size']), **{channels.SPARKLE + 'edSignature': base64.b64encode(bytes(64)).decode()})
    return ET.tostring(root)


class ReleaseMetadata(unittest.TestCase):
    def test_build_ordering_is_shared_and_apple_compatible(self):
        for previous, floor, expected in [('6', '6', '6.0.1'), ('6.0.99', '6', '6.1.0'),
                                          ('6.99.99', '6', '7.0.0'), ('6.0.1', '7', '7')]:
            with self.subTest(previous=previous):
                self.assertEqual(channels.next_build(previous, floor), expected)
                self.assertGreater(channels.build_tuple(expected), channels.build_tuple(previous))
        with self.assertRaises(ValueError):
            channels.next_build('9999.99.99', '6')
        for value in ['0', '01', '1.100', '1.2.3.4', '10000', '1-beta', None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                channels.build_tuple(value)

    def test_nightly_version_is_deterministic_and_uses_next_minor(self):
        self.assertEqual(channels.nightly_version('1.0.1', '2026-10-07', '42', SHA),
                         ('1.1.0', '1.1.0-nightly.20261007.42.abcdef0'))
        version, label = channels.nightly_version('1.0.1', '2026-10-07', '42', '0123456' + 'a' * 33)
        self.assertTrue(label.endswith('.g0123456'))
        metadata.validate(version, '6', 'nightly', label, '2026-10-07', '0123456' + 'a' * 33)
        for args in [('1.0.1', '2026-02-30', '42', SHA), ('1.0.1', '2026-10-07', '0', SHA),
                     ('1.0.1', '2026-10-07', '42', 'main'), ('1.0.1-beta', '2026-10-07', '42', SHA)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                channels.nightly_version(*args)

    def test_metadata_rejects_channel_date_and_commit_mismatches(self):
        self.assertEqual(metadata.validate('14.0', '6', 'stable', '14.0', '', '')['LPMReleaseVersion'], '14.0')
        valid = ['1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.42.abcdef0', '2026-10-07', SHA]
        self.assertEqual(metadata.validate(*valid)['LPMReleaseChannel'], 'nightly')
        for index, value in [(0, '1.2.0'), (1, '0'), (2, 'beta'), (3, '1.1.0'), (4, '2026-10-08'), (5, 'b' * 40)]:
            broken = valid.copy()
            broken[index] = value
            with self.subTest(index=index), self.assertRaises(ValueError):
                metadata.validate(*broken)

    def test_previous_stable_manifests_remain_compatible(self):
        old = manifest(legacy=True)
        self.assertEqual(channels.validate_manifest(old, 'v1.0.1', False), 'stable')
        channels.verify_item(ET.fromstring(feed(old)).find('./channel/item'), old)

    def test_manifest_rejects_untrusted_download_and_identity_metadata(self):
        valid = manifest()
        for field, value in [('bundleIdentifier', 'evil.app'), ('teamIdentifier', 'OTHER'),
                             ('minimumSystemVersion', '1.0'), ('build', '0'), ('releaseVersion', 'other')]:
            broken = copy.deepcopy(valid)
            broken[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                channels.validate_manifest(broken, 'v1.0.1', False)
        for field, value in [('file', '../evil.dmg'), ('size', True), ('sha256', 'x')]:
            broken = copy.deepcopy(valid)
            broken['artifacts'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                channels.validate_manifest(broken, 'v1.0.1', False)
        with self.assertRaises(ValueError):
            channels.validate_manifest(valid, 'v1.0.1', True)

    def test_aggregate_feed_keeps_stable_untagged_and_orders_by_build(self):
        stable = manifest()
        nightly = manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.42.abcdef0')
        root = ET.fromstring(channels.aggregate_feed([(stable, feed(stable)), (nightly, feed(nightly))]))
        items = root.findall('./channel/item')
        self.assertEqual([item.findtext(channels.SPARKLE + 'version') for item in items], ['6.0.1', '6'])
        self.assertEqual([item.findtext(channels.SPARKLE + 'channel') for item in items], ['nightly', None])
        stable['build'] = '6.0.2'
        root = ET.fromstring(channels.aggregate_feed([(stable, feed(stable)), (nightly, feed(nightly))]))
        self.assertIsNone(root.find('./channel/item').find(channels.SPARKLE + 'channel'))

    def test_feed_rejects_missing_nightly_tag_colliding_builds_and_modified_artifacts(self):
        nightly = manifest('1.1.0', '6', 'nightly', '1.1.0-nightly.20261007.42.abcdef0')
        root = ET.fromstring(feed(nightly))
        item = root.find('./channel/item')
        item.remove(item.find(channels.SPARKLE + 'channel'))
        with self.assertRaisesRegex(ValueError, 'tagged'):
            channels.aggregate_feed([(nightly, ET.tostring(root))])
        with self.assertRaisesRegex(ValueError, 'collide'):
            stable = manifest()
            channels.aggregate_feed([(nightly, feed(nightly)), (stable, feed(stable))])
        for attribute, value in [('url', 'https://evil.test/a.dmg'), ('length', '124'), (channels.SPARKLE + 'edSignature', '')]:
            root = ET.fromstring(feed(nightly))
            root.find('./channel/item/enclosure').set(attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(ValueError):
                channels.aggregate_feed([(nightly, ET.tostring(root))])

    def test_decoration_changes_display_metadata_without_changing_numeric_build(self):
        value = manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.42.abcdef0')
        root = ET.fromstring(feed(value))
        item = root.find('./channel/item')
        item.remove(item.find(channels.SPARKLE + 'channel'))
        item.find(channels.SPARKLE + 'shortVersionString').text = '1.1.0'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_bytes(ET.tostring(root))
            channels.decorate_feed(path, value)
            channels.verify_item(ET.parse(path).find('./channel/item'), value)


class Publication(unittest.TestCase):
    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory()
        self.original = Path.cwd()
        os.chdir(self.fixture.name)
        self.addCleanup(os.chdir, self.original)
        self.addCleanup(self.fixture.cleanup)
        self.environment = dict(RUNNER_TEMP=self.fixture.name, GITHUB_REF='refs/heads/main',
                                GITHUB_RUN_ID='100', GITHUB_RUN_NUMBER='42', SPARKLE_PRIVATE_KEY='test-key')
        self.project = 'MARKETING_VERSION = 1.0.1; CURRENT_PROJECT_VERSION = 6;'
        self.records = []
        self.manifests = {}
        self.commands = []
        self.signed = []
        self.status = 'ahead'
        self.comparisons = {}
        self.published = None

    def previous(self, value, tag=None):
        tag = tag or 'v' + value.get('releaseVersion', value['version'])
        record = dict(tag_name=tag, prerelease=value.get('channel') == 'nightly', draft=False,
                      immutable=True, published_at='2026-10-06T00:00:00Z')
        self.records.append(record)
        self.manifests[tag] = value
        return record

    def command(self, *arguments, **kwargs):
        self.commands.append(arguments)
        if arguments[:3] == ('gh', 'release', 'download'):
            directory = Path(arguments[arguments.index('--dir') + 1])
            value = self.manifests[arguments[3]]
            (directory / 'release-manifest.json').write_text(json.dumps(value))
            (directory / 'appcast.xml').write_bytes(feed(value))

    def output(self, *arguments, **kwargs):
        if arguments == ('git', 'rev-parse', 'HEAD'):
            return SHA
        endpoint = next((argument for argument in arguments if argument.startswith('repos/')), '')
        if '/releases?' in endpoint:
            self.assertIn('--paginate', arguments)
            self.assertIn('--slurp', arguments)
            return json.dumps([self.records[:1], self.records[1:]])
        if '/actions/runs/' in endpoint:
            return '{"created_at":"2026-10-07T03:37:00Z"}'
        if '/compare/' in endpoint:
            previous = endpoint.split('/compare/')[1].split('...')[0]
            return json.dumps(dict(status=self.comparisons.get(previous, self.status)))
        if '/releases/tags/' in endpoint:
            return json.dumps(self.published or dict(tag_name=endpoint.split('/tags/')[1], draft=False,
                                                    immutable=True, prerelease=True))
        raise AssertionError(arguments)

    def sign(self, version, build, metadata):
        self.signed.append((version, build, metadata))
        value = manifest(version, build, metadata['channel'], metadata['releaseVersion'])
        value.update(metadata)
        directory = Path('release-output')
        directory.mkdir(exist_ok=True)
        (directory / 'release-manifest.json').write_text(json.dumps(value))
        (directory / 'appcast.xml').write_bytes(feed(value))

    def publish(self, channel='nightly', tag='main'):
        with mock.patch.object(channels, 'publish_feed') as publish_feed:
            channels.publish('example/vault', channel, tag, self.project, self.command, self.output, self.sign, self.environment)
        return publish_feed

    def test_first_nightly_is_prerelease_and_never_latest(self):
        self.previous(manifest(legacy=True))
        publication = self.publish()
        self.assertEqual(self.signed[0][:2], ('1.1.0', '6.0.1'))
        edit = next(command for command in self.commands if command[:3] == ('gh', 'release', 'edit'))
        self.assertIn('--prerelease', edit)
        self.assertIn('--latest=false', edit)
        self.assertEqual(len(publication.call_args.args[1]), 2)

    def test_same_commit_skips_build_but_repairs_feed(self):
        self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.41.abcdef0'))
        self.status = 'identical'
        publication = self.publish()
        self.assertEqual(self.signed, [])
        self.assertFalse(any(command[:3] == ('gh', 'release', 'create') for command in self.commands))
        publication.assert_called_once()

    def test_diverged_or_behind_sources_do_not_sign_or_publish(self):
        self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.41.abcdef0'))
        for status in ['behind', 'diverged']:
            self.status = status
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'ancestor'):
                self.publish()
        self.assertEqual(self.signed, [])

    def test_failed_immutable_confirmation_never_publishes_feed(self):
        self.published = dict(tag_name='v1.1.0-nightly.20261007.42.abcdef0', draft=False, prerelease=True, immutable=False)
        with mock.patch.object(channels, 'publish_feed') as publication, self.assertRaisesRegex(RuntimeError, 'immutable'):
            channels.publish('example/vault', 'nightly', 'main', self.project, self.command, self.output, self.sign, self.environment)
        publication.assert_not_called()

    def test_stable_after_nightly_receives_a_higher_shared_build(self):
        self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.41.abcdef0'))
        self.project = 'MARKETING_VERSION = 1.0.2; CURRENT_PROJECT_VERSION = 6;'
        self.published = dict(tag_name='v1.0.2', draft=False, prerelease=False, immutable=True)
        self.publish('stable', 'v1.0.2')
        self.assertEqual(self.signed[0][:2], ('1.0.2', '6.0.2'))
        edit = next(command for command in self.commands if command[:3] == ('gh', 'release', 'edit'))
        self.assertIn('--latest', edit)
        self.assertNotIn('--prerelease', edit)

    def test_stable_publication_cannot_roll_nightly_users_back_to_an_older_source(self):
        self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.41.abcdef0'))
        self.project = 'MARKETING_VERSION = 1.0.2; CURRENT_PROJECT_VERSION = 6;'
        self.status = 'behind'
        self.published = dict(tag_name='v1.0.2', draft=False, prerelease=False, immutable=True)
        with self.assertRaisesRegex(ValueError, 'ancestor'):
            self.publish('stable', 'v1.0.2')
        self.assertEqual(self.signed, [])

    def test_queued_nightly_cannot_replace_a_newer_stable_source(self):
        for prior_nightly in (False, True):
            for status in ('behind', 'diverged'):
                with self.subTest(prior_nightly=prior_nightly, status=status):
                    self.records.clear()
                    self.commands.clear()
                    self.signed.clear()
                    if prior_nightly:
                        self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.41.abcdef0'))
                    self.previous(manifest('1.0.2', '6.0.2', legacy=True))
                    self.comparisons['v1.0.2'] = status
                    with mock.patch.object(channels, 'publish_feed') as publication:
                        with self.assertRaisesRegex(ValueError, 'ancestor'):
                            channels.publish('example/vault', 'nightly', 'main', self.project,
                                             self.command, self.output, self.sign, self.environment)
                        publication.assert_not_called()
                    self.assertEqual(self.signed, [])
                    self.assertFalse(any(command[:3] == ('gh', 'release', 'create') for command in self.commands))

    def test_older_nightly_feed_recovery_remains_possible_after_a_newer_stable(self):
        self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.41.abcdef0'))
        self.previous(manifest('1.0.2', '6.0.2', legacy=True))
        self.status = 'identical'
        self.comparisons['v1.0.2'] = 'behind'
        publication = self.publish()
        self.assertEqual(self.signed, [])
        self.assertFalse(any(command[:3] == ('gh', 'release', 'create') for command in self.commands))
        publication.assert_called_once()

    def test_non_main_nightly_draft_and_inconsistent_previous_release_fail_closed(self):
        self.environment['GITHUB_REF'] = 'refs/heads/topic'
        with self.assertRaisesRegex(ValueError, 'main'):
            self.publish()
        self.environment['GITHUB_REF'] = 'refs/heads/main'
        record = self.previous(manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.42.abcdef0'))
        record['draft'] = True
        with self.assertRaisesRegex(ValueError, 'draft'):
            self.publish()
        record['draft'], record['immutable'] = False, False
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.publish()
        self.assertEqual(self.signed, [])


class FeedPublication(unittest.TestCase):
    def test_nightly_dmg_generates_a_signed_release_appcast_with_the_channel_feed_url(self):
        tools = Path(os.environ.get('SPARKLE_TEST_TOOLS', str(SCRIPTS.parent / '.build/artifacts/sparkle/Sparkle'))).resolve()
        seed = os.urandom(32)
        derive = subprocess.run(['swift', '-e', 'import Foundation; import CryptoKit; let seed = FileHandle.standardInput.readDataToEndOfFile(); print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())'],
                                input=seed, capture_output=True, check=True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / 'stage'
            contents = stage / 'LPM Vault.app/Contents'
            contents.mkdir(parents=True)
            info = dict(CFBundleIdentifier='dev.lpm.vault', CFBundleName='LPM Vault', CFBundlePackageType='APPL',
                        CFBundleVersion='6.0.1', CFBundleShortVersionString='1.1.0', LSMinimumSystemVersion='14.0',
                        SUFeedURL='https://vault.lpm.dev/updates/channels.xml', SURequireSignedFeed=True,
                        SUPublicEDKey=derive.stdout.decode().strip())
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
            release = root / 'release'
            release.mkdir()
            value = manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.42.abcdef0')
            artifact = release / value['artifacts'][0]['file']
            subprocess.run(['hdiutil', 'create', '-quiet', '-srcfolder', str(stage), '-volname', 'Vault test', str(artifact)], check=True)
            value['artifacts'][0]['size'] = artifact.stat().st_size
            (release / 'release-manifest.json').write_text(json.dumps(value))
            environment = dict(os.environ, SPARKLE_PRIVATE_KEY=base64.b64encode(seed).decode())
            result = subprocess.run(['bash', str(SCRIPTS / 'generate-appcast.sh'), str(release), str(tools)],
                                    env=environment, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            channels.verify_item(ET.parse(release / 'appcast.xml').find('./channel/item'), value)

    def test_existing_pointer_uses_a_forward_commit_and_repeated_feed_is_a_no_op(self):
        value = manifest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = []
            def run(*args, **kwargs):
                commands.append(args)
            def output(*args, **kwargs):
                endpoint = next(arg for arg in args if arg.startswith('repos/'))
                if '/contents/' in endpoint:
                    return json.dumps(dict(content=base64.b64encode(b'old feed').decode()))
                return json.dumps(dict(sha='b' * 40))
            with mock.patch.object(channels, 'api_optional', return_value=dict(object=dict(sha='a' * 40))):
                channels.publish_feed('example/vault', [(value, feed(value))], root, root, run, output, {'SPARKLE_PRIVATE_KEY': 'test-key'})
            self.assertIn('force=false', commands[-1])
            self.assertEqual(json.loads((root / 'feed-commit.json').read_text())['parents'], ['a' * 40])
            commands.clear()
            with mock.patch.object(channels, 'api_optional', return_value=dict(object=dict(sha='b' * 40))), \
                 mock.patch.object(channels, 'aggregate_feed', return_value=b'old feed'):
                channels.publish_feed('example/vault', [(value, feed(value))], root, root, run, output, {'SPARKLE_PRIVATE_KEY': 'test-key'})
            self.assertEqual(len(commands), 2)

    def test_sparkle_verifies_the_composed_feed_and_rejects_tampering(self):
        tools = Path(os.environ.get('SPARKLE_TEST_TOOLS', str(SCRIPTS.parent / '.build/artifacts/sparkle/Sparkle')))
        signer = tools / 'bin/sign_update'
        self.assertTrue(signer.is_file(), 'Fetch the pinned Sparkle tools and set SPARKLE_TEST_TOOLS')
        seed = base64.b64encode(os.urandom(32))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stable = manifest()
            nightly = manifest('1.1.0', '6.0.1', 'nightly', '1.1.0-nightly.20261007.42.abcdef0')
            path = root / 'channels.xml'
            path.write_bytes(channels.aggregate_feed([(stable, feed(stable)), (nightly, feed(nightly))]))
            def invoke(verify=False):
                return subprocess.run([str(signer), '--ed-key-file', '-', *(['--verify'] if verify else []), str(path)],
                                      input=seed, capture_output=True, check=False)
            self.assertEqual(invoke().returncode, 0)
            signed = path.read_bytes()
            self.assertEqual(invoke(True).returncode, 0)
            self.assertEqual(invoke().returncode, 0)
            self.assertEqual(path.read_bytes(), signed)
            self.assertEqual(len(ET.parse(path).findall('./channel/item')), 2)
            path.write_bytes(signed.replace(b'6.0.1', b'6.0.2'))
            self.assertNotEqual(invoke(True).returncode, 0)

    def test_pointer_updates_only_after_signing_and_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = []
            def run(*args, **kwargs):
                commands.append(args)
            def output(*args, **kwargs):
                endpoint = next(arg for arg in args if arg.startswith('repos/'))
                self.assertEqual(len(commands), 2)
                return json.dumps(dict(sha='a' * 40))
            with mock.patch.object(channels, 'api_optional', return_value=None):
                value = manifest()
                channels.publish_feed('example/vault', [(value, feed(value))], root, root, run, output, {'SPARKLE_PRIVATE_KEY': 'test-key'})
            self.assertIn('--verify', commands[1])
            self.assertIn('ref=refs/heads/updates', commands[-1])
            self.assertNotIn('ref=refs/heads/main', commands[-1])
            self.assertEqual(json.loads((root / 'feed-commit.json').read_text())['parents'], [])

    def test_missing_branch_is_distinguished_from_permission_failure(self):
        for code, stderr, body, missing in [(1, 'HTTP 404', '{"message":"Not Found"}', True),
                                            (1, 'HTTP 403', '{"message":"Forbidden"}', False),
                                            (1, 'network failure', '', False)]:
            result = mock.Mock(returncode=code, stdout=body, stderr=stderr)
            with self.subTest(stderr=stderr), mock.patch.object(channels.subprocess, 'run', return_value=result):
                if missing:
                    self.assertIsNone(channels.api_optional('example', {}))
                else:
                    with self.assertRaises(RuntimeError):
                        channels.api_optional('example', {})


if __name__ == '__main__':
    unittest.main()
