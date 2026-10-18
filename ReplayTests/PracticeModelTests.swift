import AVFoundation
import Combine
import CoreVideo
import Testing
import XCTest
@testable import Replay

@Suite(.serialized)
@MainActor
struct PracticeModelTests {
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
    var stopCount = 0
    var failStart = false
    var fixture: URL?
    var onRequest: (() -> Void)?
    var started: (() -> Void)?
    var finished: ((Result<URL, Error>) -> Void)?
    private var url: URL?
    func inputs(prepare: Bool) -> [AVAudioSessionPortDescription] { [] }
    func prepareVideo(position: AVCaptureDevice.Position) async throws {}
    func stopPreview() async {}
    func start(id: UUID, mode: RecordingMode, url: URL, inputID: String?, position: AVCaptureDevice.Position,
               started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor (Result<URL, Error>) -> Void) async throws {
        requestCount += 1
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
