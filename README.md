# Replay

Replay is a native SwiftUI iPhone practice app for recording audio or video and immediately replaying the latest take once, with optional looping.

The core loop is **choose Audio or Video → Record → Stop → automatic playback once → optionally Save or record again**. Only the latest unsaved take is kept in the app. Audio saves to Files; video saves to Photos through explicit Save actions.

## Status

This repository contains an **early prototype**, not a completed implementation of the plan. The source includes audio/video capture, fullscreen video replay, phone-aware camera orientation, persisted 24/30/60 fps video settings (default 60), silent delayed video streaming with clip review/Photos saving, play-once playback with optional looping and a seekable timeline, microphone selection, a live audio recording waveform, camera switching, Clear controls, and export. Debug simulator and unsigned Release device builds now pass with Xcode 27.0. Unit/integration playback tests and the timeline/Loop UI test pass on the simulator. Physical-device capture and export workflows remain unverified.

Baseline work is in progress: a shared `Replay` scheme, Swift Testing and UI test targets, accessibility identifiers, and a focused SwiftLint configuration are present. The session state machine now drives recording, playback, mode switching, and export. Operation IDs reject stale callbacks, and a previous take is replaced only after confirmed capture start. Replay now launches successfully on the iPhone 18 Pro simulator with iOS 27.0. PCM format tests, playback integration tests, the launch smoke test, and the timeline/Loop UI test pass on the simulator. Rolling capture and CI are not implemented.

## Product scope

- Audio and video recording with immediate playback, once by default.
- An optional Loop switch, play/pause, a seekable timeline, and elapsed/total time for both media modes.
- Microphone selection on the audio recording screen; playback uses the system output route.
- One retained take across both media modes, with explicit export to Files or Photos. **Clear** stops playback and removes the temporary take; exported copies remain. Clear is available beside playback controls and in fullscreen video, and is disabled during capture/export.
- Native playback controls and an accessible timeline; recording elapsed time remains planned.
- No app-added audio effects or processing. This does not guarantee identical sound across hardware or system capture paths.

A tuner, live audio monitoring, effects, editing, slow motion, an in-app library, accounts, and cloud sync are outside the first-version scope. Fullscreen video playback, phone-matched camera orientation, and delayed video streaming are implemented in the prototype; physical-device validation remains pending.

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
| `Replay/PracticeView.swift` | Practice screen, media preview/player, frame-rate settings, controls, and Files export picker |
| `Replay/PracticeSession.swift` | State transitions, operation IDs, early Stop, cancellation, interruptions, and export ownership |
| `ReplayTests/PracticeSessionTests.swift` | Early Stop, duplicate/stale callbacks, replacement failure, playback readiness, and export ownership |
| `Replay/AudioWaveform.swift` | Bounded recorder-level history, live waveform, Reduce Motion meter, and accessible input level |
| `ReplayTests/AudioWaveformTests.swift` | Silence, quiet/loud input, invalid levels, bounded history, and reset behavior |
| `Replay/RecordingFormat.swift` | Lossless mono PCM configuration and shared persisted video frame-rate/format selection |
| `ReplayTests/RecordingFormatTests.swift` | Audio hardware-rate compatibility, invalid rates, and persisted video frame-rate defaults |
| `ReplayUITests/LaunchTests.swift` | Launch controls, timeline/Loop, native Files Save/Cancel, and failed replacement recovery |
| `scripts/run-simulator.sh` | Build, install, and open the app in an available iPhone simulator |
| `Replay/PracticeModel.swift` | Executes session effects, validates completed media, owns the current take, and associates exports with take IDs |
| `Replay/PracticeServices.swift` | Native audio/camera adapters, capture orientation, and Photos export |
| `Replay/DelayedFrameBuffer.swift` | Timestamp-based delay selection, capture-gap reset, and compressed byte/frame limits |
| `Replay/DelayedVideoCapture.swift` | Serial silent back-camera capture, JPEG compression, rotation, bounded UI mailbox, and stop-before-clip snapshots |
| `Replay/DelayedClipEncoder.swift` | Converts bounded timestamped history to an exact-duration, silent H.264 movie with complete-frame fitting |
| `ReplayTests/DelayedClipTests.swift` | Real movie boundaries/duration, paused review, explicit save/discard, failure retry, and cancelled-output cleanup |
| `Replay/DelayedStreamModel.swift` / `DelayedStreamView.swift` | Delay configuration, buffering/display states, stop/restart, and lifecycle cleanup |
| `ReplayTests/DelayedFrameBufferTests.swift` | Delay accuracy, resource bounds, gap recovery, and invalid timestamps |
| `ReplayTests/PracticeModelTests.swift` | Early Stop, failed replacement, interruption finalization, Save cancellation/retry, and exported-copy retention |
| `Replay.xcodeproj/project.pbxproj` | iPhone app target and build settings |

