import base64
import copy
from datetime import date
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
STABLE_VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
NIGHTLY_VERSION = STABLE_VERSION + r"-nightly\.([0-9]{8})\.([1-9][0-9]*)\.([0-9a-f]{7}|g0[0-9]{6})"
ET.register_namespace("sparkle", SPARKLE[1:-1])


def build_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,3}(\.(0|[1-9][0-9]?)){0,2}", value):
        raise ValueError("Invalid release build number")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def next_build(previous, floor):
    major, minor, patch = build_tuple(previous)
    patch += 1
    if patch == 100:
        minor, patch = minor + 1, 0
    if minor == 100:
        major, minor = major + 1, 0
    if major > 9999:
        raise ValueError("Release build sequence exhausted")
    result = f"{major}.{minor}.{patch}"
    return floor if build_tuple(floor) > build_tuple(result) else result


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(STABLE_VERSION, value):
        raise ValueError("Invalid numeric release version")
    return tuple(int(part) for part in value.split("."))


def nightly_version(stable, release_date, run_number, commit):
    major, minor, _ = version_tuple(stable)
    parsed = date.fromisoformat(release_date)
    if parsed.isoformat() != release_date or not re.fullmatch(r"[1-9][0-9]*", str(run_number)):
        raise ValueError("Invalid nightly date or run number")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid nightly source commit")
    version = f"{major}.{minor + 1}.0"
    token = commit[:7]
    if re.fullmatch(r"0[0-9]{6}", token):
        token = "g" + token
    return version, f"{version}-nightly.{parsed.strftime('%Y%m%d')}.{run_number}.{token}"


def validate_manifest(manifest, tag, prerelease):
    channel = manifest.get("channel", "stable")
    if channel not in ("stable", "nightly") or prerelease != (channel == "nightly"):
        raise ValueError("Release channel does not match GitHub prerelease status")
    version_tuple(manifest.get("version"))
    build_tuple(manifest.get("build"))
    release_version = manifest.get("releaseVersion", manifest["version"])
    if tag != "v" + release_version:
        raise ValueError("Release manifest does not match its tag")
    if channel == "nightly":
        match = re.fullmatch(NIGHTLY_VERSION, release_version)
        if not match or release_version.split("-nightly.")[0] != manifest["version"]:
            raise ValueError("Invalid nightly release version")
        release_date = manifest.get("releaseDate", "")
        if date.fromisoformat(release_date).strftime("%Y%m%d") != match[4]:
            raise ValueError("Nightly date does not match its tag")
        if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("sourceCommit", "")) or not manifest["sourceCommit"].startswith(match[6].removeprefix("g")):
            raise ValueError("Nightly commit does not match its tag")
    elif release_version != manifest["version"]:
        raise ValueError("Stable release cannot use a prerelease version")
    if manifest.get("bundleIdentifier") != "dev.lpm.vault" or manifest.get("teamIdentifier") != "823S8YKMRW":
        raise ValueError("Unexpected release application identity")
    if manifest.get("minimumSystemVersion") != "14.0":
        raise ValueError("Unexpected minimum macOS version")
    artifacts = manifest.get("artifacts", [])
    expected = {"dmg": f"LPM-Vault-{release_version}.dmg", "update-zip": f"LPM-Vault-{release_version}-macos-universal.zip"}
    if len(artifacts) != len(expected):
        raise ValueError("Unexpected release artifact inventory")
    for artifact in artifacts:
        if expected.pop(artifact.get("kind"), None) != artifact.get("file"):
            raise ValueError("Unexpected release artifact name")
        if type(artifact.get("size")) is not int or artifact["size"] <= 0 or not re.fullmatch(r"[0-9a-f]{64}", artifact.get("sha256", "")):
            raise ValueError("Invalid release artifact size or digest")
    return channel


def display_version(manifest):
    if manifest.get("channel", "stable") == "nightly":
        return f"{manifest['version']} Nightly · {manifest['releaseDate']} · {manifest['sourceCommit'][:7]}"
    return manifest["version"]


def verify_item(item, manifest):
    release_version = manifest.get("releaseVersion", manifest["version"])
    enclosure = item.find("enclosure")
    artifact = next(artifact for artifact in manifest["artifacts"] if artifact["kind"] == "dmg")
    expected = {SPARKLE + "version": manifest["build"], SPARKLE + "shortVersionString": display_version(manifest),
                SPARKLE + "minimumSystemVersion": manifest["minimumSystemVersion"]}
    for field, value in expected.items():
        if len(item.findall(field)) != 1 or item.findtext(field) != value:
            raise ValueError("Appcast metadata does not match release manifest")
    channels = item.findall(SPARKLE + "channel")
    if manifest.get("channel", "stable") == "nightly":
        if len(channels) != 1 or channels[0].text != "nightly":
            raise ValueError("Nightly update must be tagged with its channel")
    elif channels:
        raise ValueError("Stable update must use Sparkle's default channel")
    if enclosure is None or len(item.findall("enclosure")) != 1:
        raise ValueError("Missing or duplicate release enclosure")
    if enclosure.get("url") != f"https://vault.lpm.dev/releases/v{release_version}/{artifact['file']}" or enclosure.get("length") != str(artifact["size"]):
        raise ValueError("Unexpected appcast download URL or length")
    if len(base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)) != 64:
        raise ValueError("Invalid archive signature")


