# PocketAI for iPhone

SwiftUI app. Shared code lives in ../PocketAI.Core/swift (PocketKit, PocketUI, PocketMLX).
Design spec: ../strategy/02-design-system.md. Tasks: ../strategy/05-tasks-apple.md §L5.

## Build & test
- Build Core first: `cd ../PocketAI.Core && scripts/build-xcframework.sh`
- Generate project: `xcodegen generate`
- Build (sim, Preview mode works; MLX does not run in Simulator):
  `xcodebuild -scheme PocketAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Tests: `xcodebuild test -scheme PocketAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- Device: `xcodebuild test -scheme PocketAI -destination 'id=<UDID>'`

## Rules
- Never edit PocketAI.xcodeproj by hand; edit project.yml.
- Colors, fonts, spacing only from PocketUI tokens.
- Networking only through PocketKit Net/Peer.
- Every view has #Preview (light, dark, AX3) and a snapshot test.