## Development workflow

`main` is the default branch and contains the stable prototype. Develop on feature branches, commit completed changes after their checks, and open pull requests targeting `main`. See [AGENTS.md](AGENTS.md).

## Implementation roadmap

Follow **Steps 1–8 → Step 8A → Step 8B → Steps 9–12**. Existing prototype code is a starting point to verify, not evidence that any milestone is complete.

| Step | Work |
| --- | --- |
| 1 | Establish Debug/Release builds, a shared scheme, unit/UI targets, SwiftLint, ignore rules, and reproducible setup |
| 2 | Session states and operation IDs are connected to capture, playback, and export; deterministic capture services support simulator regression |
| 3 | Implement one-take storage, safe replacement, recovery, an atomic manifest, and bounded cleanup |
| 4 | Handle permissions, input selection, actual routes, and accessory changes |
| 5 | Validate lossless audio capture, start/finalization results, elapsed time, live audio visualization, and no app-added processing |
| 6 | Readiness-aware autoplay, optional looping, pause, timeline seeking, fullscreen video replay, and observer cleanup are implemented; device validation remains pending |
| 7 | Camera preview and capture use native rotation coordinators; verify front/back framing, orientation, sound, and capture callbacks on device |
| 8 | Integrate mode switching with one retained take and correct resource ownership |
| 8A | Add bounded rolling audio/video capture, exact replay windows, stopped capture during replay, and explicit restart |
| 8B | Silent delayed video with a 5–60 second delay, bounded compressed-frame storage, buffering, stop/restart, and clip review/Photos export is implemented; sustained device measurements remain pending |
| 9 | Tie Files/Photos export progress and outcomes to the correct take |
| 10 | Handle interruptions, lifecycle transitions, input loss, storage exhaustion, and resource failures |
| 11 | Verify native UI, VoiceOver, Dynamic Type, appearance, and small-screen layout |
| 12 | Complete regression, device/performance evidence, CI, and developer handoff |

### Live audio waveform

Audio mode shows a live waveform while recording, using average microphone power from the same [AVAudioRecorder metering API](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/ismeteringenabled). The display samples at **20 Hz** and keeps **60 bars** (three seconds of level history). Quiet input stays near the baseline; silence is flat. The mono 24-bit PCM recording format and microphone selection are preserved.

Metering starts only after confirmed audio capture and resets on Stop, capture failure, interruption, backgrounding, or a new take. Stale samples are ignored. With **Reduce Motion**, a stationary input-level meter replaces the scrolling history; VoiceOver exposes a labeled current input level. Microphone response and responsiveness during longer recordings still require an iPhone check.

For a simulator checkpoint with generated quiet/loud tones, run `./scripts/run-simulator.sh --fixture-capture --fixture-waveform --preview-recording`. This debug fixture supplies matching generated levels and audio; it does not capture a microphone.

### Video capture settings

Open the gear button → **Settings → Frame rate** to choose **24, 30, or 60 fps**. The default is **60 fps** for both standard video recording and delayed streams, including clips. The choice persists between launches and applies to new captures; controls are locked during capture/export. Existing takes retain their original frame rate. Audio recording keeps its hardware sample rate.

