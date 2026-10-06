#!/usr/bin/env python3
"""Verify the engine bundle and optionally reproduce it from its public revision."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

REPOSITORY = 'https://github.com/lpm-dev/rust-client'
TARGETS = ['aarch64-apple-darwin', 'x86_64-apple-darwin']


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(256 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def verify(bundle):
    provenance = json.loads((bundle / 'provenance.json').read_text())
    if provenance['repository'] != REPOSITORY or not re.fullmatch(r'[0-9a-f]{40}', provenance['revision']):
        raise ValueError('Engine provenance must pin a public Rust revision')
    if provenance['abiVersion'] != 1 or provenance['toolchain'] != '1.94.0' or provenance['targets'] != TARGETS:
        raise ValueError('Unsupported engine ABI, toolchain, or architectures')
    actual = {str(path.relative_to(bundle)): digest(path) for path in (bundle / 'LPMEnv.xcframework').rglob('*') if path.is_file()}
    if actual != provenance['artifacts']:
        raise ValueError('Engine files differ from their recorded hashes')
    for path, checksum in provenance['sources'].items():
        if Path(path).is_absolute() or '..' in Path(path).parts or not re.fullmatch(r'[0-9a-f]{64}', checksum):
            raise ValueError('Invalid engine source manifest')
    return provenance


def reproduce(bundle, provenance, target):
    with tempfile.TemporaryDirectory(prefix='lpm-env-verify-') as temporary:
        root = Path(temporary) / 'source'
        subprocess.run(['git', 'init', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'fetch', '--depth=1', REPOSITORY, provenance['revision']], check=True)
        subprocess.run(['git', '-C', str(root), 'checkout', '--detach', 'FETCH_HEAD'], check=True)
        for relative, checksum in provenance['sources'].items():
            if digest(root / relative) != checksum:
                raise ValueError('Source provenance does not match its pinned revision: ' + relative)
        output = Path(temporary) / 'rebuilt'
        subprocess.run(['python3', str(root / 'scripts/export-env-engine.py'), '--target-dir', str(target), '--output', str(output)], check=True)
        rebuilt = verify(output)
        if rebuilt != provenance:
            raise ValueError('Rebuilt engine differs from the committed bundle')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=Path(__file__).resolve().parents[1] / 'Vendor/EnvEngine')
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--target-dir', type=Path)
    args = parser.parse_args()
    provenance = verify(args.bundle)
    if args.rebuild:
        if args.target_dir is None:
            parser.error('--rebuild requires --target-dir')
        reproduce(args.bundle, provenance, args.target_dir)
    print('Engine ABI, source provenance, and artifact hashes verified')


if __name__ == '__main__':
    main()
