#!/usr/bin/env python3
"""Decide whether a pull request needs the native UI suite before it merges.

It does when it changes the suite's tests, test support code they can use,
or how the suite runs. A change to the app itself relies on the `ui-tests`
label: most don't change what a view shows, and the suite takes minutes.

BASE and HEAD default to HEAD^1 and HEAD, as in a pull request's checkout:
its merge commit, whose first parent is the base branch.
"""
import argparse
from pathlib import Path
import re
import subprocess

SUITE = 'SheetInteractionTests'
SUITE_DECLARATION = re.compile(rf'\b(?:struct|extension)\s+{SUITE}\b')
TEST_DECLARATION = re.compile(r'@Test\b|@Suite\b|\bXCTestCase\b')
TESTS = 'LPMVault/Tests/'
RUNNER = {
    '.github/workflows/ui.yml',
    '.github/workflows/swift-tests.yml',
    'LPMVault/Scripts/swift-test-shard.py',
    'LPMVault/Scripts/swift-test-watchdog.sh',
    'LPMVault/Scripts/ui-suite-changes.py',
}


def is_test_source(path):
    return path.startswith(TESTS) and path.endswith('.swift')


def reason(path, before, after):
    """Why changing `path` from `before` to `after` needs the UI suite, or None.

    `before` and `after` are a test source's text, None where it doesn't
    exist; no other file's text matters.
    """
    if path in RUNNER:
        return 'runs the UI suite'
    if not is_test_source(path):
        return None
    versions = [text for text in (before, after) if text is not None]
    if any(SUITE_DECLARATION.search(text) for text in versions):
        return f'has {SUITE} tests'
    if not any(TEST_DECLARATION.search(text) for text in versions):
        return 'is test support code'
    return None


def ui_suite_changes(root, base, head):
    """Each changed path that needs the UI suite, with the reason, sorted by path."""
    def git(*arguments):
        return subprocess.run(['git', *arguments], cwd=root, check=True, capture_output=True, text=True).stdout

    fields = git('diff', '--name-status', '--no-renames', '-z', base, head).split('\0')[:-1]
    changes = []
    for status, path in zip(fields[::2], fields[1::2]):
        source = is_test_source(path)
        before = git('show', f'{base}:{path}') if source and status != 'A' else None
        after = git('show', f'{head}:{path}') if source and status != 'D' else None
        if why := reason(path, before, after):
            changes.append((path, why))
    return sorted(changes)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('base', nargs='?', default='HEAD^1')
    parser.add_argument('head', nargs='?', default='HEAD')
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    changes = ui_suite_changes(Path(__file__).resolve().parents[2], args.base, args.head)
    for path, why in changes:
        print(f'{path} {why}.')
    if not changes:
        print('Nothing changes the UI suite, its support code or how it runs.')
    if args.github_output:
        with args.github_output.open('a') as output:
            output.write(f'needed={str(bool(changes)).lower()}\n')


if __name__ == '__main__':
    main()
