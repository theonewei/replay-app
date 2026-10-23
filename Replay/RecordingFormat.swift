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

/// One persisted preference shared by movie capture and delayed video.
enum VideoCaptureSettings {
    static let key = "video.frameRate"
    static let frameRates = [24, 30, 60]
    static func frameRate(in defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: key)
        return frameRates.contains(value) ? value : 60
    }

    /// Select a format that actually supports the requested rate; never silently
    /// substitute a lower rate. Keep capture resolution bounded in delayed mode.
    static func configure(_ device: AVCaptureDevice, frameRate: Int, delayed: Bool) throws {
        guard frameRates.contains(frameRate) else { throw PracticeError("Choose 24, 30, or 60 fps in Settings.") }
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width >= 640 && size.height >= 480 && size.width <= (delayed ? 1280 : 1920) && size.height <= (delayed ? 720 : 1080)
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(frameRate) && $0.maxFrameRate >= Double(frameRate) }
        }
        let ordered = candidates.sorted {
            let left = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return delayed ? abs(left.width * left.height - 640 * 480) < abs(right.width * right.height - 640 * 480) : left.width * left.height > right.width * right.height
        }
        guard let format = ordered.first else {
            throw PracticeError("This camera does not support \(frameRate) fps. Choose another frame rate in Settings.")
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }
}
