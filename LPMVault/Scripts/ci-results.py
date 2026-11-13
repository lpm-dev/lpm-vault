#!/usr/bin/env python3
"""Keep the protected macOS check dependent on every parallel verification job."""
import json
import os

REQUIRED = {'changes', 'swift', 'engine', 'release'}


def engine_needed(results):
    """False only when the changes job itself said this run needn't rebuild the engine."""
    changes = results.get('changes') or {}
    return not (changes.get('result') == 'success' and (changes.get('outputs') or {}).get('engine') == 'false')


def failures(results):
    """The jobs that keep the check from passing.

    Each must succeed. The engine rebuild alone may be skipped, and only
    because the changes job said so: a job skipped for any other reason,
    such as a cancelled run, has verified nothing.
    """
    accepted = {name: {'success'} for name in REQUIRED}
    if not engine_needed(results):
        accepted['engine'].add('skipped')
    failed = [name for name in sorted(REQUIRED) if (results.get(name) or {}).get('result') not in accepted[name]]
    return failed + sorted(results.keys() - REQUIRED)


def main():
    results = json.loads(os.environ['CI_NEEDS'])
    failed = failures(results)
    if failed:
        raise SystemExit('Required macOS jobs did not succeed: ' + ', '.join(failed))
    if results['engine']['result'] == 'skipped':
        print('Swift tests and release verification passed. Nothing changed the bundled engine, so it was not rebuilt.')
    else:
        print('Swift tests, engine reproduction, and release verification passed.')


if __name__ == '__main__':
    main()
