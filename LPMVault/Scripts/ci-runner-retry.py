#!/usr/bin/env python3
"""Run a failed run's jobs again when all that failed was getting a runner.

GitHub gives up on a job that no hosted runner takes within about 15
minutes, and the run fails though nothing ran. Such a run's failed jobs are
run again, until the run has had LAST_ATTEMPT attempts.

A run in which a job ran and failed is left as it is, even if another job
got no runner: running it again could turn a test that fails some of the
time green, and the failure is the thing to look at. The job that only
reports the others' results doesn't count as one that ran.
"""
import argparse
import json
import subprocess

LAST_ATTEMPT = 3
PASSED = {'success', 'skipped', 'neutral'}
# The jobs that fail only because a job they wait for did.
REPORTS = {'macOS tests and release bundle'}


def no_runner(job):
    """Whether the job ended without a runner ever taking it."""
    return job.get('conclusion') not in PASSED and not job.get('runner_id') and not job.get('runner_name') and not job.get('steps')


def decision(jobs):
    """The jobs no runner took and the jobs that ran and failed, by name, among a finished attempt's `jobs`."""
    unrun = sorted(job['name'] for job in jobs if no_runner(job))
    failed = sorted(job['name'] for job in jobs
                    if job.get('conclusion') not in PASSED and not no_runner(job) and job['name'] not in REPORTS)
    return unrun, failed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repository', required=True, help='The repository, as owner/name.')
    parser.add_argument('--run', type=int, required=True, help='The ID of the run that failed.')
    parser.add_argument('--attempt', type=int, required=True, help='The attempt of it that failed.')
    parser.add_argument('--dry-run', action='store_true', help='Say what would happen without running anything again.')
    args = parser.parse_args()
    run = f'repos/{args.repository}/actions/runs/{args.run}'
    pages = json.loads(subprocess.run(['gh', 'api', '--paginate', '--slurp', f'{run}/attempts/{args.attempt}/jobs?per_page=100'],
                                      check=True, capture_output=True, text=True, timeout=120).stdout)
    unrun, failed = decision([job for page in pages for job in page['jobs']])
    if not unrun:
        print('Every job that failed had a runner.')
    elif failed:
        print(f'No runner took {", ".join(unrun)}, but {", ".join(failed)} ran and failed, so nothing is run again.')
    elif args.attempt >= LAST_ATTEMPT:
        print(f'No runner took {", ".join(unrun)} in attempt {args.attempt}, the last one made without being asked.')
    else:
        print(f'No runner took {", ".join(unrun)}. Running the failed jobs again as attempt {args.attempt + 1} of {LAST_ATTEMPT}.')
        if not args.dry_run:
            subprocess.run(['gh', 'api', '--method', 'POST', f'{run}/rerun-failed-jobs'], check=True, stdout=subprocess.DEVNULL, timeout=120)


if __name__ == '__main__':
    main()
