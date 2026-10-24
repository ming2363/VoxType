# Building VoxType

Current app target: **Apple Silicon (arm64), macOS 15+**. Source uses Swift 6 tools, AppKit, SwiftUI and system zlib. The package manifest currently lists macOS 14, but the app Info.plist and manual compiler target require 15; use 15 as the application's minimum.

## Current local build

```bash
./Scripts/build-app.sh
```

Read the script before running it. It builds `dist/VoxType.app`, **replaces an existing `~/Applications/VoxType.app`**, creates/reuses a local signing identity under `~/.config/voxtype`, and temporarily adjusts the user keychain search list while signing. Never commit that signing directory or reuse somebody else's keys.

The script defaults to the Command Line Tools macOS 26.2 SDK. To select your SDK explicitly:

```bash
SDK="$(xcrun --sdk macosx --show-sdk-path)" ./Scripts/build-app.sh
```

`make-sdk-overlay.py` works around a specific local Swift 6.2.4 / SDK interface mismatch. It writes copies under `.build/`, without editing the system SDK. Compatibility on other toolchain combinations has not been established. Portable release building remains follow-up work.

With a compatible toolchain, `swift build -c release` / `swift test` are the standard SwiftPM entry points; they were **not verified successfully on the current development setup**. A SwiftPM executable is not an installed `.app` bundle.

## Distribution

The local certificate is not an Apple Developer ID and does not constitute Apple notarization. The current local build must not be described as a notarized public release. Source publication does not automatically make `dist/` suitable for release distribution.

Prepare any downloadable release with an intentional signing/notarization process, inspect the exact archive, include LICENSE and NOTICE, and verify on a clean Mac. This publication preparation does not replace the running app, change permissions or enable login startup.

## Tests

`Tests/RunCoreChecks/main.swift` provides standalone assertions without cloud calls or real credentials. `Tests/VoxTypeCoreTests` is the XCTest target. The standalone checks compile with the app's SDK/module settings and CGZip object; they require no signing or installation.

The optional [ASR benchmark](../benchmarks/README.md) is separate from ordinary tests and consumes provider usage when run.

`python3 Tests/check_clipboard_boundary.py` checks the source boundary that allows clipboard access only in the explicit Copy Last Result menu action. It does not inspect or modify your actual clipboard. Run it alongside the core assertions when changing text delivery.

`Tests/RunFloatingStatusChecks/main.swift` is an AppKit display regression using a fake model and the real `FloatingStatusController`. Compile those two files with the same SDK/module flags and linked VoxTypeCore/CGZip objects as the app. It briefly displays test indicators in an interactive Mac session, checks persistence beyond the 2.4-second timeout, stale dismissals, finishing, and nonactivating behavior. It never accesses the microphone, ASR, Keychain, clipboard or real input fields.
