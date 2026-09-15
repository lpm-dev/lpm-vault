import base64
import plistlib
import sys
from pathlib import Path

PUBLIC_KEY = "g8YlEsyut4fJ+dnO/FdFrD/AicRACq9FjZbHm8PClUs="
FEED_URL = "https://vault.lpm.dev/updates/appcast.xml"


def verify(config):
    expected = {
        "SUFeedURL": FEED_URL,
        "SUPublicEDKey": PUBLIC_KEY,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUAutomaticallyUpdate": False,
        "SUSendProfileInfo": False,
    }
    for key, value in expected.items():
        if type(config.get(key)) is not type(value) or config[key] != value:
            raise ValueError(f"Invalid release update setting: {key}")
    if len(base64.b64decode(config["SUPublicEDKey"], validate=True)) != 32:
        raise ValueError("Invalid Sparkle public key")


if __name__ == "__main__":
    verify(plistlib.loads(Path(sys.argv[1]).read_bytes()))
