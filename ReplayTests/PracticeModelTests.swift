import AVFoundation
import Combine
import CoreVideo
import Testing
import XCTest
import UIKit
@testable import Replay

@Suite(.serialized)
@MainActor
struct DelayedStreamTests {
    private func started(_ model: DelayedStreamModel) async {
        let ready = XCTestExpectation(description: "Stream enters buffering")
        let subscription = model.$state.filter { $0 == .buffering }.prefix(1).sink { _ in ready.fulfill() }
        model.start()
        #expect(await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed)
        withExtendedLifetime(subscription) {}
    }

    @Test func stopRestartAndStaleFrames() async throws {
        let driver = ControlledStreamDriver()
        let model = DelayedStreamModel(driver: driver)
        defer { model.stop() }
        #expect(model.delay == 15)
        await started(model)
        let first = try #require(await driver.latestID)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).jpegData(withCompressionQuality: 0.6) { _ in }
        await driver.emit(first, update: StreamUpdate(data: image, buffered: 2, measuredDelay: nil, error: nil, isLive: true))
        model.poll()
        #expect(model.state == .buffering && model.isLive && model.image != nil)
        #expect(!model.canClip && model.viewed == 0)
        await driver.emit(first, update: StreamUpdate(data: image, buffered: 15, measuredDelay: 15.02, error: nil, sourceTime: 0))
        model.poll()
        #expect(model.state == .streaming)
        #expect(model.image != nil)
        #expect(model.measuredDelay == 15.02)
        model.stop()
        #expect(model.image == nil)
        #expect(!model.isRunning)
        await started(model)
        await driver.emit(first, update: StreamUpdate(data: image, buffered: 15, measuredDelay: 15, error: nil))
        model.poll()
        #expect(model.state == .buffering)
        #expect(model.image == nil)
        let second = try #require(await driver.latestID)
        await driver.emit(second, update: StreamUpdate(data: nil, buffered: 0, measuredDelay: nil, error: "Interrupted"))
        model.poll()
        #expect(model.state == .failed("Interrupted"))
        #expect(!model.isRunning)
        #expect(model.image == nil)
    }

    @Test func sixtySecondDelayStartsWithLivePreviewAndResetsViewedHistoryAfterAGap() async throws {
        let driver = ControlledStreamDriver()
        let model = DelayedStreamModel(driver: driver)
        defer { model.stop() }
        model.delay = 60
        await started(model)
        let id = try #require(await driver.latestID)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).jpegData(withCompressionQuality: 0.6) { _ in }
        await driver.emit(id, update: .init(data: image, buffered: 1, measuredDelay: nil, error: nil, isLive: true))
        model.poll()
        #expect(model.image != nil && model.isLive && !model.canClip)
        for time in 0...60 {
            await driver.emit(id, update: .init(data: image, buffered: 60, measuredDelay: 60, error: nil, sourceTime: Double(time)))
            model.poll()
        }
        #expect(model.canClip && model.viewed == 60 && !model.isLive)
        await driver.emit(id, update: .init(data: image, buffered: 60, measuredDelay: 60, error: nil, sourceTime: 63))
        model.poll()
        #expect(!model.canClip && model.viewed == 0)
        model.stop()
        #expect(model.viewed == 0 && !model.isLive)
    }

    @Test func stopDuringPreparationIgnoresLateStart() async throws {
        let entered = XCTestExpectation(description: "Driver start is pending")
        let driver = ControlledStreamDriver(entered: entered)
        let model = DelayedStreamModel(driver: driver)
        model.start()
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed)
        model.stop()
        await driver.releaseStart()
        #expect(model.state == .stopped)
        #expect(!model.isRunning)
        #expect(model.image == nil)
    }

    @Test func startFailureIsRecoverable() async {
        let driver = ControlledStreamDriver(fails: true)
        let model = DelayedStreamModel(driver: driver)
        let failed = XCTestExpectation(description: "Driver failure is shown")
        let subscription = model.$state.filter { $0 == .failed("Camera unavailable") }.prefix(1).sink { _ in failed.fulfill() }
        model.start()
        #expect(await XCTWaiter.fulfillment(of: [failed], timeout: 5) == .completed)
        #expect(!model.isRunning)
        #expect(model.image == nil)
        withExtendedLifetime(subscription) {}
    }
}