def decorate_feed(path, manifest):
    root = ET.parse(path).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Release feed must contain exactly one item")
    item = items[0]
    item.find(SPARKLE + "shortVersionString").text = display_version(manifest)
    if manifest.get("channel", "stable") == "nightly":
        ET.SubElement(item, SPARKLE + "channel").text = "nightly"
    verify_item(item, manifest)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def aggregate_feed(entries):
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "LPM Vault updates"
    ET.SubElement(channel, "link").text = "https://vault.lpm.dev/"
    seen = set()
    for manifest, feed in sorted(entries, key=lambda entry: build_tuple(entry[0]["build"]), reverse=True):
        items = ET.fromstring(feed).findall("./channel/item")
        if len(items) != 1 or manifest.get("channel", "stable") in seen:
            raise ValueError("Aggregate feed requires one full release per channel")
        seen.add(manifest.get("channel", "stable"))
        verify_item(items[0], manifest)
        channel.append(copy.deepcopy(items[0]))
    if not seen:
        raise ValueError("Cannot publish an empty update feed")
    if len({build_tuple(manifest["build"]) for manifest, _ in entries}) != len(entries):
        raise ValueError("Release build numbers collide across channels")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def api_optional(endpoint, environment):
    result = subprocess.run(["gh", "api", endpoint], env=environment, capture_output=True, text=True, check=False)
    if result.returncode == 0:
        return json.loads(result.stdout)
    if "HTTP 404" in result.stderr and result.stdout.strip() and json.loads(result.stdout).get("message") == "Not Found":
        return None
    raise RuntimeError("GitHub update-feed lookup failed")


def publish_feed(repository, entries, tools, temporary, run, output, environment):
    feed = temporary / "channels.xml"
    feed.write_bytes(aggregate_feed(entries))
    key = environment.get("SPARKLE_PRIVATE_KEY", "")
    if not key:
        raise ValueError("Missing Sparkle signing key")
    for verify in (False, True):
        run(str(tools / "bin/sign_update"), "--ed-key-file", "-", *(["--verify"] if verify else []), str(feed),
            input=key.encode(), stdout=subprocess.DEVNULL)
    ref = api_optional(f"repos/{repository}/git/ref/heads/updates", environment)
    parent = ref["object"]["sha"] if ref else None
    if parent:
        previous = json.loads(output("gh", "api", f"repos/{repository}/contents/appcast.xml?ref=updates"))
        if base64.b64decode(previous["content"]) == feed.read_bytes():
            return
    tree_file = temporary / "feed-tree.json"
    tree_file.write_text(json.dumps({"tree": [{"path": "appcast.xml", "mode": "100644", "type": "blob", "content": feed.read_text()}]}))
    tree = json.loads(output("gh", "api", "--method", "POST", f"repos/{repository}/git/trees", "--input", str(tree_file)))
    commit_file = temporary / "feed-commit.json"
    commit_file.write_text(json.dumps({"message": "Publish signed Vault update feed", "tree": tree["sha"], "parents": [parent] if parent else []}))
    commit = json.loads(output("gh", "api", "--method", "POST", f"repos/{repository}/git/commits", "--input", str(commit_file)))
    if parent:
        run("gh", "api", "--method", "PATCH", f"repos/{repository}/git/refs/heads/updates", "-f", f"sha={commit['sha']}", "-F", "force=false", stdout=subprocess.DEVNULL)
    else:
        run("gh", "api", "--method", "POST", f"repos/{repository}/git/refs", "-f", "ref=refs/heads/updates", "-f", f"sha={commit['sha']}", stdout=subprocess.DEVNULL)


