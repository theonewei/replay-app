// swift-tools-version: 6.0
import PackageDescription

// A small host-side harness for hardware-independent session tests.
// iOS capture, format, and UI tests still run through the Xcode project.
let package = Package(
    name: "ReplayCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ReplayCore",
            path: "Replay",
            exclude: ["ReplayApp.swift", "PracticeView.swift", "PracticeModel.swift", "RecordingFormat.swift", "PlaybackController.swift", "PreviewMedia.swift", "PracticeServices.swift", "DelayedVideoCapture.swift", "DelayedStreamModel.swift", "DelayedStreamView.swift"],
            sources: ["PracticeSession.swift", "DelayedFrameBuffer.swift"]
        ),
        .testTarget(
            name: "ReplayCoreTests",
            dependencies: ["ReplayCore"],
            path: "ReplayTests",
            exclude: ["RecordingFormatTests.swift", "PlaybackControllerTests.swift", "PracticeModelTests.swift"],
            sources: ["PracticeSessionTests.swift", "DelayedFrameBufferTests.swift"]
        )
    ]
)
