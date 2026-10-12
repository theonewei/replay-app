# Replay

Replay is a native SwiftUI iPhone practice app for recording audio or video and immediately replaying the latest take on repeat.

The core loop is **choose Audio or Video → Record → Stop → automatic repeating playback → optionally Save or record again**. Only the latest unsaved take is kept in the app. Audio saves to Files; video saves to Photos through explicit Save actions.

## Status

This repository contains an **early prototype**, not a completed implementation of the plan. The source sketches audio/video capture, repeating playback, microphone selection, camera switching, and export. Previous validation covered Swift parsing and project-file syntax only; a successful Xcode build, simulator run, and physical-device workflow have not been established by the implementation plan.

Rolling capture is not implemented. There are currently no test targets, checked-in shared scheme, SwiftLint configuration, or CI workflow.

## Product scope

- Audio and video recording with immediate, repeating playback.
- Microphone selection on the audio recording screen; playback uses the system output route.
- One retained take across both media modes, with explicit export to Files or Photos.
- Planned play/pause, scrubbing, elapsed time, and accessible native controls.
- No app-added audio effects or processing. This does not guarantee identical sound across hardware or system capture paths.

A tuner, live monitoring, effects, editing, slow motion, an in-app library, accounts, and cloud sync are outside the first-version scope.

### Planned rolling capture

Both audio and video will support rolling capture with **5, 10, 30, and 60-second presets**, defaulting to **10 seconds**.

Tapping Replay will stop capture and loop only the latest selected window. Capture stays stopped until Record is tapped again, which starts a fresh window. Save exports exactly the clip being replayed. Capture storage and memory must stay bounded during long sessions; recording an ever-growing file and trimming it afterward does not satisfy the plan.

The Standard / Rolling selector, behavior when capture is shorter than the preset, and locking preset changes during capture are proposed choices. Remembering the last duration remains undecided.

## Open the prototype

1. Use a Mac with Xcode and an iOS SDK supporting the project's **iOS 17.0** deployment target. The validated Xcode version is still to be selected in Step 1.
2. Open `Replay.xcodeproj` and select the `Replay` app target/scheme in Xcode.
3. For a physical iPhone, select your development team under Signing & Capabilities and use a suitable bundle identifier. The current identifier is `com.example.ReplayPractice`.
4. Select a destination and build/run. Use a physical iPhone to verify microphone, camera, accessory routing, and exports.
5. Allow microphone and camera access when requested; Photos add permission is needed for video saving.

These are setup directions for evaluating the prototype, not a verified build recipe. Step 1 must establish reproducible setup and simulator instructions.

**Current storage behavior:** the prototype deletes its app-owned temporary take folder at launch. Unsaved takes do not survive relaunch. The plan proposes retaining one completed take, but that policy has not been confirmed.

## Repository layout

| File | Current responsibility |
| --- | --- |
| `Replay/ReplayApp.swift` | SwiftUI app entry point |
| `Replay/PracticeView.swift` | Practice screen, media preview/player, controls, and Files export picker |
| `Replay/PracticeModel.swift` | Recording, playback, audio session, temporary storage, Photos export, and camera recorder |
| `Replay.xcodeproj/project.pbxproj` | iPhone app target and build settings |

## Implementation roadmap

Follow **Steps 1–8 → Step 8A → Steps 9–12**. Existing prototype code is a starting point to verify, not evidence that any milestone is complete.

| Step | Work |
| --- | --- |
| 1 | Establish Debug/Release builds, a shared scheme, unit/UI targets, SwiftLint, ignore rules, and reproducible setup |
| 2 | Introduce explicit session states, serialized transitions, operation IDs, and deterministic test services |
| 3 | Implement one-take storage, safe replacement, recovery, an atomic manifest, and bounded cleanup |
| 4 | Handle permissions, input selection, actual routes, and accessory changes |
| 5 | Validate lossless audio capture, start/finalization results, elapsed time, and no app-added processing |
| 6 | Implement readiness-aware autoplay, repeat, pause, scrubbing, and observer cleanup |
| 7 | Verify camera preview, front/back capture, framing, orientation, sound, and asynchronous capture callbacks |
| 8 | Integrate mode switching with one retained take and correct resource ownership |
| 8A | Add bounded rolling audio/video capture, exact replay windows, stopped capture during replay, and explicit restart |
| 9 | Tie Files/Photos export progress and outcomes to the correct take |
| 10 | Handle interruptions, lifecycle transitions, input loss, storage exhaustion, and resource failures |
| 11 | Verify native UI, VoiceOver, Dynamic Type, appearance, and small-screen layout |
| 12 | Complete regression, device/performance evidence, CI, and developer handoff |

