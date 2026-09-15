import base64
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1]


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

    def test_verification_signs_without_publication_or_repository_checks(self):
        with mock.patch.object(release, 'sign_release') as sign, \
             mock.patch.object(release, 'run') as command, \
             mock.patch.object(release, 'output') as output:
            release.main(['--verify-only', '--version', '1.0.0', '--build', '3'])
        sign.assert_called_once_with('1.0.0', '3')
        command.assert_not_called()
        output.assert_not_called()

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
