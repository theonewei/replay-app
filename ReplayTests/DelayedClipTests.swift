import AVFoundation
import Combine
import Testing
import UIKit
import XCTest
@testable import Replay

@Suite(.serialized)
@MainActor
struct DelayedClipTests {
    static func jpeg(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96), format: format).jpegData(withCompressionQuality: 0.9) { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
    }

    static func fixture(delay: Double) throws -> DelayedFrameBuffer.Clip {
        var buffer = DelayedFrameBuffer(delay: delay)
        for frame in 0...Int(delay + 3) {
            let color: UIColor = frame < 3 ? .green : frame == 3 ? .red : .blue
            _ = try buffer.append(time: 100 + Double(frame), data: jpeg(color))
        }
        return try buffer.clip()
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func wait<T: Publisher>(for publisher: T, matching predicate: @escaping (T.Output) -> Bool, action: (() -> Void)? = nil) async where T.Failure == Never {
        let ready = XCTestExpectation(description: "Expected workflow state")
        let subscription = publisher.dropFirst(action == nil ? 0 : 1).filter(predicate).prefix(1).sink { _ in ready.fulfill() }
        action?()
        #expect(await XCTWaiter.fulfillment(of: [ready], timeout: 15) == .completed)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: [5.0, 15.0, 30.0]) func encodedClipHasExactWindowAndReadableFrames(delay: Double) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try Self.fixture(delay: delay)
        let url = root.appendingPathComponent("clip.mov")
        try await DelayedClipEncoder().encode(clip, to: url)
        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - delay) < 0.02)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        let last = try await generator.image(at: CMTime(seconds: delay - 1, preferredTimescale: 600)).image
        #expect(first.width == 64 && first.height == 96)
        let startColor = try average(first)
        let endColor = try average(last)
        #expect(startColor[0] > startColor[1] + 80 && startColor[0] > startColor[2] + 80)
        #expect(endColor[2] > endColor[0] + 80)
    }

    private func average(_ image: CGImage) throws -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel.map(Int.init)
    }

    @Test func invalidFramesLeaveNoPartialMovie() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invalid.mov")
        let clip = DelayedFrameBuffer.Clip(frames: [.init(time: 0, data: Self.jpeg(.red)), .init(time: 1, data: Data([1]))], startTime: 0, endTime: 5)
        await #expect(throws: (any Error).self) { try await DelayedClipEncoder().encode(clip, to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [false, true]) func reviewIsPausedSaveCanRetryAndDiscardKeepsExportedCopy(saveRequested: Bool) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ClipTestDriver(clip: try Self.fixture(delay: 15))
        let stream = DelayedStreamModel(driver: driver)
        let exporter = ClipTestExporter(destination: root.appendingPathComponent("export.mov"))
        let model = PracticeModel(capture: ClipTestCapture(), videoExport: exporter, storage: root, delayed: stream)
        defer { model.playback.clear(); stream.stop() }
        model.mode = .video
        model.setDelayedMode(true)
        await model.startDelayedStream()
        await wait(for: stream.$state, matching: { $0 == .buffering })
        #expect(!stream.canClip)
        await driver.ready()
        stream.poll()
        #expect(stream.canClip)
        await wait(for: model.$session, matching: { $0.state == .paused }) { model.clipDelayedStream(); model.clipDelayedStream() }
        #expect(await driver.clipCount == 1)
        #expect(await driver.active == false)
        #expect(model.reviewingDelayedClip)
        #expect(model.playback.isReady && !model.playback.isPlaying)
        #expect(model.playback.duration == 15)
        #expect(exporter.calls == 0)
        let url = try #require(model.takeURL)
        model.playback.seek(to: 7)
        #expect(model.playback.position == 7)
        model.suspend()
        await model.resume()
        #expect(model.reviewingDelayedClip && !model.playback.isPlaying)
        if saveRequested {
            await wait(for: model.$session, matching: { $0.state == .recoverableError("Photos failed") }) { model.save() }
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(!model.saved)
            model.dismissError()
            exporter.fail = false
            await wait(for: model.$session, matching: { $0.state == .paused }) { model.save(); model.save() }
            #expect(exporter.calls == 2 && model.saved)
        } else { #expect(exporter.calls == 0) }
        model.discardDelayedClip()
        #expect(model.take == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: exporter.destination.path) == saveRequested)
        #expect(stream.state == .stopped)
    }

    @Test func cancellingClipRejectsLateEncodingAndCleansTheFile() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ClipTestDriver(clip: try Self.fixture(delay: 15))
        let entered = XCTestExpectation(description: "Encoder is pending after capture stopped")
        let encoder = SuspendedClipEncoder(entered: entered)
        let stream = DelayedStreamModel(driver: driver, encoder: encoder)
        var accepted = false
        stream.onClipReady = { _ in accepted = true; return true }
        await wait(for: stream.$state, matching: { $0 == .buffering }) { stream.start() }
        await driver.ready()
        stream.poll()
        let url = root.appendingPathComponent("cancelled.mov")
        let operation = try #require(stream.makeClip(to: url))
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed)
        #expect(await driver.active == false)
        stream.stop()
        await encoder.release()
        await operation.value
        #expect(!accepted)
        #expect(stream.state == .stopped)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private actor SuspendedClipEncoder: DelayedClipEncoding {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func encode(_ clip: DelayedFrameBuffer.Clip, to url: URL) async throws {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered.fulfill() }
        // Deliberately ignores cancellation to exercise stale-completion cleanup.
        try Data([1]).write(to: url)
    }
    func release() { continuation?.resume(); continuation = nil }
}

struct FailingClipEncoder: DelayedClipEncoding {
    func encode(_ clip: DelayedFrameBuffer.Clip, to url: URL) async throws { throw PracticeError("Encoding failed") }
}

actor ClipTestDriver: DelayedVideoCapturing {
    var active = false
    var clipCount = 0
    private let snapshot: DelayedFrameBuffer.Clip
    private var mailbox: StreamMailbox?
    init(clip: DelayedFrameBuffer.Clip) { snapshot = clip }
    func start(id: UUID, delay: Double, mailbox: StreamMailbox) async throws { active = true; self.mailbox = mailbox }
    func ready() { mailbox?.put(.init(data: snapshot.frames[0].data, buffered: snapshot.duration, measuredDelay: snapshot.duration, error: nil)) }
    func clip(id: UUID) async throws -> DelayedFrameBuffer.Clip { active = false; clipCount += 1; return snapshot }
    func stop(id: UUID) async { active = false }
}

@MainActor
private final class ClipTestExporter: VideoExporting {
    let destination: URL
    var fail = true
    var calls = 0
    init(destination: URL) { self.destination = destination }
    func save(_ url: URL) async throws {
        calls += 1
        if fail { throw PracticeError("Photos failed") }
        try FileManager.default.copyItem(at: url, to: destination)
    }
}

@MainActor
private final class ClipTestCapture: PracticeCapturing {
    var cameraSession: AVCaptureSession? { nil }
    func inputs(prepare: Bool) -> [AVAudioSessionPortDescription] { [] }
    func prepareVideo(position: AVCaptureDevice.Position) async throws {}
    func stopPreview() async {}
    func stop(id: UUID) {}
    func start(id: UUID, mode: RecordingMode, url: URL, inputID: String?, position: AVCaptureDevice.Position,
               started: @escaping @MainActor () -> Void, finished: @escaping @MainActor (Result<URL, Error>) -> Void) async throws {}
}
