import http.client
import subprocess
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class Routes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['docker', 'build', '-f', 'web/Dockerfile', '-t', 'lpm-vault-web-test', '.'], cwd=ROOT, check=True)
        cls.container = subprocess.check_output(['docker', 'run', '-d', '-p', '127.0.0.1::8080', 'lpm-vault-web-test'], text=True).strip()
        cls.addClassCleanup(lambda: subprocess.run(['docker', 'rm', '-f', cls.container], check=True, stdout=subprocess.DEVNULL))
        cls.port = int(subprocess.check_output(['docker', 'port', cls.container, '8080'], text=True).strip().rsplit(':', 1)[1])
        for _ in range(50):
            try:
                if cls.request('/health')[0] == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.1)
        raise RuntimeError('Website did not become healthy')

    @classmethod
    def request(cls, path):
        connection = http.client.HTTPConnection('127.0.0.1', cls.port, timeout=3)
        try:
            connection.request('GET', path)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_product_and_assets(self):
        for path in ['/', '/style.css', '/lpm.png', '/health']:
            with self.subTest(path=path):
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertTrue(body)
                self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
                self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])

    def test_current_routes_do_not_cache(self):
        for path, asset in [('/download', 'LPM-Vault.dmg'), ('/updates/appcast.xml', 'appcast.xml')]:
            status, headers, _ = self.request(path)
            self.assertEqual(status, 302)
            self.assertEqual(headers['Location'], f'https://github.com/lpm-dev/lpm-vault/releases/latest/download/{asset}')
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')

    def test_versioned_artifacts_are_immutable(self):
        path = '/releases/v1.2.3/LPM-Vault-1.2.3.dmg'
        status, headers, _ = self.request(path)
        self.assertEqual(status, 308)
        self.assertEqual(headers['Location'], 'https://github.com/lpm-dev/lpm-vault/releases/download/v1.2.3/LPM-Vault-1.2.3.dmg')
        self.assertIn('immutable', headers['Cache-Control'])

    def test_malformed_routes_cannot_redirect_to_arbitrary_targets(self):
        for path in ['/releases/latest/test.dmg', '/releases/v1.0.0/evil.exe', '/releases/v1.0.0/.env',
                     '/releases/v1.0.0/a%0d%0aLocation:%20https://evil.test', '/releases/v1.0.0/../../.git/config',
                     '/.git/config', '/Dockerfile', '/missing', '/updates/other.xml']:
            with self.subTest(path=path):
                status, headers, _ = self.request(path)
                self.assertIn(status, [400, 404])
                self.assertNotIn('Location', headers)


if __name__ == '__main__':
    unittest.main()
