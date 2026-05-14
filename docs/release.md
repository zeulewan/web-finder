# Release Notes

This file captures release procedures that are easy to forget. Do not commit App Store Connect key IDs, issuer IDs, private key paths, or `.p8` filenames.

## Version Bump

Use the project script instead of editing versions by hand:

```bash
scripts/bump-version.sh X.Y.Z [IOS_BUILD]
```

It updates:

- `cli/package.json`
- `macos/Info.plist`
- `ios/WebFinder/Info.plist`
- `ios/WebFinder.xcodeproj/project.pbxproj`
- `docs/index.html`

iOS App Store uploads require a new `CFBundleVersion` for every upload. Public releases require a new `CFBundleShortVersionString`.

## GitHub Release

Use:

```bash
scripts/release.sh X.Y.Z [IOS_BUILD]
```

This bumps versions, commits, tags, pushes, and creates the GitHub release. Users then update with:

```bash
web-finder update
```

## iOS App Store Upload

`ios/build-ios.sh` creates an unsigned IPA for local/manual use. It is not the App Store upload path.

Preferred terminal upload:

```bash
export APP_STORE_CONNECT_KEY_PATH=/path/to/AuthKey_KEYID.p8
export APP_STORE_CONNECT_KEY_ID=KEYID
export APP_STORE_CONNECT_ISSUER_ID=ISSUER_UUID
scripts/archive-ios-appstore.sh X.Y.Z
```

The script archives the Release build, exports it for App Store Connect, and uploads it. `ios/exportOptions.plist` must keep `manageAppVersionAndBuildNumber` set to `false`; otherwise Xcode can silently auto-increment the uploaded build number and make local version tracking confusing.

If terminal upload fails with an App Store Connect credentials error, use Xcode Organizer with a signed-in Apple Developer account.

Manual Xcode upload path:

1. Open `ios/WebFinder.xcodeproj`.
2. Select the `WebFinder` scheme.
3. Select a generic physical-device destination such as `Any iOS Device`, not a simulator.
4. Run `Product > Archive`.
5. In Organizer, choose the archive, then `Distribute App`.
6. Choose `App Store Connect`, upload, and keep automatic signing/team `25QMAKVCBN`.

## iOS App Store Submission

After upload processing finishes, use:

```bash
scripts/submit-ios-appstore.py X.Y.Z
```

The script uses the same App Store Connect env vars as the upload script. It:

- Finds the App Store Connect app from bundle ID `com.zeul.webfinder.ios`.
- Creates the iOS App Store version if it does not exist.
- Selects the latest `VALID` and `APP_STORE_ELIGIBLE` uploaded build.
- Attaches that build to the version.
- Updates the `en-US` What's New text.
- Creates a review submission.
- Adds the app version as a review submission item.
- Submits it by patching the review submission with `submitted: true`.

To force a specific App Store Connect build number:

```bash
scripts/submit-ios-appstore.py X.Y.Z --build-number BUILD_NUMBER
```

To prepare metadata/build attachment without sending to review:

```bash
scripts/submit-ios-appstore.py X.Y.Z --no-submit
```

Useful App Store Connect states:

- `PREPARE_FOR_SUBMISSION`: version exists but is not ready.
- `READY_FOR_REVIEW`: version was added to a draft review submission.
- `WAITING_FOR_REVIEW`: submission was sent to Apple.
- `IN_REVIEW`: Apple is actively reviewing it.
- `READY_FOR_SALE`: approved and live.

Important API detail: the old `POST /v1/appStoreVersionSubmissions` path no longer creates submissions. Use the newer flow: `POST /v1/reviewSubmissions`, `POST /v1/reviewSubmissionItems`, then `PATCH /v1/reviewSubmissions/{id}` with `{"submitted": true}`.

## iOS Release Build Label

Release builds should not show the dev build label. The project uses `WFBuildKind`:

- Debug: `DEV`
- Release/App Store: `APPSTORE`

If the App Store build still shows a dev label, check `ios/WebFinder/Info.plist` and the build settings in `ios/WebFinder.xcodeproj/project.pbxproj`.

## Discovery Release Testing

When changing manifest, Tailscale Serve, or scanner behavior:

```bash
web-finder status
web-finder --json
web-finder
curl -k https://PEER_DNS:9321/.well-known/web-finder.json
```

Test from at least two devices. Compare CLI, macOS app, and iOS output. Remote devices should fetch Web Finder manifests from peers, not port-scan peers. A peer only appears with services after Web Finder is installed and `web-finder start` has run on that peer.
