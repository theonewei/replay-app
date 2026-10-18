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
