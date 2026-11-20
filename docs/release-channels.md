# Release channels

## Release behavior

A stable release is started by hand from `main` with its version, which must match `MARKETING_VERSION` in the Xcode project. The workflow creates its `vMAJOR.MINOR.PATCH` tag.
The nightly workflow runs from `main` at 03:37 UTC. A manual run without a version also publishes a nightly from `main`.
Both paths run the repository CI before they sign, notarize, and publish the app.

A nightly tag has this form: `v1.1.0-nightly.20261007.42.abcdef0`.
The numeric version uses the next minor version from the Xcode project.
The tag also records the workflow creation date in UTC, the workflow run number, and the source commit.
A numeric commit prefix with a leading zero uses a `g` prefix to preserve valid SemVer.
The bundle keeps numeric Apple version fields. Separate signed bundle metadata supplies the channel, date, and source commit.

Stable and nightly releases share the build sequence in `CFBundleVersion`.
The publisher reads the latest immutable release manifest for each channel across all GitHub release pages.
It selects the next build after the highest published build, with the committed project build as the minimum.
For example, build `6` becomes `6.0.1`, then `6.0.2`. Build `6.99.99` becomes `7.0.0`.
One workflow concurrency group serializes both channels. Separate counters cannot overwrite the build order.

Nightly releases use GitHub prerelease status and never become the latest stable release.
The existing `/download` and `/updates/appcast.xml` routes continue to serve the latest stable release.
No tag starts a release run. The workflow creates each tag at the commit it built, just before it creates the release.

## Signed channel feed

New installations use `https://vault.lpm.dev/updates/channels.xml`.
This route redirects to `appcast.xml` on the generated `updates` branch.
The branch contains the signed feed only. It contains no application source or signing material.

The feed contains the latest stable release and the latest nightly release, ordered by build number.
Stable entries use Sparkle's default channel. Nightly entries use `<sparkle:channel>nightly</sparkle:channel>`.
Sparkle excludes nightly entries unless the person selects Nightly.
Nightly installations can also receive a newer stable build, even if its display version has a lower minor number.

The publisher signs and checks each release feed and the combined feed with the pinned Sparkle tools.
It updates the feed branch only after GitHub reports the release as published, immutable, and in the correct channel.
The branch update uses a normal forward update. A conflicting update fails instead of replacing another publication.
Failed signing or publication leaves the public feed unchanged.

## First deployment

1. Merge the reviewed implementation after its current commit passes CI.
2. Deploy the updated Vault web image before the first release with the new feed URL.
3. Run **Signed release** manually from `main`, or wait for the nightly schedule.
4. Check that the release has prerelease status and immutable protection.
5. Check that `/updates/channels.xml` serves a signed feed with the expected nightly entry.
6. Check that `/download` still redirects to the stable installer.

The workflow reads the Apple signing, provisioning, notarization and Sparkle secrets from the `release` environment, which only `main` can use.
Its `contents: write` permission also permits the generated feed branch update.
The generated `updates` branch must permit forward updates from the release workflow.
The implementation does not publish from a pull request or write generated artifacts to `main`.

## Recovery

If a release fails before publication, read its workflow logs before another run.
If an unpublished draft remains, inspect its artifacts before you delete the draft.
The publisher refuses to overwrite an existing draft or immutable release.

If feed publication fails after release publication, rerun that workflow run.
The publisher reuses the published release and rebuilds the combined signed feed.
Each release that enters the feed must have its tag on the commit its manifest records. A release whose tag points elsewhere stops feed publication; see RELEASING.md for recovery.
It does not rebuild the app or replace immutable artifacts.
If `main` still matches the published nightly, a scheduled run also repairs the feed without another release.
Every new release must contain the source of the latest published stable and nightly releases.
The publisher compares release tags, including stable tags with legacy manifests.
This rule prevents a higher build number from sending nightly users back to older source code.
Feed recovery reuses existing artifacts even when another channel has newer source.

A stable release builds the commit `main` pointed at when the run was started, so check the run's commit.
To recover a failed stable release, rerun that run instead of starting a new one. A new run builds the current `main`, and refuses once the project's version has moved on.
A tag at another commit without its release stops the release until you delete the tag.

If signing credentials expire, replace the affected secret in the `release` environment before the next run.
Release failure keeps the previous feed and stable installer available.

## Regression coverage

The Swift tests cover the installed version, initial channel, saved choice, sign-in states, and channel picker actions.
They also cover the waiting message after a nightly installation selects Stable.
Active sessions and retained downloads keep channel selection unavailable while manual checks remain available.
Prepared installer state survives app launches until installation, Skip, or terminal recovery.
Native callback tests cover deferred downloads, authorization delays, automatic installation, and installer recovery.
Each prepared installer has a generation identifier. A cycle resolves only its observed or prepared generation.
Separate resolution keys prevent stale callbacks from clearing a newer installer record or reopening a resolved record.
The release tests cover shared build order, tag metadata, legacy manifests, pagination, unchanged commits, and publication failures.
A real Sparkle signing test checks the combined feed and rejects modified content.
The nginx tests cover the channel feed, immutable nightly downloads, and the existing stable routes.
