#!/usr/bin/env python3
"""Choose one shard of the package's Swift tests, so CI can run them on parallel runners.

Usage: swift-test-shard.py K/N TESTS_FILE FILTERS_FILE [swift test arguments...]

Writes the identifiers of the Kth of N shards' tests to TESTS_FILE and a
`swift test --filter` pattern for each to FILTERS_FILE, one per line.

With SWIFT_TEST_ISOLATED_SUITE naming a suite, such as
`Module.SheetInteractionTests`, shard 1 runs every test outside it and the
other shards split its tests: a serialized suite whose tests wait on the
screen then never shares a process with the parallel tests that could
starve those waits.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

REGEX_SPECIALS = set('\\.^$|?*+()[]{}')


def parse_shard(value):
    match = re.fullmatch(r'([1-9][0-9]*)/([1-9][0-9]*)', value)
    if not match or int(match[1]) > int(match[2]):
        raise ValueError(f'Invalid shard {value!r}; expected K/N with 1 <= K <= N')
    return int(match[1]), int(match[2])


def shard_of(identifier, count):
    """The shard of a test, from its identifier alone, so adding a test moves no other."""
    return int.from_bytes(hashlib.sha256(identifier.encode()).digest()[:8], 'big') % count + 1


def identifiers(listing):
    """Test identifiers such as `Module.Suite/Nested/test(label:)`, sorted.

    Filters match identifiers anywhere in a test's name, so each must name
    its module once and be no other identifier's prefix: then a filter can
    match only its own test.
    """
    tests = sorted({line.strip() for line in listing.splitlines() if line.strip()})
    if not tests:
        raise ValueError('swift test list found no tests')
    for test in tests:
        module, separator, _ = test.partition('.')
        if not separator or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', module) or test.count(module + '.') != 1:
            raise ValueError(f'Unexpected test identifier {test!r}')
    for shorter, longer in zip(tests, tests[1:]):
        if longer.startswith(shorter):
            raise ValueError(f'Test identifier {shorter!r} is a prefix of {longer!r}')
    return tests


def pattern(identifier):
    return ''.join('\\' + character if character in REGEX_SPECIALS else character for character in identifier)


def select(tests, shard, count, isolated=None):
    if not isolated:
        return [test for test in tests if shard_of(test, count) == shard]
    if count < 2:
        raise ValueError('An isolated suite needs at least two shards')
    inside = [test for test in tests if test.startswith(isolated + '/')]
    if not inside:
        raise ValueError(f'No tests in the isolated suite {isolated!r}')
    if shard == 1:
        return [test for test in tests if not test.startswith(isolated + '/')]
    return [test for test in inside if shard_of(test, count - 1) + 1 == shard]


def main(arguments):
    if len(arguments) < 3:
        raise SystemExit(__doc__)
    try:
        shard, count = parse_shard(arguments[0])
        listing = subprocess.run(['swift', 'test', 'list', *arguments[3:], '--enable-swift-testing', '--disable-xctest'],
                                 check=True, capture_output=True, text=True).stdout
        tests = select(identifiers(listing), shard, count, os.environ.get('SWIFT_TEST_ISOLATED_SUITE'))
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'::error::Could not choose the tests of shard {arguments[0]}: {error}')
    if not tests:
        raise SystemExit(f'::error::Shard {arguments[0]} has no tests')
    Path(arguments[1]).write_text(''.join(test + '\n' for test in tests))
    Path(arguments[2]).write_text(''.join(pattern(test) + '\n' for test in tests))


if __name__ == '__main__':
    main(sys.argv[1:])
