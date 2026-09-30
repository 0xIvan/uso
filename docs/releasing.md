# Distribution checks

Private sharing uses `tools/package.sh --preview`; no Apple Developer
membership is needed to create that artifact. Recipients may need to approve
opening it in macOS Privacy & Security because it is not notarized.

For a future public release:

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
   publishing. The current repository does not grant an open-source license.

No public publishing or Apple submission occurs in preview mode.

Apple references:
- https://developer.apple.com/developer-id/
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
