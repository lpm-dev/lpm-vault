import hashlib
import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location('credits', Path(__file__).resolve().parents[1] / 'generate-credits.py')
credits = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credits)
ROOT = credits.ROOT
# Sparkle's LICENSE at the 2.10.0 tag.
SPARKLE_LICENSE_SHA256 = '389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe'


class CreditsTests(unittest.TestCase):
    def test_credits_html_is_generated_from_the_bundled_notices(self):
        expected = credits.credits(credits.SPARKLE_LICENSE.read_text(), credits.ENGINE_NOTICES.read_text())
        self.assertEqual(credits.CREDITS.read_text(), expected, 'run python3 LPMVault/Scripts/generate-credits.py')

    def test_the_sparkle_license_is_the_pinned_versions(self):
        self.assertEqual(hashlib.sha256(credits.SPARKLE_LICENSE.read_bytes()).hexdigest(), SPARKLE_LICENSE_SHA256)
        version = re.escape(credits.SPARKLE_VERSION)
        self.assertRegex((ROOT / 'Package.swift').read_text(), r'sparkle-project/Sparkle", exact: "' + version + '"')
        self.assertRegex((ROOT / 'project.yml').read_text(), r'Sparkle:\n\s+url: https://github.com/sparkle-project/Sparkle\n\s+exactVersion: "' + version + '"')
        self.assertRegex((ROOT / 'Package.resolved').read_text(), r'"identity" : "sparkle",[\s\S]*?"version" : "' + version + '"')

    def test_credits_carry_every_notice_with_headings_below_their_own(self):
        engine = '<html><body>\n<h1>Third-party notices for the LPM env engine</h1>\n<h3 id="text-1">1</h3>\n<pre>MIT &lt;terms&gt;</pre>\n</body></html>'
        page = credits.credits('Copyright (c) Sparkle <authors>\n', engine)
        self.assertIn('<h2>Sparkle ' + credits.SPARKLE_VERSION + '</h2>\n<pre>Copyright (c) Sparkle &lt;authors&gt;</pre>', page)
        self.assertIn('<h2>Third-party notices for the LPM env engine</h2>', page)
        self.assertIn('<h4 id="text-1">1</h4>', page)
        self.assertIn('<pre>MIT &lt;terms&gt;</pre>', page)
        self.assertNotIn('color', page)
        with self.assertRaisesRegex(ValueError, 'no body'):
            credits.credits('license', '<html>no body</html>')

    def test_the_app_bundles_credits_where_the_about_panel_looks(self):
        self.assertRegex((ROOT / 'project.yml').read_text(), r'- path: Credits\.html\n\s+buildPhase: resources')
        self.assertIn('/* Credits.html in Resources */', (ROOT / 'LPMVault.xcodeproj/project.pbxproj').read_text())


if __name__ == '__main__':
    unittest.main()
