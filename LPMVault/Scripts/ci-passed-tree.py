#!/usr/bin/env python3
"""Let the merge queue skip the macOS jobs a pull request's run passed on the same tree.

A pull request's checks run on its merge with the base branch. If the base
hasn't moved when the pull request is queued, its merge group holds that
same tree, and the same jobs would only repeat, on runners that are often
short. So a pull request's run that passes names an artifact after the tree
it checked (`record`), and a merge group's run looks for one named after
its own (`find`).

Only a completed, successful run of the CI workflow for a pull request from
this repository counts: a fork's run can name its artifacts as it likes. A
lookup that fails, for any reason, finds nothing, and the jobs run.
"""
import argparse
import json
from pathlib import Path
import subprocess

PREFIX = 'ci-passed-tree-'
WORKFLOW = '.github/workflows/ci.yml'


def tree(root):
    """The tree of the commit checked out at `root`."""
    return subprocess.run(['git', 'rev-parse', '--verify', 'HEAD^{tree}'],
                          cwd=root, check=True, capture_output=True, text=True).stdout.strip()


def artifact_name(tree):
    return PREFIX + tree


def passing_run(name, artifacts, run):
    """The first run that uploaded one of `artifacts` under `name` and whose pass counts, or None.

    `run` gives a run's record for its ID; it is asked only about a run
    this repository's own branch started.
    """
    for artifact in artifacts:
        source = artifact.get('workflow_run') or {}
        if artifact.get('name') != name or artifact.get('expired') is not False or not source.get('id'):
            continue
        if not source.get('repository_id') or source.get('repository_id') != source.get('head_repository_id'):
            continue
        record = run(source['id'])
        if (record.get('path') == WORKFLOW and record.get('event') == 'pull_request'
                and record.get('status') == 'completed' and record.get('conclusion') == 'success'):
            return record
    return None


def api(endpoint):
    return json.loads(subprocess.run(['gh', 'api', endpoint], check=True, capture_output=True, text=True, timeout=60).stdout)


def find(root, repository):
    """The run that passed the tree checked out at `root`, or None with the reason there is none."""
    try:
        name = artifact_name(tree(root))
        artifacts = api(f'repos/{repository}/actions/artifacts?name={name}&per_page=100')['artifacts']
        run = passing_run(name, artifacts, lambda identifier: api(f'repos/{repository}/actions/runs/{identifier}'))
    except Exception as error:
        return None, f'The lookup failed: {error}'
    return run, None if run else f'No pull request run has passed this tree ({len(artifacts)} named {name}).'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    record = commands.add_parser('record', help='Name the artifact that says the checked-out tree passed.')
    record.add_argument('--marker', type=Path, required=True, help='The file to upload as that artifact.')
    record.add_argument('--github-output', type=Path, required=True)
    lookup = commands.add_parser('find', help='Find a pull request run that passed the checked-out tree.')
    lookup.add_argument('--repository', required=True, help='The repository, as owner/name.')
    lookup.add_argument('--github-output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.command == 'record':
        checked = tree(root)
        args.marker.write_text(checked + '\n')
        lines = [f'name={artifact_name(checked)}']
        print(f'These checks passed tree {checked}.')
    else:
        run, reason = find(root, args.repository)
        lines = [f'verified={str(run is not None).lower()}']
        if run:
            link = f'https://github.com/{args.repository}/actions/runs/{int(run["id"])}'
            lines.append(f'run={link}')
            print(f'{link} passed this tree, so the macOS jobs are not run again.')
        else:
            print(reason)
    with args.github_output.open('a') as output:
        output.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