### Intended architecture

Split hardware, storage, and timing boundaries into small testable services:

- `PracticeCoordinator`: main-actor state and recording/playback/export transitions.
- `Take` and `TakeStore`: stable take identity, pending files, replacement, metadata, recovery, and cleanup.
- `AudioSessionController`, `AudioRecorder`, and `CameraRecorder`: routes, capture start acknowledgement, and finalization.
- `PlaybackController`: readiness, repeat, pause, seek, errors, and observer lifetime.
- `ExportService`: Files and Photos results associated with a take ID.
- SwiftUI views: state presentation, actions, native sheets, and accessibility.

The coordinator should model ready, preparing, recording, finishing, replaying, paused, exporting, and recoverable-error states. Recording and playback must never overlap. Delayed or stale callbacks must not replace newer state or media.

### Decisions still needed

The plan lists proposed defaults for minimum iOS version, relaunch retention, failed replacement, mode switching, camera selection, video sound, orientation/mirroring, audio format, saving during replay, background behavior, recording duration, and latency targets. Resolve these in Product design before dependent implementation; do not treat them as confirmed requirements.

## Validation plan

Use Swift Testing for unit tests, real files and AVFoundation fixtures for integration tests, XCTest/XCUIAutomation for UI tests, and physical iPhones for hardware behavior. Test services should support delayed, failed, duplicate, and stale callbacks, a controllable clock, and isolated storage.

Required evidence includes:

- Debug simulator and Release generic-device builds, lint, and a launch smoke test.
- Safe replacement and recovery, permission denial, route changes, playback races, and export cancellation/failure.
- Real audio/video capture, both cameras, Files/Photos reopening, interruptions, and accessibility checks.
- Every rolling preset in both media modes: correct boundaries, capture stopped before replay, fresh buffers on restart, exact exported clips, and bounded resources during 15-minute capture.
- Standard-recording regression, 10-minute takes, 100 replacement cycles, and measured stop-to-first-output latency on agreed phones.

The proposed p95 latency targets are audio ≤0.5 seconds and video ≤1.0 second. These are pending agreement and measurement, not current performance claims. Passing fixture tests or Swift syntax checks does not establish physical capture functionality.

### Planned commands after Step 1

These commands require the shared `Replay` scheme, test targets, and documented SwiftLint version/configuration added in Step 1. They are not currently verified commands. Replace `SIMULATOR_UDID` with an installed simulator ID and use a fresh result path for each test run.

```sh
xcodebuild -version
xcodebuild -list -project Replay.xcodeproj
xcrun simctl list devices available
swiftlint lint --strict
xcodebuild -project Replay.xcodeproj -scheme Replay -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' build
xcodebuild -project Replay.xcodeproj -scheme Replay -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' -only-testing:ReplayTests -resultBundlePath build/unit-results.xcresult test
xcodebuild -project Replay.xcodeproj -scheme Replay -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' -only-testing:ReplayUITests -resultBundlePath build/ui-results.xcresult test
xcodebuild -project Replay.xcodeproj -scheme Replay -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Source documents

This README summarizes Isaac's second-brain note **Replay — Implementation and testing plan**, updated **October 10, 2026**, at `life/Replay/Implementation-plan.md`. Related notes are `life/Replay/Product-design.md` and `life/Replay/UI-design.md`. These documents live in the personal Obsidian vault and are not bundled with this repository.

The plan records proposed work and acceptance criteria; it does not record future tests as passing or authorize implementation or release.
