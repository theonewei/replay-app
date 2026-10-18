# Replay

Replay is a native SwiftUI iPhone practice app for recording audio or video and immediately replaying the latest take once, with optional looping.

The core loop is **choose Audio or Video → Record → Stop → automatic playback once → optionally Save or record again**. Only the latest unsaved take is kept in the app. Audio saves to Files; video saves to Photos through explicit Save actions.

## Status

This repository contains an **early prototype**, not a completed implementation of the plan. The source includes audio/video capture, play-once playback with optional looping and a seekable timeline, microphone selection, camera switching, and export. Debug simulator and unsigned Release device builds now pass with Xcode 27.0. Unit/integration playback tests and the timeline/Loop UI test pass on the simulator. Physical-device capture and export workflows remain unverified.

Baseline work is in progress: a shared `Replay` scheme, Swift Testing and UI test targets, accessibility identifiers, and a focused SwiftLint configuration are present. The hardware-independent session core passes seven host-side tests but is not yet connected to the app. Replay now launches successfully on the iPhone 18 Pro simulator with iOS 27.0. PCM format tests, playback integration tests, the launch smoke test, and the timeline/Loop UI test pass on the simulator. Rolling capture and CI are not implemented.

## Product scope

- Audio and video recording with immediate playback, once by default.
- An optional Loop switch, play/pause, a seekable timeline, and elapsed/total time for both media modes.
- Microphone selection on the audio recording screen; playback uses the system output route.
- One retained take across both media modes, with explicit export to Files or Photos.
- Native playback controls and an accessible timeline; recording elapsed time remains planned.
- No app-added audio effects or processing. This does not guarantee identical sound across hardware or system capture paths.

A tuner, live monitoring, effects, editing, slow motion, an in-app library, accounts, and cloud sync are outside the first-version scope.

### Planned rolling capture

Both audio and video will support rolling capture with **5, 10, 30, and 60-second presets**, defaulting to **10 seconds**.

Tapping Replay will stop capture and play only the latest selected window once; Loop will optionally repeat it. Capture stays stopped until Record is tapped again, which starts a fresh window. Save exports exactly the clip being replayed. Capture storage and memory must stay bounded during long sessions; recording an ever-growing file and trimming it afterward does not satisfy the plan.

The Standard / Rolling selector, behavior when capture is shorter than the preset, and locking preset changes during capture are proposed choices. Remembering the last duration remains undecided.

## Open the prototype

1. Use a Mac with Xcode and an iOS SDK supporting the project's **iOS 17.0** deployment target. Baseline toolchain: **Xcode 27.0 (27A266a)**, installed at `/Applications/Xcode.app`. Complete its license and component setup before building. Debug simulator and unsigned Release device builds have been verified with this version.
2. Open `Replay.xcodeproj` and select the `Replay` app target/scheme in Xcode.
3. For a physical iPhone, select your development team under Signing & Capabilities and use a suitable bundle identifier. The current identifier is `com.example.ReplayPractice`.
4. Select a destination and build/run. Use a physical iPhone to verify microphone, camera, accessory routing, and exports.
5. Allow microphone and camera access when requested; Photos add permission is needed for video saving.

### Build and launch in the iPhone simulator

```sh
./scripts/run-simulator.sh
```

The script uses the installed Xcode without changing the system's selected developer directory, picks an available iPhone simulator (preferring one already booted), builds Debug, installs Replay, and opens it in Device Hub (Xcode 27) or Simulator (earlier versions). Set `SIMULATOR_UDID` to choose a specific installed device. If no iOS runtime is available, install one in Xcode Settings → Components. Build logs and DerivedData stay under ignored `build/`.

Verified on **iPhone 18 Pro / iOS 27.0 (24A434)**. With Xcode 27, the simulator appears in **Device Hub**; older Xcode versions use Simulator.app. The initial Audio ready screen has been visually checked.

**Current storage behavior:** the prototype deletes its app-owned temporary take folder at launch. Unsaved takes do not survive relaunch. The plan proposes retaining one completed take, but that policy has not been confirmed.

## Repository layout

