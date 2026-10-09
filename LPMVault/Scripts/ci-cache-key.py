#!/usr/bin/env python3
"""Identify compatible CI build caches without skipping builds or verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def fingerprint(root, files):
    digest = hashlib.sha256()
    for path in sorted(set(files)):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(b'\0')
        with path.open('rb') as source:
            for chunk in iter(lambda: source.read(256 * 1024), b''):
                digest.update(chunk)
        digest.update(b'\0')
    return digest.hexdigest()


def cache_files(kind, root):
    common = [root / '.github/workflows/ci.yml', root / 'LPMVault/Scripts/ci-cache-key.py',
              root / 'LPMVault/Vendor/EnvEngine/provenance.json']
    if kind == 'engine':
        inputs = common + [root / 'LPMVault/Scripts/verify-env-engine.py']
        sources = inputs
    elif kind == 'swift':
        inputs = common + [root / 'LPMVault/Package.swift', root / 'LPMVault/Package.resolved']
        sources = [p for folder in ['Sources', 'Tests']
                   for p in (root / 'LPMVault' / folder).rglob('*') if p.is_file()]
    elif kind == 'release':
        project = root / 'LPMVault/LPMVault.xcodeproj'
        inputs = common + [project / 'project.pbxproj', root / 'LPMVault/Info.plist']
        inputs += [p for p in project.rglob('*') if p.is_file() and
                   (p.suffix == '.xcscheme' or p.name == 'Package.resolved')]
        sources = [p for p in (root / 'LPMVault/Sources').rglob('*') if p.is_file()]
        sources += [p for p in (root / 'LPMVault').glob('*') if p.suffix in ['.entitlements', '.xcconfig']]
    else:
        raise ValueError('Unknown cache kind: ' + kind)
    return inputs, sources


def cache_identity(kind, root, toolchain):
    inputs, sources = cache_files(kind, root)
    environment = hashlib.sha256(toolchain.encode()).hexdigest()
    prefix = f'vault-{kind}-v1-{environment}-{fingerprint(root, inputs)}-'
    return prefix, prefix + fingerprint(root, sources)


def timestamp_inputs(kind, root):
    inputs, sources = cache_files(kind, root)
    engine = root / 'LPMVault/Vendor/EnvEngine/LPMEnv.xcframework'
    return set(inputs + sources + [path for path in engine.rglob('*') if path.is_file()])


def source_times(kind, root, restore):
    folder = {'swift': root / 'LPMVault/.build', 'release': root / 'build-check'}[kind]
    metadata = folder / 'ci-source-times.json'
    if restore:
        try:
            saved = json.loads(metadata.read_text())
        except (OSError, ValueError):
            return 0
        if not isinstance(saved, dict) or saved.get('version') != 1 or not isinstance(saved.get('files'), dict):
            return 0
        restored = 0
        for path in timestamp_inputs(kind, root):
            record = saved['files'].get(str(path.relative_to(root)))
            if not isinstance(record, dict) or type(record.get('mtime_ns')) is not int or record['mtime_ns'] < 0:
                continue
            if not isinstance(record.get('hash'), str) or not re.fullmatch(r'[0-9a-f]{64}', record['hash']):
                continue
            status = path.stat()
            if fingerprint(root, [path]) == record['hash']:
                os.utime(path, ns=(status.st_atime_ns, record['mtime_ns']))
                restored += 1
            elif status.st_mtime_ns <= record['mtime_ns']:
                os.utime(path, ns=(status.st_atime_ns, max(time.time_ns(), record['mtime_ns'] + 2_000_000_000)))
        return restored
    records = {str(path.relative_to(root)): {'hash': fingerprint(root, [path]), 'mtime_ns': path.stat().st_mtime_ns}
               for path in timestamp_inputs(kind, root)}
    folder.mkdir(parents=True, exist_ok=True)
    metadata.write_text(json.dumps({'version': 1, 'files': records}) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['swift', 'release', 'engine'])
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--github-output', type=Path)
    action.add_argument('--record-source-times', action='store_true')
    action.add_argument('--restore-source-times', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if args.record_source_times or args.restore_source_times:
        if args.kind == 'engine':
            parser.error('Source timestamps apply to Swift and release builds')
        restored = source_times(args.kind, root, args.restore_source_times)
        print(f'Restored {restored} unchanged build inputs.' if args.restore_source_times else 'Recorded build input hashes and timestamps.')
        return
    identity = [platform.machine()]
    for command in [['sw_vers', '-buildVersion'], ['xcodebuild', '-version'],
                    ['xcrun', '--show-sdk-build-version'], ['swift', '--version']]:
        identity.append(subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip())
    prefix, key = cache_identity(args.kind, root, '\n'.join(identity))
    with args.github_output.open('a') as output:
        output.write(f'prefix={prefix}\nkey={key}\n')


if __name__ == '__main__':
    main()
