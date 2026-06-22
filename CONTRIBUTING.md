# Contributing to Meeting Minutes

Thanks for your interest! This is a native macOS app (Swift + SwiftUI) that
records meetings, transcribes them locally with whisper.cpp, and generates AI
minutes via the Claude API.

## Getting set up

**Requirements:** macOS 14+, Xcode 16 or later (developed against Xcode 26),
Apple Silicon recommended.

```sh
git clone <your fork>
cd meeting-minutes
cp Local.xcconfig.example Local.xcconfig   # set your DEVELOPMENT_TEAM
open MeetingMinutes.xcodeproj
```

Select the **MeetingMinutes** scheme and Run (⌘R). On first launch you'll be
guided through Microphone and Screen Recording permissions. See the
[Troubleshooting](README.md#troubleshooting) section if permissions misbehave.

Or, to just build and install the app without Xcode (no Apple account needed):

```sh
./scripts/install.sh   # builds Release, installs to /Applications
```

To build from the command line (how CI builds it):

```sh
xcodebuild -project MeetingMinutes.xcodeproj -scheme MeetingMinutes \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Project layout

```
MeetingMinutes/
├── App/             SwiftUI entry point
├── Capture/         Mic + system-audio capture (AVAudioEngine + ScreenCaptureKit)
├── Transcription/   whisper.cpp transcriber, model download, audio decode/merge
├── Minutes/         Claude API client, Keychain storage, minutes generation
├── Permissions/     Microphone + Screen Recording permission tracking
├── Models/          Shared data types
└── Views/           SwiftUI views
```

The Xcode project uses **synchronized folder groups**, so new `.swift` files
added under `MeetingMinutes/` are picked up automatically — no need to edit the
project file.

## Roadmap

- [x] Phase 1 — Capture (two-track recording)
- [x] Phase 2 — Transcription (local whisper.cpp)
- [x] Phase 3 — Minutes (Claude API)
- [ ] **Phase 4 — Library:** browse / search / play past meetings (SQLite)
- [ ] Phase 5 — Polish & packaging (notarized release, app icon)

## Guidelines

- **Match the surrounding code.** Follow the existing naming, structure, and
  comment density rather than introducing new conventions.
- **Keep it dependency-light.** Prefer the standard library and system
  frameworks; discuss before adding a new Swift package.
- **Privacy first.** Audio and transcripts stay on-device. Don't add telemetry
  or send data anywhere without an explicit, opt-in setting.
- **Never commit secrets.** API keys live in the Keychain; `Local.xcconfig`
  (your team ID) is git-ignored.
- Make sure `xcodebuild … build` passes before opening a PR.

## Reporting issues

Include your macOS and Xcode versions, and for permission problems the output of
`codesign -dvv <built .app>` (the `Authority`/`TeamIdentifier` lines).