private actor ControlledStreamDriver: DelayedVideoCapturing {
    var latestID: UUID?
    private var mailboxes: [UUID: StreamMailbox] = [:]
    private let entered: XCTestExpectation?
    private let fails: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation? = nil, fails: Bool = false) { self.entered = entered; self.fails = fails }
    func start(id: UUID, delay: Double, frameRate: Int, mailbox: StreamMailbox) async throws {
        latestID = id
        mailboxes[id] = mailbox
        if fails { throw PracticeError("Camera unavailable") }
        if let entered {
            await withCheckedContinuation { continuation in self.continuation = continuation; entered.fulfill() }
        }
    }
    func releaseStart() { continuation?.resume(); continuation = nil }
    func emit(_ id: UUID, update: StreamUpdate) { mailboxes[id]?.put(update) }
    func clip(id: UUID, endingAt: Double) async throws -> DelayedFrameBuffer.Clip { throw PracticeError("No test clip") }
    func stop(id: UUID) async {}
}

@Suite(.serialized)
@MainActor
struct PracticeModelTests {
    @Test func failedClipPreservesThePreviousRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let driver = ClipTestDriver(clip: try DelayedClipTests.fixture(delay: 15))
        let stream = DelayedStreamModel(driver: driver, encoder: FailingClipEncoder())
        let model = PracticeModel(capture: capture, storage: root, delayed: stream)
        defer { model.playback.clear(); stream.stop() }
        try await complete(model, capture: capture)
        let original = try #require(model.take)
        model.mode = .video
        model.setDelayedMode(true)
        await model.startDelayedStream()
        let started = XCTestExpectation(description: "Stream buffering")
        let subscription = stream.$state.filter { $0 == .buffering }.prefix(1).sink { _ in started.fulfill() }
        #expect(await XCTWaiter.fulfillment(of: [started], timeout: 5) == .completed)
        for offset in 0...15 {
            await driver.ready(time: 103 + Double(offset))
            stream.poll()
        }
        let failed = XCTestExpectation(description: "Clip failure is recoverable")
        let failure = stream.$state.filter { $0 == .failed("Encoding failed") }.prefix(1).sink { _ in failed.fulfill() }
        model.clipDelayedStream()
        #expect(await XCTWaiter.fulfillment(of: [failed], timeout: 5) == .completed)
        #expect(model.take == original)
        #expect(FileManager.default.fileExists(atPath: original.url.path))
        #expect(await driver.active == false)
        withExtendedLifetime((subscription, failure)) {}
    }

    @Test func videoStartsWithBackCameraAndFlipIsExplicit() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let model = PracticeModel(capture: capture, storage: root)
        model.mode = .video
        await model.prepare()
        #expect(capture.preparedPositions.last == .back)
        await model.flipCamera()
        #expect(capture.preparedPositions.last == .front)
        await model.flipCamera()
        #expect(capture.preparedPositions.last == .back)
        await start(model, capture: capture)
        #expect(capture.recordedPosition == .back)
        model.suspend()
    }

    private func waitFor(_ model: PracticeModel, state: PracticeSession.State, action: () -> Void) async {
        let ready = XCTestExpectation(description: "Session reaches \(state)")
        let observer = model.$session.dropFirst().filter { $0.state == state }.prefix(1).sink { _ in ready.fulfill() }
        action()
        #expect(await XCTWaiter.fulfillment(of: [ready], timeout: 10) == .completed)
        withExtendedLifetime(observer) {}
    }

    private func start(_ model: PracticeModel, capture: ControlledCapture) async {
        let requested = XCTestExpectation(description: "Capture requested")
        capture.onRequest = { requested.fulfill() }
        model.toggleRecording()
        #expect(await XCTWaiter.fulfillment(of: [requested], timeout: 5) == .completed)
    }

    private func complete(_ model: PracticeModel, capture: ControlledCapture) async throws {
        await start(model, capture: capture)
        capture.acknowledge()
        model.toggleRecording()
        await waitFor(model, state: .replaying) { capture.finish() }
    }

    @Test func earlyStopIsQueuedAndPlaybackWaitsForFinalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let model = PracticeModel(capture: capture, storage: root)
        defer { model.playback.clear() }
        await start(model, capture: capture)
        #expect(model.session.state == .preparing)
        model.toggleRecording() // Stop before capture acknowledges its start.
        #expect(capture.stopCount == 0)
        #expect(model.player == nil)
        capture.acknowledge()
        #expect(model.session.state == .finishing)
        #expect(capture.stopCount == 1)
        model.toggleRecording()
        #expect(capture.requestCount == 1)
        #expect(capture.stopCount == 1)
        await waitFor(model, state: .replaying) { capture.finish() }
        #expect(model.playback.isReady)
        #expect(model.playback.isPlaying)
        #expect(!model.playback.loopEnabled)
        model.togglePlayback()
        #expect(model.session.state == .paused)
        #expect(!model.playback.isPlaying)
        model.playback.seek(to: 7)
        #expect(model.playback.position == 7)
        #expect(model.session.state == .paused)
    }

    @Test func failedReplacementAndStaleCallbacksPreserveTheTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let model = PracticeModel(capture: capture, storage: root)
        defer { model.playback.clear() }
        try await complete(model, capture: capture)
        let previous = try #require(model.take)
        let previousCallback = capture.finished
        capture.failStart = true
        await waitFor(model, state: .recoverableError("Capture failed")) { model.toggleRecording() }
        #expect(model.take == previous)
        #expect(FileManager.default.fileExists(atPath: previous.url.path))
        model.dismissError()
        #expect(model.canSave)
        previousCallback?(.failure(PracticeError("Late callback")))
        #expect(model.take == previous)
        #expect(model.session.state == .paused)
    }

    @Test(arguments: [RecordingMode.audio, .video]) func delayedModePreservesTheRetainedTake(mode: RecordingMode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let model = PracticeModel(capture: capture, storage: root)
        defer { model.playback.clear() }
        model.mode = mode
        if mode == .video { capture.fixture = try await videoFixture(in: root) }
        try await complete(model, capture: capture)
        let original = try #require(model.take)
        model.mode = .video
        model.setDelayedMode(true)
        #expect(!model.canSave)
        model.toggleRecording()
        #expect(capture.requestCount == 1)
        #expect(!model.playback.isPlaying)
        #expect(model.take == original)
        #expect(FileManager.default.fileExists(atPath: original.url.path))
        model.setDelayedMode(false)
        model.mode = mode
        #expect(!model.isDelayedMode)
        #expect(model.take == original)
        #expect(model.canSave)
    }

    @Test func backgroundFinalizationDoesNotResumePlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let model = PracticeModel(capture: capture, storage: root)
        defer { model.playback.clear() }
        await start(model, capture: capture)
        capture.acknowledge()
        model.suspend()
        model.suspend()
        #expect(capture.stopCount == 1)
        await model.resume()
        await waitFor(model, state: .paused) { capture.finish() }
        #expect(model.playback.isReady)
        #expect(!model.playback.isPlaying)
        #expect(model.session.canRecord)
    }

    @Test func saveCancellationRetryAndReplacementProtectExportedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("takes")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let model = PracticeModel(capture: capture, storage: store)
        defer { model.playback.clear() }
        try await complete(model, capture: capture)
        let original = try #require(model.take)
        model.save()
        let cancelled = try #require(model.audioExport)
        #expect(model.session.state == .exporting)
        #expect(!model.playback.isPlaying)
        model.toggleRecording()
        #expect(capture.requestCount == 1)
        model.completeAudioExport(id: UUID(), outcome: .saved)
        #expect(!model.saved)
        model.completeAudioExport(id: cancelled.id, outcome: .cancelled)
        #expect(model.session.state == .paused)
        #expect(model.canSave)
        #expect(model.take == original)
        model.save()
        let export = try #require(model.audioExport)
        let copy = root.appendingPathComponent("export.wav")
        try FileManager.default.copyItem(at: original.url, to: copy)
        let exportedBytes = try Data(contentsOf: copy)
        model.completeAudioExport(id: export.id, outcome: .saved)
        #expect(model.saved)
        #expect(model.session.state == .paused)
        await start(model, capture: capture)
        #expect(model.take == original) // Until confirmed capture start.
        capture.acknowledge()
        #expect(model.take == nil)
        #expect(!FileManager.default.fileExists(atPath: original.url.path))
        model.completeAudioExport(id: export.id, outcome: .saved)
        #expect(!model.saved)
        model.toggleRecording()
        await waitFor(model, state: .replaying) { capture.finish() }
        #expect(try Data(contentsOf: copy) == exportedBytes)
        #expect(model.take?.id != original.id)
    }
    @Test func videoExportFailureCanRetryWithoutLosingTheTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ControlledCapture()
        let exporter = ControlledVideoExport()
        let model = PracticeModel(capture: capture, videoExport: exporter, storage: root.appendingPathComponent("takes"))
        defer { model.playback.clear() }
        capture.fixture = try await videoFixture(in: root)
        model.mode = .video
        try await complete(model, capture: capture)
        let original = try #require(model.take)
        await waitFor(model, state: .recoverableError("Photos failed")) {
            model.save()
            model.save()
        }
        #expect(exporter.calls == 1)
        #expect(model.take == original)
        #expect(!model.saved)
        #expect(FileManager.default.fileExists(atPath: original.url.path))
        model.dismissError()
        exporter.shouldFail = false
        await waitFor(model, state: .paused) { model.save() }
        #expect(exporter.calls == 2)
        #expect(model.saved)
        #expect(model.take == original)
        #expect(!model.playback.isPlaying)
    }

    private func videoFixture(in root: URL) async throws -> URL {
        let url = root.appendingPathComponent("fixture.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw PracticeError("Could not start video fixture writer.") }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel)
        guard status == kCVReturnSuccess, let pixel else { throw PracticeError("Could not allocate video fixture frame.") }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 0, CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline else { throw PracticeError("Video fixture encoder timed out.") }
                try await Task.sleep(for: .milliseconds(10)) // Encoder backpressure, bounded by deadline.
            }
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)) else {
                throw writer.error ?? PracticeError("Video fixture frame was rejected.")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PracticeError("Video fixture did not finish.") }
        return url
    }

}

