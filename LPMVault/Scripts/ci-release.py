import base64
import json
import os
import re
import secrets
import shlex
import subprocess
from pathlib import Path


def run(*args, **kwargs):
    result = subprocess.run(args, check=False, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed with status {result.returncode}")
    return result


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def release_version(tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Release tags must use vMAJOR.MINOR.PATCH")
    return tag[1:]


def main():
    version = release_version(os.environ["GITHUB_REF_NAME"])
    repository = os.environ["GITHUB_REPOSITORY"]
    run("git", "fetch", "origin", "main")
    run("git", "merge-base", "--is-ancestor", "HEAD", "origin/main")
    repo = json.loads(output("gh", "api", f"repos/{repository}"))
    if repo["private"]:
        raise ValueError("Public update downloads require a public repository")
    if not json.loads(output("gh", "api", f"repos/{repository}/immutable-releases"))["enabled"]:
        raise ValueError("Enable immutable releases before publishing")
    # Xcode substitutes this value from the committed project settings.
    project = Path("LPMVault/LPMVault.xcodeproj/project.pbxproj").read_text()
    builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([0-9.]+);", project))
    if len(builds) != 1:
        raise ValueError("The project must declare one release build number")
    build = builds.pop()
    releases = json.loads(output("gh", "api", f"repos/{repository}/releases?per_page=100"))
    if any(release["tag_name"] == f"v{version}" for release in releases):
        raise ValueError("A release already exists for this tag")
    published = [release for release in releases if not release["draft"] and not release["prerelease"]]
    if published:
        latest = json.loads(output("gh", "api", f"repos/{repository}/releases/latest"))
        previous = Path(os.environ["RUNNER_TEMP"]) / "previous-vault-release"
        previous.mkdir()
        run("gh", "release", "download", latest["tag_name"], "--repo", repository,
            "--pattern", "release-manifest.json", "--dir", str(previous))
        manifest = json.loads((previous / "release-manifest.json").read_text())
        numeric = lambda value: tuple(int(part) for part in value.split("."))
        if numeric(version) <= numeric(manifest["version"]) or numeric(build) <= numeric(manifest["build"]):
            raise ValueError("Release version and build must both increase")
    required = ["APPLE_DEVELOPER_ID_P12_BASE64", "APPLE_DEVELOPER_ID_P12_PASSWORD",
                "APPLE_VAULT_PROVISIONING_PROFILE_BASE64", "APPLE_NOTARY_KEY_BASE64",
                "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID", "SPARKLE_PRIVATE_KEY"]
    for name in required:
        if not os.environ.get(name):
            raise ValueError(f"Missing Actions secret: {name}")
    directory = Path(os.environ["RUNNER_TEMP"]) / "vault-signing"
    directory.mkdir(mode=0o700)
    keychain = directory / "release.keychain-db"
    original_search = shlex.split(output("security", "list-keychains", "-d", "user"))
    try:
        paths = {}
        for name, filename in [("APPLE_DEVELOPER_ID_P12_BASE64", "identity.p12"),
                               ("APPLE_VAULT_PROVISIONING_PROFILE_BASE64", "vault.provisionprofile"),
                               ("APPLE_NOTARY_KEY_BASE64", "notary.p8")]:
            paths[name] = directory / filename
            paths[name].write_bytes(base64.b64decode(os.environ[name], validate=True))
            paths[name].chmod(0o600)
        password = secrets.token_urlsafe(32)
        run("security", "create-keychain", "-p", password, str(keychain))
        run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
        run("security", "unlock-keychain", "-p", password, str(keychain))
        run("security", "import", str(paths[required[0]]), "-k", str(keychain),
            "-P", os.environ["APPLE_DEVELOPER_ID_P12_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
        run("security", "list-keychains", "-d", "user", "-s", str(keychain), *original_search)
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain), stdout=subprocess.DEVNULL)
        environment = os.environ.copy()
        environment["LPM_VAULT_PROVISIONING_PROFILE"] = str(paths["APPLE_VAULT_PROVISIONING_PROFILE_BASE64"])
        environment["APPLE_NOTARY_KEY_PATH"] = str(paths["APPLE_NOTARY_KEY_BASE64"])
        run("bash", "LPMVault/release-app.sh", "--version", version, "--build", build,
            "--output-dir", "release-output", env=environment)
        run("bash", "LPMVault/Scripts/fetch-sparkle-tools.sh", str(directory / "sparkle"))
        run("bash", "LPMVault/Scripts/generate-appcast.sh", "release-output", str(directory / "sparkle"))
    finally:
        run("security", "list-keychains", "-d", "user", "-s", *original_search)
        subprocess.run(["security", "delete-keychain", str(keychain)], check=False)
        for path in directory.glob("*"):
            if path.is_file():
                path.unlink()
    artifacts = [f"LPM-Vault-{version}.dmg", f"LPM-Vault-{version}-macos-universal.zip",
                 "LPM-Vault.dmg", "appcast.xml", "checksums.txt", "release-manifest.json"]
    run("gh", "release", "create", f"v{version}", "--repo", repository, "--verify-tag",
        "--draft", "--title", f"LPM Vault {version}", "--generate-notes",
        *(str(Path("release-output") / name) for name in artifacts))
    run("gh", "release", "edit", f"v{version}", "--repo", repository, "--draft=false", "--latest")


if __name__ == "__main__":
    main()