| File | Current responsibility |
| --- | --- |
| `Replay/ReplayApp.swift` | SwiftUI app entry point |
| `Replay/PlaybackController.swift` | Playback readiness, play-once default, optional looping, seeking, time updates, and observer cleanup |
| `ReplayTests/PlaybackControllerTests.swift` | Real fixture playback, looping, seeking, pause/seek races, and take replacement |
| `Replay/PracticeView.swift` | Practice screen, media preview/player, controls, and Files export picker |
| `Replay/PracticeSession.swift` | Explicit state transitions and operation IDs; not yet connected to hardware services |
| `ReplayTests/PracticeSessionTests.swift` | Early Stop, duplicate/stale callbacks, replacement failure, playback readiness, and export ownership |
| `Replay/RecordingFormat.swift` | Validated sample-rate input for the prototype's lossless mono PCM configuration |
| `ReplayTests/RecordingFormatTests.swift` | Hardware-rate compatibility and invalid-rate tests |
| `ReplayUITests/LaunchTests.swift` | Launch smoke test for mode, Record, and Save controls |
| `scripts/run-simulator.sh` | Build, install, and open the app in an available iPhone simulator |
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
| 6 | Readiness-aware autoplay, optional looping, pause, timeline seeking, and observer cleanup are implemented; device validation remains pending |
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

### Baseline checks

Use **SwiftLint 0.65.1** (`brew install swiftlint`; check `swiftlint version`). Run `./scripts/lint.sh` to select Xcode's SourceKit explicitly, even if the system selects Command Line Tools. The focused rule set checks whitespace, final newlines, and forced `try`. Expand it as implementation progresses.

The shared scheme and test targets are present. Debug/Release builds and simulator tests pass. Export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if the system selects Command Line Tools. Replace `SIMULATOR_UDID` with an installed simulator ID and use a fresh result path for each test run.

```sh
xcodebuild -version
xcodebuild -list -project Replay.xcodeproj
xcrun simctl list devices available
./scripts/lint.sh
xcodebuild -project Replay.xcodeproj -scheme Replay -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' build
xcodebuild -project Replay.xcodeproj -scheme Replay -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' -only-testing:ReplayTests -resultBundlePath build/unit-results.xcresult test
xcodebuild -project Replay.xcodeproj -scheme Replay -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' -only-testing:ReplayUITests -resultBundlePath build/ui-results.xcresult test
xcodebuild -project Replay.xcodeproj -scheme Replay -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

### Hardware-independent state tests

```sh
./scripts/test-core.sh
```

This small SwiftPM harness uses the installed Command Line Tools and their Swift Testing framework on macOS 14 or later. It runs the same session tests included in the iOS unit target without requiring a simulator, microphone, or camera. Format and UI tests remain exclusive to the Xcode project.

Current evidence: **Debug simulator, unsigned Release device, and test-target builds pass**; **14 simulator unit/integration tests and both UI scenarios pass**; **7 host-side session tests also pass**; **SwiftLint 0.65.1 reports zero violations**; and project/scheme reference checks plus shell syntax checks pass. The simulator installation, launch, and Audio ready screen are verified. Hardware capture remains unverified. The existing camera recorder also produces Swift concurrency warnings; its queue/isolation model is scheduled for the capture-service work. The state core's proposed mode-switch and export-pause policies remain separate from the running prototype until product decisions and integration are complete.

### Preview playback controls

Run `./scripts/run-simulator.sh --preview-audio --preview-paused` for a playback preview. Debug builds accept these launch arguments to load a generated 12-second silent clip. This lets you inspect the timeline and Loop switch without capturing microphone input. Normal launches still begin ready to record. Preview arguments are ignored in Release builds.

Playback starts once by default. Loop starts off on each app launch and can be toggled for the current practice session. Scrubbing a paused take keeps it paused; scrubbing during playback resumes from the new position when released. Seeking to the end stops playback, and Play then restarts from the beginning.

## Source documents

This README summarizes Isaac's second-brain note **Replay — Implementation and testing plan**, updated **October 10, 2026**, at `life/Replay/Implementation-plan.md`. Related notes are `life/Replay/Product-design.md` and `life/Replay/UI-design.md`. These documents live in the personal Obsidian vault and are not bundled with this repository. The October 17, 2026 request to play once by default with optional looping supersedes the original plan's automatic-repeat requirement.

The plan records proposed work and acceptance criteria. Implementation has now begun; only the checks listed above have been verified. Distribution and physical-device validation remain pending.
