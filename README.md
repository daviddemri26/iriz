# Iriz

Iriz is a native, local-first macOS contextual memory. It watches for meaningful changes on the active screen, can segment ambient speech, and turns evidence into a searchable journal of actions and follow-ups.

Public repository: [github.com/daviddemri26/iriz](https://github.com/daviddemri26/iriz)

## Current implementation

- Native SwiftUI application with an AppKit floating capsule.
- macOS 15 minimum, Swift 6, no required third-party runtime.
- ScreenCaptureKit capture with local frame differencing and Vision OCR.
- Accessibility-based active-window and browser URL adapters.
- Ambient microphone capture with local silence suppression and WAV segmentation; system audio is captured as a separate track during detected meetings.
- Optional 2–10 second voice enrollment stored in Keychain and sent only as the `You` reference for diarized meeting transcription.
- OpenAI Responses and Transcriptions clients using a user-provided API key stored in Keychain.
- Local SQLite FTS5 index. The live database is held in memory and serialized into an AES-GCM encrypted file, so event text is not left as a plaintext SQLite file on disk.
- AES-GCM encrypted media with 24-hour cleanup.
- Journal, Follow Up, text assistant, Settings, onboarding, retention, exclusions, launch-at-login controls, and warned JSON/Markdown exports without raw media.
- Standalone and future Setapp distribution adapters.

The packaged personal build does not contain an API key. Enter one in **Settings → OpenAI**. Tests do not call OpenAI.

## Build and test

```sh
SWIFT_MODULECACHE_PATH=/tmp/iriz-swift-cache \
CLANG_MODULE_CACHE_PATH=/tmp/iriz-swift-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/iriz-swift-cache \
swift test --disable-sandbox
```

Run from Xcode by opening `Package.swift`, or use `swift run Iriz`.

## Package

```sh
./Scripts/package_app.sh
```

The script builds a Universal `arm64`/`x86_64` `build/Iriz.app`, applies an ad-hoc signature when no Developer ID identity is supplied, validates the bundle, and creates `build/Iriz.zip`.

For direct release distribution, first save notary credentials with `notarytool`, then run:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="iriz-notary" \
./Scripts/package_app.sh
```

The script then timestamps the Developer ID signature, submits the ZIP to Apple, waits for notarization, staples the ticket to the app, and recreates the archive.

## Privacy boundaries

Iriz never reads keystrokes, clipboard contents, or camera input. It pauses on screen lock, excludes its own UI and known password managers, and sends nothing while the app is paused. Screen analysis uses OpenAI `store: false`; OpenAI's independent abuse-monitoring retention policy still applies unless the API organization has approved data controls. Audio transcription and screen analysis are disabled until the user supplies an API key and grants the related macOS permissions.

Before distributing audio capture to other people, obtain jurisdiction-specific legal review and make participant notice expectations explicit.
