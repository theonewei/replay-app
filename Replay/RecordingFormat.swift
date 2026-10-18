import AVFoundation

/// Preserves the prototype's mono, lossless PCM capture format.
struct RecordingFormat {
    static func settings(sampleRate: Double) throws -> [String: Any] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw PracticeError("The microphone has no supported sample rate. Please try another input.")
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }
}
