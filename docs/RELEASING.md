# Releasing Everest for Mac

A release runs from a Mac, not from CI: the repository is public, its runner is
self-hosted, and the signing secrets stay off it. It needs the Developer ID
identity and the `macos-release-notary` profile (`vps-infra/docs/agents-secrets.md`,
"Signer et notariser depuis un autre Mac"), an `infisical login`, and the keyboard
plugged in for `selftest`.

## Publish a version

1. Set `AppVersion.number` in `Sources/everest/Version.swift`. Sparkle compares the
   build (the commit count), so publish from `main`, never from an older commit.
2. Write `ReleaseNotes/<version>.json`, and commit.
3. Run:

```sh
scripts/release.sh               # tests, selftest, build, notarize, DMG, appcast; uploads nothing
scripts/update-test.sh           # a real update from an old build to this code
scripts/update-test.sh --clean
SKIP_BUILD=1 scripts/release.sh --publish
```

4. Attach `dist/Everest-<version>.dmg` to a GitHub release, tagged `v<version>`.

For a risky version, `PHASED_ROLLOUT_INTERVAL=86400` spreads the update over seven
days: it reaches every keyboard, and pictures use the firmware-update mechanism.

## Where things are

| What | Where |
|---|---|
| Downloads | R2 bucket `mrrcalendar-downloads`, prefix `everest/`, served at `https://downloads.mrrcalendar.com/everest-mac/` |
| Update feed | `everest/appcast.xml` (5 minutes of cache), read by `SUFeedURL` |
| Website manifest | `everest/latest.json`, read by `mrrcalendar.com/everest-mac` |
| Download link | `https://mrrcalendar.com/everest-mac/download`: counts, then redirects to the DMG |
| Private signing key | Infisical `agents`, `prod`, `/apple`, `SPARKLE_ED_PRIVATE_KEY_EVEREST_MAC` |
| Public signing key | `SPARKLE_PUBLIC_KEY` in `make-app.sh` |

**Never regenerate the signing key**: installed apps would refuse every update
signed with another one. `scripts/create-update-key.sh` ran once and refuses to
replace it.

## What the build contains

`./make-app.sh --release` builds arm64 and x86_64 into one binary, embeds
`Sparkle.framework` without its XPC services (they are for sandboxed apps), and
signs from the inside out with the hardened runtime and a secure timestamp. No
entitlement is needed.
