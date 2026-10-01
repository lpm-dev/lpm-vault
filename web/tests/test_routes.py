import http.client
import re
import subprocess
import time
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSET_TYPES = {
    '/style.css': 'text/css',
    '/site.js': 'javascript',
    '/lpm-vault.svg': 'image/svg+xml',
    '/lpm-vault-32.png': 'image/png',
    '/lpm-vault-512.png': 'image/png',
    '/apple-touch-icon.png': 'image/png',
    '/fonts/geist-5.3.0-latin.woff2': 'font/woff2',
    '/fonts/jetbrains-mono-5.3.0-latin.woff2': 'font/woff2',
    '/fonts/OFL-Geist.txt': 'text/plain',
    '/fonts/OFL-JetBrains-Mono.txt': 'text/plain',
    '/robots.txt': 'text/plain',
}


class PageInventory(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.fragment_links = set()
        self.local_references = set()
        self.external_subresources = []
        self.inline_styles = []
        self.inline_scripts = 0
        self.event_handlers = []
        self.flyers = set()
        self.flyer_targets = set()
        self.copy_sources = set()
        self._in_inline_script = False

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if 'id' in attributes:
            self.ids.add(attributes['id'])
        if 'style' in attributes or tag == 'style':
            self.inline_styles.append(tag)
        self.event_handlers.extend(name for name in attributes if name.startswith('on'))
        if tag == 'script':
            if attributes.get('src'):
                self._record_subresource(attributes['src'])
            else:
                self._in_inline_script = True
        if tag == 'link' and attributes.get('rel') in {'stylesheet', 'preload', 'icon', 'apple-touch-icon'}:
            self._record_subresource(attributes['href'])
        if tag in {'img', 'source'} and attributes.get('src'):
            self._record_subresource(attributes['src'])
        for name in ('href', 'src'):
            value = attributes.get(name) or ''
            if value.startswith('#') and len(value) > 1:
                self.fragment_links.add(value[1:])
            elif value.startswith('/') and not value.startswith('//'):
                self.local_references.add(value)
        if 'data-flyer' in attributes:
            self.flyers.add(attributes['data-flyer'])
        if 'data-flyer-target' in attributes:
            self.flyer_targets.add(attributes['data-flyer-target'])
        if 'data-copy' in attributes:
            self.copy_sources.add(attributes['data-copy'])

    def handle_data(self, data):
        if self._in_inline_script and data.strip():
            self.inline_scripts += 1

    def handle_endtag(self, tag):
        if tag == 'script':
            self._in_inline_script = False

    def _record_subresource(self, url):
        if not url.startswith('/') or url.startswith('//'):
            self.external_subresources.append(url)


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
    def request(cls, path, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', cls.port, timeout=3)
        try:
            connection.request('GET', path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_product_and_assets(self):
        for path in ['/', '/health', *ASSET_TYPES]:
            with self.subTest(path=path):
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertTrue(body)
                self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
                self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])
                if path in ASSET_TYPES:
                    self.assertIn(ASSET_TYPES[path], headers['Content-Type'])

    def test_content_security_policy_allows_only_same_origin_code(self):
        _, headers, _ = self.request('/')
        directives = {
            parts[0]: parts[1:]
            for parts in (directive.split() for directive in headers['Content-Security-Policy'].split(';'))
            if parts
        }
        self.assertEqual(directives['default-src'], ["'none'"])
        for directive in ['script-src', 'style-src', 'font-src', 'img-src']:
            with self.subTest(directive=directive):
                self.assertEqual(directives[directive], ["'self'"])

    def test_page_is_compatible_with_content_security_policy(self):
        _, _, body = self.request('/')
        page = PageInventory()
        page.feed(body.decode())
        self.assertEqual(page.inline_styles, [])
        self.assertEqual(page.inline_scripts, 0)
        self.assertEqual(page.event_handlers, [])
        self.assertEqual(page.external_subresources, [])

    def test_page_references_resolve(self):
        _, _, body = self.request('/')
        page = PageInventory()
        page.feed(body.decode())
        self.assertEqual(page.fragment_links - page.ids, set())
        self.assertEqual(page.copy_sources - page.ids, set())
        self.assertTrue(page.flyers)
        self.assertEqual(page.flyers, page.flyer_targets)
        for path in sorted(page.local_references - {'/download'}):
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 200)

    def test_stylesheet_references_resolve(self):
        _, _, body = self.request('/style.css')
        urls = set(re.findall(r'url\("([^"]+)"\)', body.decode()))
        self.assertTrue(urls)
        for url in sorted(urls):
            with self.subTest(url=url):
                self.assertTrue(url.startswith('/'))
                self.assertEqual(self.request(url)[0], 200)

    def test_text_assets_are_compressed(self):
        for path in ['/', '/style.css', '/site.js', '/lpm-vault.svg']:
            with self.subTest(path=path):
                _, headers, _ = self.request(path, {'Accept-Encoding': 'gzip'})
                self.assertEqual(headers.get('Content-Encoding'), 'gzip')
                self.assertIn('Accept-Encoding', headers.get('Vary', ''))

    def test_versioned_fonts_are_immutable_and_pages_revalidate(self):
        for path in ['/fonts/geist-5.3.0-latin.woff2', '/fonts/jetbrains-mono-5.3.0-latin.woff2']:
            with self.subTest(path=path):
                self.assertIn('immutable', self.request(path)[1]['Cache-Control'])
        for path in ['/', '/style.css', '/site.js', '/fonts/OFL-Geist.txt']:
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[1]['Cache-Control'], 'no-cache')

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
