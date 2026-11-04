# PocketAI for iPhone

PocketAI for iPhone is a SwiftUI iOS app for running AI models on device: chat, projects, model management, voice input and image generation, all local. It can also pair with a Mac running [PocketAI for Mac](https://github.com/liveshortly/PocketAI.Mac) on the same network (Bonjour discovery and a pairing code scanned with the camera) to use that Mac's models, and it can connect to a [LiveShortly](https://github.com/liveshortly/liveshortly-server) server to start and follow sessions.

## How the repos fit together

| Repo | What it is |
|------|------------|
| [PocketAI.Core](https://github.com/liveshortly/PocketAI.Core) | Rust core and shared Swift packages (`PocketKit`, `PocketUI`, `PocketMLX`, `PocketImageGen`, `PocketLiveShortly`). Required. |
| [PocketAI.Mac](https://github.com/liveshortly/PocketAI.Mac) | The macOS app this app pairs with. |
| [PocketAI.Iphone](https://github.com/liveshortly/PocketAI.Iphone) | This repo. |

`project.yml` references Core as a local package at `../PocketAI.Core`, so Core must be checked out as a sibling folder:

```
getpocketai/
├── PocketAI.Core
├── PocketAI.Mac      (optional for an iPhone build)
└── PocketAI.Iphone
```

```sh
mkdir getpocketai && cd getpocketai
git clone https://github.com/liveshortly/PocketAI.Core.git
git clone https://github.com/liveshortly/PocketAI.Iphone.git
```

The iPhone app talks to LiveShortly directly over HTTP through `PocketLiveShortly`; it does not use the `live` CLI. Hosting sessions with [`live`](https://github.com/liveshortly/live) is done on a Mac.

## Requirements

- A Mac with Apple Silicon (Core's XCFramework has arm64 slices only, including the simulator slice).
- Xcode with a Swift 6 toolchain and the iOS SDK. <!-- TODO(owner): state the exact Xcode version you build with. -->
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An iPhone on iOS 18.0 or later to run models. MLX does not run in the Simulator; the Simulator is fine for UI work.
- Everything PocketAI.Core needs to build its XCFramework (Rust via rustup plus the Apple targets, CMake). See the [Core README](https://github.com/liveshortly/PocketAI.Core#requirements).

## Build and run

1. Build Core's XCFramework (once, and again after Core's Rust code changes):
   ```sh
   cd ../PocketAI.Core && scripts/build-xcframework.sh
   ```
2. Set your signing team (see [Signing](#signing)), then generate the Xcode project. `PocketAI.xcodeproj` is generated from `project.yml` and is not committed; edit `project.yml`, never the project file.
   ```sh
   cd ../PocketAI.Iphone && xcodegen generate
   ```
3. Build and run. Open `PocketAI.xcodeproj` in Xcode and run the `PocketAI` scheme on a device or simulator, or:
   ```sh
   # Simulator
   xcodebuild -scheme PocketAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
   # Device
   xcodebuild -scheme PocketAI -destination 'id=<device UDID>' build
   ```
   Use any simulator name installed in your Xcode.

### Tests

```sh
xcodebuild test -scheme PocketAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The scheme runs the XCUITest suite in `UITests/`. Use `-destination 'id=<device UDID>'` to run on a device.

## Signing

`project.yml` has signing enabled with automatic signing and the maintainer's development team. To build for yourself:

1. In `project.yml`, set `DEVELOPMENT_TEAM` on both the `PocketAI` and `PocketAIUITests` targets to your own team ID.
2. Change `bundleIdPrefix` and the `PRODUCT_BUNDLE_IDENTIFIER` values (`com.getpocketai.app`, `com.getpocketai.app.uitests`) to identifiers you own.
3. The app uses the app group `group.com.getpocketai.app` (`Entitlements/PocketAI-dev.entitlements`); change it to a group under your team.
4. Run `xcodegen generate` again.

For a compile-only check without any team, pass `CODE_SIGNING_ALLOWED=NO`:

```sh
xcodebuild -scheme PocketAI -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

<!-- TODO(owner): consider replacing the hardcoded DEVELOPMENT_TEAM in project.yml with an empty value or an xcconfig override so contributors don't have to edit a tracked file. -->

TestFlight distribution is maintainer only. `scripts/sign-upload-local.sh` (with `ExportOptions-testflight.plist`) signs an unsigned archived `PocketAI.app` with an Apple Distribution certificate, packages an IPA and uploads it to TestFlight. It needs the maintainer's certificate, provisioning profile and App Store Connect API key, none of which are in this repo.

## Using a self-hosted LiveShortly server

Open **Settings → Integrations → LiveShortly**. The **Server** field defaults to `https://liveshortly.com`; replace it with your own [liveshortly-server](https://github.com/liveshortly/liveshortly-server) origin (for example `https://live.example.com`) and connect. If you type a host without a scheme, `https://` is assumed.

Connecting uses a device-code sign-in: the app shows a code and a button that opens the server's approval page. Once approved, the server URL and tokens are saved together in the Keychain, and sessions, hosts and live streams all come from that server. To switch servers, disconnect and connect again with a different URL.

The app declares no App Transport Security exceptions, so your server needs to be reachable over HTTPS with a certificate the iPhone trusts. <!-- TODO(owner): confirm whether a plain-HTTP LAN server is meant to be supported for self-hosting. -->

## Repo layout

| Path | Contents |
|------|----------|
| `Sources/` | App code. Top-level folders: `Chats`, `Devices` (Mac pairing and chat sync), `Diagnostics`, `Home`, `Intents`, `Models`, `Notifications`, `Onboarding`, `Permissions`, `Projects`, `Settings`, `Shared`, `SharedInbox`, `Voice`. |
| `ShareExtension/` | Share extension sources. <!-- TODO(owner): there is no ShareExtension target in project.yml, so this folder is not built. Add the target or remove the folder. --> |
| `Resources/` | String catalog and privacy manifest (`PrivacyInfo.xcprivacy`). |
| `Entitlements/` | Entitlements for the app (development and distribution) and the share extension. |
| `UITests/` | XCUITest suite. |
| `scripts/` | Maintainer TestFlight upload script. |
| `docs/` | Accessibility checklist and redesign notes. <!-- TODO(owner): docs/ holds internal redesign logs and agent notes; consider removing them before going public. --> |
| `project.yml` | XcodeGen project definition. |
| `ExportOptions-testflight.plist` | Export options for TestFlight builds (maintainer). |

## Contributing

- Edit `project.yml`, never `PocketAI.xcodeproj`, and do not commit the generated project.
- Use colors, fonts and spacing from `PocketUI` tokens rather than literals.
- Do networking only through PocketKit's networking layer.
- Give every view a `#Preview` (light, dark, and a large accessibility text size).
- Shared logic and UI components belong in PocketAI.Core; open the change there.

<!-- TODO(owner): add contribution terms (issues/PRs welcome? CLA?). The current LICENSE grants no rights to use or modify the code. -->

## License

Copyright (c) 2026 Rohit Sehgal. All rights reserved. This is proprietary software; see [`LICENSE`](LICENSE). Making the repository public does not grant any license to use, copy, modify or distribute it.

<!-- TODO(owner): a public repo keeps this proprietary "All rights reserved" license unless you change LICENSE. -->