@MainActor
private final class ControlledCapture: PracticeCapturing {
    var cameraSession: AVCaptureSession? { nil }
    var requestCount = 0
    var preparedPositions: [AVCaptureDevice.Position] = []
    var recordedPosition: AVCaptureDevice.Position?
    var stopCount = 0
    var failStart = false
    var fixture: URL?
    var onRequest: (() -> Void)?
    var started: (() -> Void)?
    var finished: ((Result<URL, Error>) -> Void)?
    private var url: URL?
    func inputs(prepare: Bool) -> [AVAudioSessionPortDescription] { [] }
    func prepareVideo(position: AVCaptureDevice.Position) async throws { preparedPositions.append(position) }
    func stopPreview() async {}
    func start(id: UUID, mode: RecordingMode, url: URL, inputID: String?, position: AVCaptureDevice.Position,
               started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor (Result<URL, Error>) -> Void) async throws {
        requestCount += 1
        recordedPosition = position
        if failStart { throw PracticeError("Capture failed") }
        self.url = url
        self.started = started
        self.finished = finished
        onRequest?()
    }
    func stop(id: UUID) { stopCount += 1 }
    func acknowledge() { started?() }
    func finish() {
        guard let url else { return }
        do {
            if let fixture {
                try FileManager.default.copyItem(at: fixture, to: url)
            } else {
                let generated = try PreviewMedia.makeAudio(in: url.deletingLastPathComponent())
                try FileManager.default.moveItem(at: generated, to: url)
            }
            finished?(.success(url))
        } catch { finished?(.failure(error)) }
    }
}


@MainActor
private final class ControlledVideoExport: VideoExporting {
    var shouldFail = true
    var calls = 0
    func save(_ url: URL) async throws {
        calls += 1
        if shouldFail { throw PracticeError("Photos failed") }
    }
}
