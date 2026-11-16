#!/usr/bin/env python3
"""Keep the protected macOS check dependent on every parallel verification job."""
import json
import os

REQUIRED = {'plan', 'swift', 'engine', 'release'}
MACOS = REQUIRED - {'plan'}


def plan(results):
    """What the plan job decided, or nothing where it didn't succeed."""
    job = results.get('plan') or {}
    return (job.get('outputs') or {}) if job.get('result') == 'success' else {}


def failures(results):
    """The jobs that keep the check from passing.

    Each must succeed. A macOS job may be skipped only because the plan job
    said so: all of them where a pull request's run passed this same tree,
    and the engine rebuild where nothing changed the engine. A job skipped
    for any other reason, such as a cancelled run, has verified nothing.
    """
    decided = plan(results)
    accepted = {name: {'success'} for name in REQUIRED}
    if decided.get('verified') == 'true':
        for name in MACOS:
            accepted[name].add('skipped')
    if decided.get('engine') == 'false':
        accepted['engine'].add('skipped')
    failed = [name for name in sorted(REQUIRED) if (results.get(name) or {}).get('result') not in accepted[name]]
    return failed + sorted(results.keys() - REQUIRED)


def main():
    results = json.loads(os.environ['CI_NEEDS'])
    failed = failures(results)
    if failed:
        raise SystemExit('Required macOS jobs did not succeed: ' + ', '.join(failed))
    skipped = {name for name in MACOS if results[name]['result'] == 'skipped'}
    if skipped == MACOS:
        print(f'{plan(results).get("run")} passed Swift tests and release verification on this same tree, so they were not run again.')
    elif skipped:
        print('Swift tests and release verification passed. Nothing changed the bundled engine, so it was not rebuilt.')
    else:
        print('Swift tests, engine reproduction, and release verification passed.')


if __name__ == '__main__':
    main()
