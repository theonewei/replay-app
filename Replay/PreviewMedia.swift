#if DEBUG
import AVFoundation

/// Generated silence for simulator previews and playback tests. Never captures input.
enum PreviewMedia {
    static func makeAudio(in folder: URL, duration: Double = 12) throws -> URL {
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
        samples.update(repeating: 0, count: Int(frames))
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
        started()
    }
    func stop(id: UUID) {
        guard self.id == id, let url else { return }
        let callback = finished
        self.id = nil
        finished = nil
        do {
            let fixture = try PreviewMedia.makeAudio(in: url.deletingLastPathComponent())
            try FileManager.default.moveItem(at: fixture, to: url)
            callback?(.success(url))
        } catch { callback?(.failure(error)) }
    }
}
#endif
