#if DEBUG
import AVFoundation
import UIKit

/// Generated silence for simulator previews and playback tests. Never captures input.
enum PreviewMedia {
    static func makeVideo(in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("Preview-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 480
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw PracticeError("Could not create preview video.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline else { throw PracticeError("Preview encoder timed out.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 480, kCVPixelFormatType_32ARGB, nil, &pixel)
            guard let pixel else { throw PracticeError("Could not create preview frame.") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, Int32(30 + frame * 12), CVPixelBufferGetDataSize(pixel)) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else {
                throw PracticeError("Could not encode preview frame.")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 12, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw PracticeError("Could not finish preview video.") }
        return url
    }

    private static let audioAmplitudes: [Float] = [0, 0.003, 0.02, 0.15, 0.55, 0.06]
    static func audioAmplitude(at time: Double) -> Float { audioAmplitudes[Int(max(0, time)) % audioAmplitudes.count] }
    static func audioPower(at time: Double) -> Float {
        let amplitude = audioAmplitude(at: time)
        return amplitude > 0 ? 20 * log10(amplitude) - 3.0103 : -160
    }

    static func makeAudio(in folder: URL, duration: Double = 12, waveform: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent("Preview-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16
        ])
        let frames = AVAudioFrameCount(44_100 * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else {
            throw PracticeError("Could not create the preview recording.")
        }
        buffer.frameLength = frames
        if waveform {
            for index in 0..<Int(frames) {
                let time = Double(index) / 44_100
                samples[index] = audioAmplitude(at: time) * Float(sin(2 * Double.pi * 220 * time))
            }
        } else { samples.update(repeating: 0, count: Int(frames)) }
        try file.write(from: buffer)
        return url
    }
}
#endif

#if DEBUG
@MainActor
final class FixtureCaptureDriver: PracticeCapturing {
    var cameraSession: AVCaptureSession? { nil }
    private var id: UUID?
    private var url: URL?
    private var finished: ((Result<URL, Error>) -> Void)?
    private var starts = 0
    private var began: Double?
    func inputs(prepare: Bool) -> [AVAudioSessionPortDescription] { [] }
    func prepareVideo(position: AVCaptureDevice.Position) async throws {}
    func stopPreview() async {}
    func start(id: UUID, mode: RecordingMode, url: URL, inputID: String?, position: AVCaptureDevice.Position,
               started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor (Result<URL, Error>) -> Void) async throws {
        guard mode == .audio else { throw PracticeError("This test harness provides audio fixtures only.") }
        starts += 1
        if starts == 2, ProcessInfo.processInfo.arguments.contains("--fail-second-start") {
            throw PracticeError("Recording could not start. Your previous take is still available.")
        }
        self.id = id
        self.url = url
        self.finished = finished
        began = ProcessInfo.processInfo.systemUptime
        started()
    }
    func audioPower(id: UUID) -> Float? {
        guard self.id == id, let began, ProcessInfo.processInfo.arguments.contains("--fixture-waveform") else { return nil }
        return PreviewMedia.audioPower(at: ProcessInfo.processInfo.systemUptime - began)
    }
    func stop(id: UUID) {
        guard self.id == id, let url else { return }
        let callback = finished
        self.id = nil
        began = nil
        finished = nil
        do {
            let fixture = try PreviewMedia.makeAudio(in: url.deletingLastPathComponent(), waveform: ProcessInfo.processInfo.arguments.contains("--fixture-waveform"))
            try FileManager.default.moveItem(at: fixture, to: url)
            callback?(.success(url))
        } catch { callback?(.failure(error)) }
    }
}

/// An animated, timestamped source exercises the real delay buffer without a camera.
actor FixtureDelayedVideoCapture: DelayedVideoCapturing {
    private var id: UUID?
    private var task: Task<Void, Never>?
    private var buffer: DelayedFrameBuffer?

    func start(id: UUID, delay: Double, frameRate: Int, mailbox: StreamMailbox) async throws {
        self.id = id
        buffer = DelayedFrameBuffer(delay: delay)
        task = Task { [weak self] in await self?.produce(id: id, frameRate: frameRate, mailbox: mailbox) }
    }

    private func produce(id: UUID, frameRate: Int, mailbox: StreamMailbox) async {
        let began = ProcessInfo.processInfo.systemUptime
        let speed = ProcessInfo.processInfo.arguments.contains("--fast-stream") ? 5.0 : 1.0
        while self.id == id, !Task.isCancelled {
            let time = (ProcessInfo.processInfo.systemUptime - began) * speed
            let data = await Self.image(time: time)
            guard self.id == id, !Task.isCancelled, buffer != nil else { return }
            do {
                let frame = try buffer?.append(time: time, data: data)
                mailbox.put(StreamUpdate(data: frame?.data ?? data, buffered: buffer?.buffered ?? 0,
                                         measuredDelay: frame.map { time - $0.time }, error: nil, sourceTime: frame?.time, isLive: frame == nil))
            } catch { return }
            try? await Task.sleep(for: .seconds(1.0 / Double(frameRate)))
        }
    }

    func clip(id: UUID, endingAt: Double) async throws -> DelayedFrameBuffer.Clip {
        guard self.id == id, let buffer else { throw PracticeError("The stream is no longer available.") }
        let clip = try buffer.clip(endingAt: endingAt)
        await stop(id: id)
        return clip
    }

    func stop(id: UUID) async {
        guard self.id == id else { return }
        task?.cancel()
        task = nil
        buffer = nil
        self.id = nil
    }

    @MainActor private static func image(time: Double) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 640), format: format).jpegData(withCompressionQuality: 0.65) { context in
            UIColor(hue: (time.truncatingRemainder(dividingBy: 12)) / 12, saturation: 0.7, brightness: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 640))
            let text = "Camera fixture\n\(String(format: "%.1f", time)) seconds"
            (text as NSString).draw(in: CGRect(x: 35, y: 240, width: 410, height: 160), withAttributes: [
                .font: UIFont.systemFont(ofSize: 38, weight: .medium), .foregroundColor: UIColor.white
            ])
        }
    }
}
#endif
