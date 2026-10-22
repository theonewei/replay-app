import AVFoundation
import Testing
@testable import Replay

struct RecordingFormatTests {
    @Test func videoFrameRateDefaultsToSixtyAndPersistsSupportedChoices() throws {
        let name = "ReplaySettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(VideoCaptureSettings.frameRate(in: defaults) == 60)
        for rate in [24, 30, 60] {
            defaults.set(rate, forKey: VideoCaptureSettings.key)
            let reopened = try #require(UserDefaults(suiteName: name))
            #expect(VideoCaptureSettings.frameRate(in: reopened) == rate)
        }
        defaults.set(120, forKey: VideoCaptureSettings.key)
        #expect(VideoCaptureSettings.frameRate(in: defaults) == 60)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func losslessMonoPCMAtHardwareRate(sampleRate: Double) throws {
        let settings = try RecordingFormat.settings(sampleRate: sampleRate)
        let format = try #require(AVAudioFormat(settings: settings))
        #expect(format.sampleRate == sampleRate)
        #expect(format.channelCount == 1)
        #expect(format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        #expect(format.streamDescription.pointee.mBitsPerChannel == 24)
    }

    @Test(arguments: [0.0, -1.0, Double.infinity, Double.nan])
    func invalidHardwareRateFails(sampleRate: Double) {
        #expect(throws: PracticeError.self) {
            try RecordingFormat.settings(sampleRate: sampleRate)
        }
    }
}
