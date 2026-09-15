import base64
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify(root, manifest, artifact_size):
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("The feed must contain exactly one full release")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None or len(item.findall("enclosure")) != 1:
        raise ValueError("Missing or duplicate release enclosure")
    version = manifest["version"]
    expected_url = f"https://vault.lpm.dev/releases/v{version}/LPM-Vault-{version}.dmg"
    if enclosure.get("url") != expected_url:
        raise ValueError("Unexpected release URL")
    if item.findtext(SPARKLE + "version") != manifest["build"]:
        raise ValueError("Unexpected update build number")
    if item.findtext(SPARKLE + "shortVersionString") != version:
        raise ValueError("Unexpected update version")
    if item.findtext(SPARKLE + "minimumSystemVersion") != manifest["minimumSystemVersion"]:
        raise ValueError("Unexpected minimum macOS version")
    if enclosure.get("length") != str(artifact_size):
        raise ValueError("Incorrect archive length")
    signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)
    if len(signature) != 64:
        raise ValueError("Missing EdDSA archive signature")


if __name__ == "__main__":
    directory = Path(sys.argv[2])
    manifest = json.loads((directory / "release-manifest.json").read_text())
    artifact = directory / f"LPM-Vault-{manifest['version']}.dmg"
    verify(ET.parse(sys.argv[1]).getroot(), manifest, artifact.stat().st_size)
