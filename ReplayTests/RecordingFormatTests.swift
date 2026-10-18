import AVFoundation
import Testing
@testable import Replay

struct RecordingFormatTests {
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
