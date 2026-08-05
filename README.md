# iriz

iriz is a native, local-first contextual memory for macOS. It notices meaningful screen and voice context, keeps routine activity quiet, and turns unfinished work into **Actions**: context-aware next steps created from meaningful commitments and loose ends.

Public repository: [github.com/daviddemri26/iriz](https://github.com/daviddemri26/iriz)

## Product model

- **Actions** keep meaningful commitments and unfinished work visible. iriz can create or enrich them from evidence, suggest completion when the signal is promising, and complete them automatically only when the evidence is explicit.
- **Ask iriz** searches encrypted memory locally first, sends only a bounded set of relevant evidence and recent thread context, and returns sourced answers. Conversations can be pinned for quick access.
- **How iriz Works** explains the local-first flow and includes an interactive version of the production indicator.
- **The indicator** combines colors when several states are active. A rotating contextual gradient means an OpenAI request is in progress; fixed colors continue to show observation, listening, meetings, private context, and blocking issues.

## Current implementation

- Native SwiftUI application with AppKit floating controls and one main application window.
- macOS 15 minimum, Swift 6, and no required third-party runtime.
- ScreenCaptureKit capture with local frame differencing and Vision OCR.
- Accessibility-based active-window and browser URL adapters.
- Ambient microphone capture with local silence suppression and WAV segmentation; system audio is captured as a separate track during detected meetings.
- Optional 2–10 second voice enrollment stored in Keychain and sent only as the `You` reference for diarized meeting transcription.
- OpenAI Responses and Transcriptions clients using a user-provided API key stored in Keychain.
- A token-based activity registry that tracks local processing and concurrent OpenAI calls without stopping the indicator before the final request finishes.
- Local SQLite FTS5 search. The live database is held in memory and serialized into an AES-GCM encrypted file, so event text is not left in a plaintext SQLite database on disk.
- AES-GCM encrypted media with automatic 24-hour cleanup.
- Actions, Ask iriz, pinned conversations, source details, Settings, onboarding, retention, exclusions, launch-at-login controls, and warned JSON/Markdown memory exports without raw media.
- Standalone and future Setapp distribution adapters.

The packaged personal build does not contain an API key. Enter one in **Settings → AI & Language**. Tests do not call OpenAI.

## Build and test

```sh
SWIFT_MODULECACHE_PATH=/tmp/iriz-swift-cache \
CLANG_MODULE_CACHE_PATH=/tmp/iriz-swift-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/iriz-swift-cache \
swift test --disable-sandbox
```

Run from Xcode by opening `Package.swift`, or use `swift run iriz`.

## Package

```sh
./Scripts/package_app.sh
```

The script builds a Universal `arm64`/`x86_64` `build/iriz.app`, applies an ad-hoc signature when no Developer ID identity is supplied, validates the bundle, and creates `build/iriz.zip`.

### Developer ID release candidate

Use the real Developer ID Application identity to test macOS permissions and upgrades before public distribution. Xcode must be signed in to the Apple Developer team and the certificate must be present in the login Keychain.

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./Scripts/package_release_candidate.sh
./Scripts/install_release_candidate.sh  # installs /Applications/iriz.app
```

Always launch `/Applications/iriz.app` for permission acceptance. Do not alternate with `.build`, `swift run`, or `build/iriz.app`, because TCC evaluates the signed application identity and path. The installer removes the existing app before replacement and refuses an update if the designated code requirement changes.

The critical local acceptance sequence is:

1. Grant Screen Recording, Microphone, Accessibility, and Notifications from iriz Settings.
2. Relaunch `/Applications/iriz.app` and verify every status is retained.
3. Package and install another build using the same Developer ID identity.
4. Verify the permissions remain granted after the update.
5. Exercise Observe, Listen, Pause, privacy exclusions, screen lock, and the floating panel without repeated prompts.

This validates the real Developer ID and TCC lifecycle. A public build additionally requires Apple notarization and a successful Gatekeeper assessment.

For direct release distribution, first save notary credentials with `notarytool`, then run:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="iriz-notary" \
./Scripts/package_public_release.sh
```

The script timestamps the Developer ID signature, submits the ZIP to Apple, waits for notarization, staples the ticket to the app, and recreates the archive.

## Privacy boundaries

iriz never reads keystrokes, clipboard contents, or camera input. It pauses on screen lock, excludes its own UI and known password managers, and sends nothing while the app is paused. Screen analysis uses OpenAI `store: false`; OpenAI's independent abuse-monitoring retention policy still applies unless the API organization has approved data controls. Audio transcription and screen analysis remain disabled until the user supplies an API key and grants the related macOS permissions.

Before distributing audio capture to other people, obtain jurisdiction-specific legal review and make participant notice expectations explicit.