def publish(repository, channel, tag, project, run, output, sign, environment):
    temporary = Path(environment["RUNNER_TEMP"]) / "vault-release-state"
    temporary.mkdir(exist_ok=True)
    commit = output("git", "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Invalid release source commit")
    pages = json.loads(output("gh", "api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100"))
    releases = [release for page in pages for release in page]
    latest = {}
    for release in sorted(releases, key=lambda value: value.get("published_at") or "", reverse=True):
        if release["draft"]:
            continue
        release_tag = release["tag_name"]
        if re.fullmatch("v" + STABLE_VERSION, release_tag):
            release_channel = "stable"
        elif re.fullmatch("v" + NIGHTLY_VERSION, release_tag):
            release_channel = "nightly"
        else:
            continue
        if release_channel not in latest:
            if release.get("immutable") is not True or release["prerelease"] != (release_channel == "nightly"):
                raise ValueError("Previous release must be immutable and match its channel")
            directory = temporary / release_tag
            directory.mkdir(exist_ok=True)
            run("gh", "release", "download", release_tag, "--repo", repository, "--pattern", "release-manifest.json", "--pattern", "appcast.xml", "--dir", str(directory), "--clobber")
            manifest = json.loads((directory / "release-manifest.json").read_text())
            validate_manifest(manifest, release_tag, release["prerelease"])
            latest[release_channel] = (release, manifest, directory)
    versions = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", project))
    builds = set(re.findall(r"CURRENT_PROJECT_VERSION = ([0-9.]+);", project))
    if len(versions) != 1 or len(builds) != 1:
        raise ValueError("Project must declare one version and build")
    version, floor = versions.pop(), builds.pop()
    if channel == "nightly":
        if environment.get("GITHUB_REF") != "refs/heads/main":
            raise ValueError("Nightly releases must run from main")
        created = json.loads(output("gh", "api", f"repos/{repository}/actions/runs/{environment['GITHUB_RUN_ID']}"))["created_at"]
        version, release_version = nightly_version(version, created[:10], environment["GITHUB_RUN_NUMBER"], commit)
        tag = "v" + release_version
        if "nightly" in latest:
            previous = latest["nightly"][0]["tag_name"]
            comparison = json.loads(output("gh", "api", f"repos/{repository}/compare/{previous}...{commit}"))
            if comparison["status"] not in ("identical", "ahead"):
                raise ValueError("Published nightly is not an ancestor of this source commit")
            if comparison["status"] == "identical":
                print("Current main already has a nightly; repairing feed publication if needed")
                tag = previous
    else:
        release_version = tag[1:]
        if version_tuple(release_version) != version_tuple(version):
            raise ValueError("Stable tag must match the project's version")
    existing = next((release for release in releases if release["tag_name"] == tag), None)
    if existing and existing["draft"]:
        raise ValueError("A release draft already exists; inspect and remove it before retrying")
    if not existing:
        if channel == "stable" and "nightly" in latest:
            previous = latest["nightly"][0]["tag_name"]
            comparison = json.loads(output("gh", "api", f"repos/{repository}/compare/{previous}...{commit}"))
            if comparison["status"] not in ("identical", "ahead"):
                raise ValueError("Published nightly must be an ancestor of a new stable release")
        if channel == "stable" and "stable" in latest and version_tuple(version) <= version_tuple(latest["stable"][1]["version"]):
            raise ValueError("Stable release version must increase")
        previous_build = max((value[1]["build"] for value in latest.values()), key=build_tuple, default=None)
        build = next_build(previous_build, floor) if previous_build else floor
        metadata = dict(channel=channel, releaseVersion=release_version, sourceCommit=commit,
                        releaseDate=created[:10] if channel == "nightly" else "")
        sign(version, build, metadata=metadata)
        directory = Path("release-output")
        manifest = json.loads((directory / "release-manifest.json").read_text())
        validate_manifest(manifest, tag, channel == "nightly")
        if any(manifest.get(field) != value for field, value in dict(metadata, version=version, build=build).items()):
            raise ValueError("Signed release metadata differs from publication plan")
        names = [f"LPM-Vault-{release_version}.dmg", f"LPM-Vault-{release_version}-macos-universal.zip",
                 "LPM-Vault.dmg", "appcast.xml", "checksums.txt", "release-manifest.json"]
        run("gh", "release", "create", tag, "--repo", repository, "--target", commit,
            *( ["--verify-tag"] if channel == "stable" else [] ), "--draft", "--title", f"LPM Vault {release_version}", "--generate-notes",
            *(str(Path("release-output") / name) for name in names))
        run("gh", "release", "edit", tag, "--repo", repository, "--draft=false",
            *( ["--prerelease", "--latest=false"] if channel == "nightly" else ["--latest"] ))
        published = json.loads(output("gh", "api", f"repos/{repository}/releases/tags/{tag}"))
        if published.get("tag_name") != tag or published.get("draft") is not False or published.get("immutable") is not True or published.get("prerelease") is not (channel == "nightly"):
            raise RuntimeError("Release publication did not confirm immutable protection and channel")
        latest[channel] = (published, manifest, directory)
    elif channel not in latest or latest[channel][0]["tag_name"] != tag:
        raise ValueError("Refusing to republish an obsolete release")
    tools = Path(environment["RUNNER_TEMP"]) / "vault-signing/sparkle"
    if not tools.exists():
        tools = temporary / "sparkle"
        run("bash", "LPMVault/Scripts/fetch-sparkle-tools.sh", str(tools))
    entries = []
    for _, manifest, directory in latest.values():
        feed = directory / "appcast.xml"
        run(str(tools / "bin/sign_update"), "--ed-key-file", "-", "--verify", str(feed),
            input=environment["SPARKLE_PRIVATE_KEY"].encode(), stdout=subprocess.DEVNULL)
        entries.append((manifest, feed.read_bytes()))
    publish_feed(repository, entries, tools, temporary, run, output, environment)
