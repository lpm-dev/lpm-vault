import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))


def module(filename):
    spec = importlib.util.spec_from_file_location(filename, SCRIPTS / (filename + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


config = module('verify-update-config')
appcast = module('verify-appcast')
release = module('ci-release')


class ReleaseSecurity(unittest.TestCase):
    def test_release_configuration_fails_closed(self):
        valid = dict(SUFeedURL=config.FEED_URL, SUPublicEDKey=config.PUBLIC_KEY,
                     SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                     SUAutomaticallyUpdate=False, SUSendProfileInfo=False)
        config.verify(valid)
        for key in valid:
            missing = valid.copy()
            missing.pop(key)
            with self.subTest(key=key), self.assertRaises(ValueError):
                config.verify(missing)
        for value in ['YES', 1, False]:
            with self.assertRaises(ValueError):
                config.verify(dict(valid, SURequireSignedFeed=value))

    def test_feed_requires_matching_signed_artifact(self):
        manifest = dict(version='1.2.3', build='42', minimumSystemVersion='14.0')
        root = ET.fromstring(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>42</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure url="https://vault.lpm.dev/releases/v1.2.3/LPM-Vault-1.2.3.dmg" length="123"
        sparkle:edSignature="{base64.b64encode(bytes(64)).decode()}" /></item></channel></rss>''')
        appcast.verify(root, manifest, 123)
        for attribute, value in [('url', 'http://evil.test/app.dmg'), ('length', '122'), (appcast.SPARKLE + 'edSignature', '')]:
            broken = copy.deepcopy(root)
            broken.find('./channel/item/enclosure').set(attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(ValueError):
                appcast.verify(broken, manifest, 123)
        root.find('./channel').append(copy.deepcopy(root.find('./channel/item')))
        with self.assertRaises(ValueError):
            appcast.verify(root, manifest, 123)

    def test_release_tag_validation(self):
        self.assertEqual(release.release_version('v1.2.3'), '1.2.3')
        for tag in ['main', 'v1', 'v1.2.3-beta', 'v01.2.3', 'v1.2.3;echo secret']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.release_version(tag)

    def test_signing_requires_every_sparkle_component(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', str(SCRIPTS / 'sign-sparkle.sh'), directory, '-', '--timestamp=none'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Missing Sparkle component', result.stderr)

    def test_signing_only_verification_preserves_private_bootstrap(self):
        with mock.patch.object(release, 'sign_release') as sign, \
             mock.patch.object(release, 'run') as command, \
             mock.patch.object(release, 'output') as output:
            release.main(['--verify-only', '--signing-only', '--version', '1.0.0', '--build', '3'])
        sign.assert_called_once_with('1.0.0', '3')
        command.assert_not_called()
        output.assert_not_called()

    def repository_response(self, *arguments, **kwargs):
        endpoint = arguments[-1]
        if endpoint == 'repos/example/vault':
            return '{"private": false}'
        if endpoint.endswith('/immutable-releases'):
            environment = kwargs.get('env', os.environ)
            if environment.get('GH_TOKEN') != 'settings-read-token':
                raise subprocess.CalledProcessError(1, arguments, stderr='HTTP 403')
            self.assertNotIn('IMMUTABLE_RELEASES_READ_TOKEN', environment)
            return '{"enabled": true}'
        if endpoint.endswith('/releases?per_page=100'):
            return '[]'
        if '/releases/tags/' in endpoint:
            return json.dumps({'tag_name': 'v1.0.2', 'draft': False, 'immutable': True})
        self.fail('Unexpected release API endpoint: ' + endpoint)

    def test_production_uses_read_credential_for_settings(self):
        environment = dict(GITHUB_REF_NAME='v1.0.2', GITHUB_REPOSITORY='example/vault',
                           GH_TOKEN='publisher-token', IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token')
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release, 'run') as command, \
             mock.patch.object(release, 'output', side_effect=self.repository_response), \
             mock.patch.object(release.Path, 'read_text', return_value='CURRENT_PROJECT_VERSION = 7;'), \
             mock.patch.object(release.release_channels, 'publish') as publish:
            release.main([])
            self.assertEqual(os.environ['GH_TOKEN'], 'publisher-token')
        publish.assert_called_once()
        self.assertEqual(publish.call_args.args[:3], ('example/vault', 'stable', 'v1.0.2'))
        self.assertEqual(publish.call_args.args[-1]['GH_TOKEN'], 'publisher-token')
        self.assertNotIn('IMMUTABLE_RELEASES_READ_TOKEN', publish.call_args.args[-1])

    def test_verification_checks_publication_before_signing(self):
        environment = dict(GITHUB_REPOSITORY='example/vault', GH_TOKEN='publisher-token',
                           IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token')
        calls = []
        def respond(*arguments, **kwargs):
            calls.append(arguments[-1])
            return self.repository_response(*arguments, **kwargs)
        def sign(version, build):
            self.assertEqual(calls, ['repos/example/vault', 'repos/example/vault/immutable-releases'])
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release, 'run') as command, \
             mock.patch.object(release, 'output', side_effect=respond), \
             mock.patch.object(release, 'sign_release', side_effect=sign) as signing:
            release.main(['--verify-only', '--version', '1.0.2', '--build', '7'])
        signing.assert_called_once_with('1.0.2', '7')
        command.assert_not_called()

    def test_preflight_checks_without_signing_or_publication(self):
        environment = dict(GITHUB_REPOSITORY='example/vault', GH_TOKEN='publisher-token',
                           IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token')
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release, 'run') as command, \
             mock.patch.object(release, 'output', side_effect=self.repository_response), \
             mock.patch.object(release, 'sign_release') as sign:
            release.main(['--preflight-only'])
        command.assert_not_called()
        sign.assert_not_called()

    def test_missing_read_credential_stops_before_signing(self):
        environment = dict(GITHUB_REF_NAME='v1.0.2', GITHUB_REPOSITORY='example/vault',
                           GH_TOKEN='publisher-token', IMMUTABLE_RELEASES_READ_TOKEN='')
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release, 'run'), \
             mock.patch.object(release, 'output', return_value='{"private": false}'), \
             mock.patch.object(release, 'sign_release') as sign:
            with self.assertRaisesRegex(ValueError, 'IMMUTABLE_RELEASES_READ_TOKEN'):
                release.main([])
        sign.assert_not_called()

    def test_permission_failure_stops_verification_before_signing(self):
        environment = dict(GITHUB_REPOSITORY='example/vault', GH_TOKEN='publisher-token',
                           IMMUTABLE_RELEASES_READ_TOKEN='expired-read-token')
        def denied(*arguments, **kwargs):
            if arguments[-1].endswith('/immutable-releases'):
                raise RuntimeError('gh failed with status 1')
            return '{"private": false}'
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release, 'output', side_effect=denied), \
             mock.patch.object(release, 'sign_release') as sign:
            with self.assertRaisesRegex(RuntimeError, 'Administration: read'):
                release.main(['--verify-only', '--version', '1.0.2', '--build', '7'])
        sign.assert_not_called()

    def test_settings_must_be_explicitly_enabled(self):
        environment = dict(GITHUB_REPOSITORY='example/vault', IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token')
        for settings in [{'enabled': False}, {}, {'enabled': 1}, {'enabled': 'true'}]:
            def respond(*arguments, **kwargs):
                return json.dumps(settings) if arguments[-1].endswith('/immutable-releases') else '{"private": false}'
            with self.subTest(settings=settings), mock.patch.dict(os.environ, environment), \
                 mock.patch.object(release, 'output', side_effect=respond), \
                 mock.patch.object(release, 'sign_release') as sign:
                with self.assertRaisesRegex(ValueError, 'Enable immutable releases'):
                    release.main(['--verify-only', '--version', '1.0.2', '--build', '7'])
                sign.assert_not_called()

    def test_publication_failure_propagates_without_retrying_signing(self):
        environment = dict(GITHUB_REF_NAME='v1.0.2', GITHUB_REPOSITORY='example/vault',
                           IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token')
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release, 'run'), \
             mock.patch.object(release, 'output', side_effect=self.repository_response), \
             mock.patch.object(release.Path, 'read_text', return_value='CURRENT_PROJECT_VERSION = 7;'), \
             mock.patch.object(release.release_channels, 'publish', side_effect=RuntimeError('immutable')) as publish, \
             mock.patch.object(release, 'sign_release') as sign:
            with self.assertRaisesRegex(RuntimeError, 'immutable'):
                release.main([])
        publish.assert_called_once()
        sign.assert_not_called()

    def test_settings_credential_is_excluded_from_other_subprocesses(self):
        environment = dict(GH_TOKEN='publisher-token', IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token')
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(release.subprocess, 'run', return_value=mock.Mock(returncode=0)) as command, \
             mock.patch.object(release.subprocess, 'check_output', return_value='{}') as output:
            release.run('gh', 'release', 'create')
            release.output('gh', 'api', 'repos/example/vault')
            release.run('bash', 'sign.sh', env=dict(environment, SIGNING_PROFILE='profile'))
        for call in command.call_args_list + output.call_args_list:
            child = call.kwargs.get('env', environment)
            self.assertNotIn('IMMUTABLE_RELEASES_READ_TOKEN', child)
            self.assertEqual(child['GH_TOKEN'], 'publisher-token')
        self.assertEqual(command.call_args.kwargs['env']['SIGNING_PROFILE'], 'profile')

    def test_output_failure_does_not_expose_arguments(self):
        with mock.patch.object(release.subprocess, 'check_output',
                               side_effect=subprocess.CalledProcessError(1, ['gh', 'secret-value'])):
            with self.assertRaises(RuntimeError) as result:
                release.output('gh', 'secret-value')
        self.assertNotIn('secret-value', str(result.exception))

    def test_settings_credential_is_excluded_from_signing_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            encoded = base64.b64encode(b'test-signing-data').decode()
            environment = dict(RUNNER_TEMP=directory, GH_TOKEN='publisher-token',
                               IMMUTABLE_RELEASES_READ_TOKEN='settings-read-token',
                               APPLE_DEVELOPER_ID_P12_BASE64=encoded, APPLE_DEVELOPER_ID_P12_PASSWORD='test-password',
                               APPLE_VAULT_PROVISIONING_PROFILE_BASE64=encoded, APPLE_NOTARY_KEY_BASE64=encoded,
                               APPLE_NOTARY_KEY_ID='test-key', APPLE_NOTARY_ISSUER_ID='test-issuer',
                               SPARKLE_PRIVATE_KEY='test-sparkle-key')
            with mock.patch.dict(os.environ, environment), \
                 mock.patch.object(release, 'run'), \
                 mock.patch.object(release, 'output', return_value='"default.keychain"'), \
                 mock.patch.object(release.subprocess, 'run', return_value=mock.Mock(returncode=0)) as cleanup:
                release.sign_release('1.0.2', '7')
            child = cleanup.call_args.kwargs.get('env', environment)
            self.assertFalse('IMMUTABLE_RELEASES_READ_TOKEN' in child)

    def test_preflight_modes_reject_incompatible_arguments(self):
        invalid = [['--signing-only'], ['--preflight-only', '--signing-only'],
                   ['--verify-only', '--preflight-only'], ['--preflight-only', '--version', '1.0.2'],
                   ['--preflight-only', '--build', '7']]
        with mock.patch.object(release, 'output') as output, mock.patch.object(release, 'sign_release') as sign:
            for arguments in invalid:
                with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                    release.main(arguments)
        output.assert_not_called()
        sign.assert_not_called()

    def test_default_verification_refuses_a_private_repository(self):
        with mock.patch.dict(os.environ, GITHUB_REPOSITORY='example/vault'), \
             mock.patch.object(release, 'output', return_value='{"private": true}'), \
             mock.patch.object(release, 'sign_release') as sign:
            with self.assertRaisesRegex(ValueError, 'public repository'):
                release.main(['--verify-only', '--version', '1.0.2', '--build', '7'])
        sign.assert_not_called()

    def test_verification_rejects_invalid_metadata_before_signing(self):
        with mock.patch.object(release, 'sign_release') as sign:
            for arguments in [
                ['--verify-only'],
                ['--verify-only', '--version', '1.0.0'],
                ['--verify-only', '--version', 'v1.0.0', '--build', '3'],
                ['--verify-only', '--version', '1.0.0', '--build', '0'],
                ['--verify-only', '--version', '1.0.0', '--build', '3;echo unsafe'],
            ]:
                with self.subTest(arguments=arguments), self.assertRaises((ValueError, SystemExit)):
                    release.main(arguments)
        sign.assert_not_called()

    def test_production_rejects_test_version_overrides(self):
        with self.assertRaises(SystemExit):
            release.main(['--version', '1.0.0', '--build', '3'])

    def test_production_still_refuses_a_private_repository_before_signing(self):
        with mock.patch.dict(os.environ, GITHUB_REF_NAME='v1.0.0', GITHUB_REPOSITORY='example/vault'), \
             mock.patch.object(release, 'run'), \
             mock.patch.object(release, 'output', return_value='{"private": true}'), \
             mock.patch.object(release, 'sign_release') as sign:
            with self.assertRaisesRegex(ValueError, 'public repository'):
                release.main([])
        sign.assert_not_called()

    def test_subprocess_failure_does_not_expose_arguments(self):
        with self.assertRaises(RuntimeError) as result:
            release.run('false', 'secret-value')
        self.assertNotIn('secret-value', str(result.exception))


if __name__ == '__main__':
    unittest.main()
