# Distribution checks

Private sharing uses `tools/package.sh --preview`; no Apple Developer
membership is needed to create that artifact. Recipients may need to approve
opening it in macOS Privacy & Security because it is not notarized.

For a public release:

1. Configure an Apple Developer ID Application certificate and a notarytool
   Keychain profile on the build Mac. Never commit signing keys or passwords.
2. Update the version and build number in `Info.plist` for each release.
3. Run `tools/package.sh --release` with `CODE_SIGN_IDENTITY` and
   `NOTARY_PROFILE` in the environment. Failure to sign, notarize, staple,
   validate, or pass Gatekeeper prevents a new release artifact being emitted.
4. Download the resulting DMG onto a different Mac using a browser. Confirm
   copying into Applications and opening succeeds with Gatekeeper enabled.
5. Verify no-login guidance, a real account's live usage, refresh, offline
   behavior, login startup, quit, replacement updates, and removal. Verify
   Intel hardware and the minimum macOS version before claiming them tested;
   compiling both architectures is not equivalent to running on both.
6. Choose publisher/contact details and distribution/license terms before
   publishing. The compiled app is free to use; source rights are retained under LICENSE.

No public publishing or Apple submission occurs in preview mode.

Apple references:
- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow

## 0.2.2 release status

- Claude token renewal and credential writes have been removed. Both providers'
  credential stores are read-only.
- Installation and privacy instructions describe live-only readings.
- Claude monitoring remains enabled by the maintainer's decision. Permission
  under Anthropic's subscription credential policy remains unresolved and is
  disclosed in the README and bundled installation instructions.
- Support: https://github.com/0xIvan/uso/issues
- Distribution: compiled app free to use; source rights retained under LICENSE.
- The accepted 0.2.1 app submission predates these fixes; do not publish it as 0.2.2.
- A downloaded install on another Mac, live account readings, offline recovery,
  login startup, replacement updates, and removal still require manual verification.
  Intel and macOS 13 execution have not been verified here.

Verified on 2026-10-14:

- Universal 0.2.2 (build 5) compiled and passed 29 self-checks.
- App submission `49662618-285d-454d-9a51-15f8072e23a0`: Accepted.
- DMG submission `0c38219b-9198-4058-8cbb-fcab8d6d0773`: Accepted.
- Both tickets stapled and validated; app and DMG passed Gatekeeper assessment.
- Final image integrity and SHA-256 verification passed.
- Mounted DMG app signature, both architectures, bundled documentation and
  license contents, and all 29 self-checks passed.
- Final artifact: `dist/Uso-0.2.2-universal.dmg` and its `.sha256` file.
- The updated app started locally, but computer-use could not inspect its UI.
  This does not replace the outstanding manual checks above.

## GitHub Actions

The repository default branch is `main`. Build checks run on pushes to `main`
and pull requests. `.github/workflows/release.yml` runs only for version tags;
ordinary pushes do not create releases.

Repository Actions secrets:

- `APPLE_CERTIFICATE_BASE64`: Base64-encoded Developer ID Application P12,
  including the private key.
- `APPLE_CERTIFICATE_PASSWORD`: P12 export password.
- `APPLE_ID`: Apple account used for notarization.
- `APPLE_TEAM_ID`: Developer team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: Apple app-specific password for notarization.
- `SPARKLE_PRIVATE_KEY`: Sparkle Ed25519 private signing key, exported by
  `generate_keys --account uso-sparkle -x PATH`. Keep a secure backup; it must
  match `SUPublicEDKey` in Info.plist. It is separate from Apple code signing.

The release runner imports the certificate into a temporary Keychain, validates
notarization credentials, and calls `tools/package.sh --release`. Certificate
material is removed during cleanup; GitHub-hosted runners are destroyed after
execution. Secrets are never committed and are not used for pull-request builds.

For a release:

1. Update `docs/release-notes.md`, then commit and push the reviewed application
   and documentation changes to the default branch (`main`).
2. Run `tools/release.sh --dry-run` to preview the next patch release. Run
   `tools/release.sh` to bump the version and build number, commit only
   `Info.plist`, and atomically push the default branch and annotated tag.
   Use `tools/release.sh minor`, `tools/release.sh major`, or an explicit
   version such as `tools/release.sh 0.3.0` when needed. Each increments the
   build number by one. The command requires a clean checkout on origin's
   default branch, exactly matching the remote, and refuses an existing tag.
3. Watch the Release workflow. Only after signing, notarization, stapling,
   Gatekeeper, and image verification succeed does it attach the DMG and checksum
   and the signed `appcast.xml` to a draft GitHub Release. Source ZIP/TAR archives
   are not the app installer.
4. Download the attached DMG and complete the manual checks above. Publish the
   draft when ready; the release Assets section then provides public downloads.

For a failed run, inspect its log and fix the specific failure. The Release
workflow can be rerun against the same tag if the source does not need changes;
manual workflow dispatch must select that tag. A rerun can replace assets on a
draft, but refuses to overwrite an already published release. If source changes
are needed, use a new version/tag rather than moving an existing release tag.

If the helper's push fails, its release commit and tag stay local for recovery.
Follow the printed retry command after resolving the remote error; do not rerun
the helper and accidentally bump to another version. The atomic push ensures
that the branch and release tag are either both accepted or both rejected.
The helper does not publish the draft or change GitHub signing secrets.

## Sparkle updates

`tools/sparkle.sh` fetches the pinned Sparkle distribution and verifies its SHA-256
before extraction. `tools/build.sh` embeds Sparkle, signs its nested helpers from
the inside out, preserves XPC entitlements, and signs the framework and outer app.
Ad-hoc previews omit hardened runtime so library validation does not block the
framework; Developer ID releases retain hardened runtime and secure timestamps.

After `tools/package.sh --release` produces the final notarized DMG, run
`tools/appcast.sh` to generate its signed feed. Locally this uses the Keychain
account `uso-sparkle`; CI supplies `SPARKLE_PRIVATE_KEY` over stdin. Never put
private keys in the repository or process arguments. The final DMG must not be
modified after generating its Sparkle signature. `tools/verify-appcast.swift`
checks the version, build, URL, size, and archive signature against the embedded
public key before the generated feed can replace the previous file. Sparkle's license is included
inside the application bundle.

Each draft contains its own `appcast.xml`, with a version-specific DMG URL.
Publishing the stable release makes that file available through
`https://github.com/0xIvan/uso/releases/latest/download/appcast.xml`.
The app does not poll GitHub APIs or offer draft/prerelease updates. Do not mark a
lower version as latest, and retain published release assets for existing clients.
There is no separate feed-deployment job and no private feed-hosting credentials.

Manual update verification before publishing the first Sparkle-enabled release:

1. Install it manually; previous versions cannot gain Sparkle remotely.
2. Check that the button in Settings opens Sparkle's UI and that a repeated check is
   disabled while the first is in progress.
3. For a controlled update test, use a temporary older and newer app with a
   signed test feed; never redirect normal users to test releases.
4. Verify download, signature validation, replacement, relaunch, and retained
   preferences from an app copied to Applications. Complete this again against
   published notarized builds when available. Until the first Sparkle release
   is published, the production feed URL returns no feed.
