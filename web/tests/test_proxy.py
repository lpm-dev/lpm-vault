import http.client
import subprocess
import tempfile
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVENT_ORIGIN = {'Origin': 'https://vault.lpm.dev'}


class EventProxy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['docker', 'build', '-q', '-f', 'web/Dockerfile', '-t', 'lpm-vault-proxy-test', '.'], cwd=ROOT, check=True)
        cls.fixture = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixture.cleanup)
        directory = Path(cls.fixture.name)
        directory.chmod(0o755)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=eu.i.posthog.com', '-addext', 'subjectAltName=DNS:eu.i.posthog.com',
                        '-keyout', str(directory / 'key.pem'), '-out', str(directory / 'cert.pem')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (directory / 'key.pem').chmod(0o644)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=untrusted.test', '-keyout', str(directory / 'other-key.pem'),
                        '-out', str(directory / 'other-cert.pem')], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.directory = directory
        (directory / 'upstream.conf').write_text('''server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    ssl_certificate /fixture/cert.pem;
    ssl_certificate_key /fixture/key.pem;
    location = /e/ {
        add_header Set-Cookie "upstream=must-not-persist";
        add_header Cache-Control "public, max-age=3600";
        add_header Access-Control-Allow-Origin "*";
        return 200 "$request_method|$http_host|$http_cookie|$http_authorization|$http_referer|$http_x_forwarded_for|$args|$remote_addr";
    }
}''')
        template = (ROOT / 'web/nginx.conf').read_text().replace('eu.i.posthog.com:443', 'eu.i.posthog.com:8443')
        (directory / 'proxy.conf').write_text(template)
        cls.network = cls.create_network()
        prefix = uuid.uuid4().hex
        cls.dual_stack_network = cls.create_network('--ipv6', '--subnet', f'fd{prefix[:2]}:{prefix[2:6]}:{prefix[6:10]}:{prefix[10:14]}::/64')
        upstream = ['--network-alias', 'eu.i.posthog.com', '-v', f'{directory}:/fixture:ro',
                    '-v', f'{directory}/upstream.conf:/etc/nginx/conf.d/upstream.conf:ro']
        cls.upstream = cls.run_container(cls.network, upstream)
        cls.run_container(cls.dual_stack_network, upstream)
        cls.proxy, cls.port = cls.start_proxy(cls.network)

    @classmethod
    def create_network(cls, *arguments):
        name = 'vault-proxy-' + uuid.uuid4().hex
        subprocess.run(['docker', 'network', 'create', *arguments, name], check=True, stdout=subprocess.DEVNULL)
        cls.addClassCleanup(lambda: subprocess.run(['docker', 'network', 'rm', name], check=True, stdout=subprocess.DEVNULL))
        return name

    @classmethod
    def run_container(cls, network, arguments):
        identifier = subprocess.check_output(['docker', 'run', '-d', '--network', network, *arguments, 'lpm-vault-proxy-test'], text=True).strip()
        cls.addClassCleanup(lambda: subprocess.run(['docker', 'rm', '-f', identifier], check=True, stdout=subprocess.DEVNULL))
        return identifier

    @classmethod
    def start_proxy(cls, network, trusted_certificate='cert.pem', arguments=()):
        proxy = cls.run_container(network, ['-p', '127.0.0.1::8080', *arguments,
                                            '-v', f'{cls.directory}/proxy.conf:/etc/nginx/templates/default.conf.template:ro',
                                            '-v', f'{cls.directory}/{trusted_certificate}:/etc/ssl/certs/ca-certificates.crt:ro'])
        port = int(subprocess.check_output(['docker', 'port', proxy, '8080'], text=True).strip().rsplit(':', 1)[1])
        for _ in range(50):
            try:
                if cls.request('/health', method='GET', port=port)[0] == 200:
                    return proxy, port
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.1)
        raise RuntimeError('Proxy fixture did not start')

    def upstream_clients(self, port):
        # Each nginx worker caches its own lookups and starts a cached one at a random address. One connection keeps
        # these requests on one worker, so 20 of them reach both address families of a dual-stack upstream.
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
        self.addCleanup(connection.close)
        clients = set()
        for _ in range(20):
            connection.request('POST', '/ingest/e/', body=b'{"event":"fixture"}', headers=EVENT_ORIGIN)
            response = connection.getresponse()
            body = response.read()
            self.assertEqual(response.status, 200)
            clients.add(body.decode().rsplit('|', 1)[1])
        return clients

    @classmethod
    def request(cls, path='/ingest/e/', method='POST', headers=None, body=b'{"event":"fixture"}', port=None):
        connection = http.client.HTTPConnection('127.0.0.1', port or cls.port, timeout=15)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_forwards_only_the_event_endpoint_without_browser_credentials(self):
        status, headers, body = self.request('/ingest/e/?v=1&compression=base64', headers={
            'Origin': 'https://vault.lpm.dev', 'Cookie': 'private=secret', 'Authorization': 'Bearer secret',
            'Referer': 'https://vault.lpm.dev/?token=secret', 'X-Forwarded-For': '192.0.2.10',
        })
        self.assertEqual(status, 200)
        fields = body.decode().split('|')
        self.assertEqual(fields[:5], ['POST', 'eu.i.posthog.com', '', '', ''])
        self.assertTrue(fields[5].startswith('192.0.2.10, '))
        self.assertEqual(fields[6], 'v=1&compression=base64')
        self.assertEqual(headers['Cache-Control'], 'no-store')
        self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
        for name in ['Set-Cookie', 'Access-Control-Allow-Origin', 'Access-Control-Allow-Credentials']:
            self.assertNotIn(name, headers)

    def test_rejects_other_methods_origins_and_oversized_events(self):
        for method in ['GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS']:
            with self.subTest(method=method):
                self.assertEqual(self.request(method=method)[0], 405)
        self.assertEqual(self.request(headers={'Origin': 'https://evil.test'})[0], 403)
        self.assertEqual(self.request(headers={'Origin': 'null'})[0], 403)
        self.assertEqual(self.request(body=b'x' * 65537)[0], 413)
        for path in ['/ingest/flags', '/ingest/static/replay.js', '/ingest/e/extra', '/ingest/?target=https://evil.test']:
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 404)

    def test_untrusted_upstream_certificates_are_rejected(self):
        _, port = self.start_proxy(self.network, trusted_certificate='other-cert.pem')
        self.assertEqual(self.request(port=port)[0], 502)

    def test_a_container_without_ipv6_never_dials_ipv6_upstream_addresses(self):
        proxy, port = self.start_proxy(self.dual_stack_network, arguments=['--sysctl', 'net.ipv6.conf.all.disable_ipv6=1'])
        self.assertTrue(all(':' not in client for client in self.upstream_clients(port)))
        logs = subprocess.run(['docker', 'logs', proxy], capture_output=True, text=True, check=True)
        failed_connections = [line for line in logs.stderr.splitlines() if 'while connecting to upstream' in line]
        self.assertEqual(failed_connections, [])

    def test_a_container_with_ipv6_still_reaches_ipv6_upstream_addresses(self):
        _, port = self.start_proxy(self.dual_stack_network)
        clients = self.upstream_clients(port)
        self.assertTrue(any(':' in client for client in clients), clients)


if __name__ == '__main__':
    unittest.main()
