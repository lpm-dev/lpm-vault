#!/usr/bin/env python3
"""Write Credits.html, which About LPM Vault shows: the notices of everything the app bundles."""
import argparse
import html
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CREDITS = ROOT / 'Credits.html'
SPARKLE_VERSION = '2.10.0'
SPARKLE_LICENSE = ROOT / 'Licenses/Sparkle-LICENSE'
ENGINE_NOTICES = ROOT / 'Vendor/EnvEngine/THIRD_PARTY_NOTICES.html'
# No colors, so the About panel's own text color applies in light and dark mode.
STYLE = (
    'body { font-family: -apple-system, sans-serif; font-size: 11px; }\n'
    'h1 { font-size: 14px; }\n'
    'h2 { font-size: 13px; }\n'
    'h3, h4 { font-size: 11px; }\n'
    'pre { font-family: Menlo, monospace; font-size: 10px; white-space: pre-wrap; }'
)


def credits(sparkle_license, engine_notices):
    body = re.search(r'<body>(.*)</body>', engine_notices, re.DOTALL | re.IGNORECASE)
    if body is None:
        raise ValueError('The engine notices have no body')
    engine = re.sub(r'<(/?)h([1-5])\b', lambda heading: '<' + heading.group(1) + 'h' + str(int(heading.group(2)) + 1), body.group(1).strip())
    return '\n'.join([
        '<!DOCTYPE html>', '<html>', '<head>', '<meta charset="UTF-8">', '<title>Acknowledgements</title>',
        '<style>', STYLE, '</style>', '</head>', '<body>',
        '<h1>Acknowledgements</h1>',
        '<h2>Sparkle ' + SPARKLE_VERSION + '</h2>',
        '<pre>' + html.escape(sparkle_license.strip()) + '</pre>',
        engine,
        '</body>', '</html>', '',
    ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if Credits.html is out of date instead of writing it')
    args = parser.parse_args()
    expected = credits(SPARKLE_LICENSE.read_text(), ENGINE_NOTICES.read_text())
    if args.check:
        if not CREDITS.is_file() or CREDITS.read_text() != expected:
            sys.exit('Credits.html is out of date: run python3 LPMVault/Scripts/generate-credits.py')
        print('Credits.html is up to date')
        return
    CREDITS.write_text(expected)
    print('Wrote ' + str(CREDITS))


if __name__ == '__main__':
    main()