Capture selects a camera format that supports the chosen rate and sets both frame durations; unsupported rates produce an actionable error rather than a silent fallback. See [Apple's frame-duration documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration). Standard capture uses a supported format up to 1080p; delayed video is downscaled to VGA to bound frame storage. Sustained 60 fps, camera support, dropped frames, memory use at a 60-second delay, and thermal behavior require physical-device validation. If a resource cap is reached, the stream stops with a recoverable error; a shorter delay or lower frame rate reduces storage demand.

### Video playback and delayed streaming

Recorded video opens fullscreen with play/pause, the timeline, optional Loop, Save, and Done. Closing/reopening fullscreen preserves the same player and position. Playback runs once by default. Both the practice screen and fullscreen player support portrait and landscape.

All video modes default to the **back camera**. Standard recording keeps a Flip camera control for choosing the front camera. Camera preview uses Apple's rotation coordinator and mirrors the front camera for framing. Recorded video is unmirrored and takes its orientation from the phone when Record is tapped. A movie keeps that orientation throughout the take; rotate before recording to choose portrait or landscape. Verify front/back recording and Photos output on a physical iPhone.

For delayed video, choose **Video → Delayed stream**, set a **5–60 second** delay (one-second steps; default **15 seconds**), and tap **Start stream**. A live viewfinder and progress bar appear while the initial buffer fills; the display then switches to delayed video while capture continues. Stop clears the stream; restarting fills a new buffer. Delay/mode changes are disabled while streaming. Backgrounding, camera interruptions, and failures stop the stream; returning to the app does not restart it.

The initial delayed mode uses the **back camera**, **silent video**, VGA capture (640×480 before rotation), and **60 fps by default**. It holds compressed JPEG frames in memory, with a **256 MiB compressed-data cap** and a **7,500-frame cap**, and writes no continuous stream file. History retains two delay intervals plus a three-second delivery margin, allowing clips of video already displayed. Making a clip creates one temporary H.264 movie from that bounded history. The system camera, encoder, and current displayed image use additional memory. Capture timestamps select frames at the configured delay; UI delivery adds latency, so actual on-device timing still needs measurement. A capture gap refills the history, and exceeding a resource limit stops with a recoverable error.

After watching a full delay interval, tap **Clip last N seconds viewed**. This stops capture and prepares the last N seconds of delayed video shown on screen, ending at the last displayed frame. Newer captured video is excluded. Viewed-history progress appears until clipping is available; a 15-second delay takes approximately 30 seconds from Start to the first full clip (15 seconds buffering, then 15 seconds viewing). It opens **paused in fullscreen**, with the existing timeline, Play/Pause, and optional Loop. Choose **Save** to copy it to Photos, or **Discard** to delete the temporary clip. Done returns to the delayed-mode controls. Capture stays stopped until you explicitly start another stream.

No Photos save occurs when clipping. A successfully prepared clip becomes the latest take across both modes, replacing the previous temporary take; preparation failure preserves the previous take. Save failure keeps the clip available for retry. Discard removes only the temporary file, so any exported copy survives. Backgrounding during review preserves the paused clip; backgrounding during preparation cancels it and cleans up partial output. The delay can be adjusted before another stream; changing it does not resize a clip already under review.

Delayed video and its clips remain silent. Normal recording and rolling capture remain separate workflows; standard rolling capture is still unimplemented.

### Intended architecture

Split hardware, storage, and timing boundaries into small testable services:

- `PracticeCoordinator`: main-actor state and recording/playback/export transitions.
- `Take` and `TakeStore`: stable take identity, pending files, replacement, metadata, recovery, and cleanup.
- `AudioSessionController`, `AudioRecorder`, and `CameraRecorder`: routes, capture start acknowledgement, and finalization.
- `PlaybackController`: readiness, repeat, pause, seek, errors, and observer lifetime.
- `ExportService`: Files and Photos results associated with a take ID.
- SwiftUI views: state presentation, actions, native sheets, and accessibility.

The practice coordinator models ready, preparing, recording, finishing, replaying, paused, exporting, and recoverable-error states. Standard and rolling modes stop capture before replay. `DelayedStreamModel` owns separate starting/buffering/streaming/finishing/reviewing/stopped/error states for concurrent capture and delayed video display, with session IDs and a single-slot mailbox rejecting stale or backed-up UI updates. Delayed or stale callbacks must not replace newer state or media.

### Decisions still needed

The prototype keeps iOS 17, its mono lossless PCM format, and temporary-only relaunch storage. It now preserves the previous take on start failure, pauses on mode changes and export, and avoids automatic resume after interruptions. Camera orientation is chosen at the start of a recorded take; delayed video follows rotation continuously. Persistent relaunch retention, accessory support, recording duration coverage, and latency targets still need product decisions and device validation. Delayed video uses the back camera and can create silent clips for explicit Photos export; additional streaming camera selection or audio remains future scope.

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

Current evidence: **Debug simulator, unsigned Release device, and test-target builds pass**; **49 simulator unit/integration tests and ten UI scenarios pass**; **20 host-side session/delay/waveform tests also pass**; **SwiftLint 0.65.1 reports zero violations**; and project/scheme reference checks plus shell syntax checks pass. Simulator launch, timeline playback, fullscreen position/Loop/play-intent preservation and landscape layout, delayed-stream buffering/stop/restart/background behavior, clip review/scrubbing/native Photos save/discard, the generated recording-to-replay flow, native Files save/cancel, and failed-start recovery are verified. Delay selection and buffer bounds are tested for every integer delay from 5 through 60 seconds. Capture tests inject deterministic callbacks and generated audio/video fixtures. Settings tests verify a 60 fps default and persistence across relaunches; an encoded movie verifies 60 fps metadata, and buffer tests cover 60 seconds at 24/30/60 fps. Real encoded clips verify duration and first/last-frame content for 5/15/30/60-second windows. Waveform tests cover silence, quiet/loud levels, bounded history, stale samples, failed capture, stop/restart, and backgrounding. Clear tests cover audio and fullscreen video, blocked capture/export states, delayed-clip cleanup, fresh recording, and retained exported copies. Tests also cover partial-output cleanup, cancelled/stale encoding, explicit discard without export, save failure/retry, prior-take retention, and back-camera defaults. Physical microphone/camera capture, front/back orientation and Photos output, sustained 60 fps capture and delayed-stream timing/thermal/resource measurements, accessory routing, real interruptions, and physical Photos export still require an iPhone. Native Files and Photos save UI have been exercised on the simulator. Camera-session work and start/stop callbacks are serialized. Mode changes pause replay and preserve the take; exports pause replay and remain paused after completion or cancellation. Transient permission/save-sheet inactivity does not end recording; backgrounding and interruptions stop capture safely without automatic resume.

### Preview playback controls

Run `./scripts/run-simulator.sh --preview-audio --preview-paused` for a playback preview. Debug builds accept these launch arguments to load a generated 12-second silent clip. Use `--preview-video --preview-paused` for generated fullscreen video. UI tests use `--fixture-capture --fixture-stream` for animated timestamped camera fixtures without hardware; `--fast-stream` accelerates fixture time only and never affects native capture. Run `./scripts/run-simulator.sh --fixture-stream --preview-stream` to open the animated delayed-video checkpoint automatically; it fills the selected delay in real time. Add `--preview-clip` to automatically clip the first full window and open it for review. This lets you inspect the timeline and Loop switch without capturing microphone input. Normal launches still begin ready to record. `--fixture-capture` substitutes generated audio for capture in simulator workflow tests; it never requests microphone input. `--fail-second-start` injects one replacement failure in that harness. Preview arguments are ignored in Release builds.

Files export remains paused after Save or Cancel. A new recording is disabled until the picker reports its result, and Saved is shown only for a confirmed success.

Playback starts once by default. Loop starts off on each app launch and can be toggled for the current practice session. Scrubbing a paused take keeps it paused; scrubbing during playback resumes from the new position when released. Seeking to the end stops playback, and Play then restarts from the beginning.

## Source documents

This README summarizes Isaac's second-brain note **Replay — Implementation and testing plan**, updated **October 21, 2026**, at `life/Replay/Implementation-plan.md`. Related notes are `life/Replay/Product-design.md` and `life/Replay/UI-design.md`. These documents live in the personal Obsidian vault and are not bundled with this repository. The October 17, 2026 request to play once by default with optional looping supersedes the original plan's automatic-repeat requirement.

The plan records proposed work and acceptance criteria. Implementation has now begun; only the checks listed above have been verified. Distribution and physical-device validation remain pending.
