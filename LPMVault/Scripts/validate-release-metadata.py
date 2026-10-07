import plistlib
from pathlib import Path
import re
import sys

from release_channels import NIGHTLY_VERSION, build_tuple
from datetime import date


def validate(version, build, channel, release_version, release_date, commit):
    if not re.fullmatch(r'(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,2}', version):
        raise ValueError('Invalid numeric release version')
    build_tuple(build)
    if channel not in ('stable', 'nightly'):
        raise ValueError('Invalid release channel')
    if commit and not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid release source commit')
    if channel == 'nightly':
        match = re.fullmatch(NIGHTLY_VERSION, release_version)
        if not match or release_version.split('-nightly.')[0] != version:
            raise ValueError('Invalid nightly version')
        if date.fromisoformat(release_date).isoformat() != release_date or date.fromisoformat(release_date).strftime('%Y%m%d') != match[4]:
            raise ValueError('Invalid nightly date')
        if len(commit) != 40 or not commit.startswith(match[6].removeprefix('g')):
            raise ValueError('Nightly commit does not match its tag')
    elif release_version != version or release_date:
        raise ValueError('Stable metadata must use its numeric version and no nightly date')
    return dict(LPMReleaseChannel=channel, LPMReleaseVersion=release_version, LPMReleaseDate=release_date, LPMReleaseCommit=commit)


if __name__ == '__main__':
    metadata = validate(*sys.argv[1:7])
    if len(sys.argv) == 8:
        path = Path(sys.argv[7])
        info = plistlib.loads(path.read_bytes())
        info.update(metadata)
        path.write_bytes(plistlib.dumps(info))
