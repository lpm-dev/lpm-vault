#!/usr/bin/env python3
"""Identify compatible CI build caches without skipping builds or verification."""
import argparse
import hashlib
from pathlib import Path
import platform
import subprocess


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


def cache_identity(kind, root, toolchain):
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
    environment = hashlib.sha256(toolchain.encode()).hexdigest()
    prefix = f'vault-{kind}-v1-{environment}-{fingerprint(root, inputs)}-'
    return prefix, prefix + fingerprint(root, sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind', choices=['swift', 'release', 'engine'])
    parser.add_argument('--github-output', type=Path, required=True)
    args = parser.parse_args()
    identity = [platform.machine()]
    for command in [['sw_vers', '-buildVersion'], ['xcodebuild', '-version'],
                    ['xcrun', '--show-sdk-build-version'], ['swift', '--version']]:
        identity.append(subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip())
    root = Path(__file__).resolve().parents[2]
    prefix, key = cache_identity(args.kind, root, '\n'.join(identity))
    with args.github_output.open('a') as output:
        output.write(f'prefix={prefix}\nkey={key}\n')


if __name__ == '__main__':
    main()
