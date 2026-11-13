#!/usr/bin/env python3
"""Decide whether a run rebuilds the bundled env engine from its pinned source.

A pull request does when it changes the bundled engine, or how the rebuild
runs: nothing else it changes can alter what the rebuild compares, and each
rebuild holds a macOS runner for minutes. Every other run does, so the
engine is rebuilt after each merge to main, before each release and every
night, which is where a change outside the repository, such as a new runner
image, shows.

BASE and HEAD default to HEAD^1 and HEAD, as in a pull request's checkout:
its merge commit, whose first parent is the base branch.
"""
import argparse
from pathlib import Path
import subprocess

ENGINE = 'LPMVault/Vendor/EnvEngine/'
RUNNER = {
    '.github/workflows/ci.yml',
    'LPMVault/Scripts/ci-cache-key.py',
    'LPMVault/Scripts/engine-changes.py',
    'LPMVault/Scripts/verify-env-engine.py',
}


def reason(path):
    """Why a change to `path` needs the engine rebuilt, or None."""
    if path.startswith(ENGINE):
        return 'is part of the bundled engine'
    if path in RUNNER:
        return 'runs the engine rebuild'
    return None


def engine_changes(root, base, head):
    """Each changed path that needs the engine rebuilt, with the reason, sorted by path."""
    diff = subprocess.run(['git', 'diff', '--name-only', '--no-renames', '-z', base, head],
                          cwd=root, check=True, capture_output=True, text=True).stdout
    return sorted((path, why) for path in diff.split('\0')[:-1] if (why := reason(path)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('base', nargs='?', default='HEAD^1')
    parser.add_argument('head', nargs='?', default='HEAD')
    parser.add_argument('--event', required=True, help='The name of the event the run answers, as GITHUB_EVENT_NAME gives it.')
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    if args.event == 'pull_request':
        changes = engine_changes(Path(__file__).resolve().parents[2], args.base, args.head)
        for path, why in changes:
            print(f'{path} {why}.')
        if not changes:
            print('Nothing changes the bundled engine or how its rebuild runs.')
        needed = bool(changes)
    else:
        print(f'A {args.event} run always rebuilds the engine.')
        needed = True
    if args.github_output:
        with args.github_output.open('a') as output:
            output.write(f'needed={str(needed).lower()}\n')


if __name__ == '__main__':
    main()
