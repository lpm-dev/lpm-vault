#!/usr/bin/env python3
"""Keep the protected macOS check dependent on every parallel verification job."""
import json
import os


def failures(results):
    required = {'swift', 'engine', 'release'}
    failed = [name for name in sorted(required) if results.get(name, {}).get('result') != 'success']
    failed += [name for name in sorted(results.keys() - required)]
    return failed


def main():
    failed = failures(json.loads(os.environ['CI_NEEDS']))
    if failed:
        raise SystemExit('Required macOS jobs did not succeed: ' + ', '.join(failed))
    print('Swift tests, engine reproduction, and release verification passed.')


if __name__ == '__main__':
    main()
