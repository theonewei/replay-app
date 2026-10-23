import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ReplayCore
#else
@testable import Replay
#endif

struct AudioWaveformTests {
    @Test func silenceQuietAndLoudInputRemainOrderedAndClamped() {
        var waveform = AudioWaveform()
        for power: Float in [-160, -60, -45, -15, 0, 20] { waveform.append(decibels: power) }
        #expect(waveform.samples == [0, 0, 0.25, 0.75, 1, 1])
        waveform.append(decibels: .nan)
        waveform.append(decibels: .infinity)
        #expect(waveform.samples.count == 6)
    }

    @Test func longRecordingsStayBoundedAndResetHasNoOldActivity() {
        var waveform = AudioWaveform()
        for _ in 0..<10_000 { waveform.append(decibels: -12) }
        #expect(waveform.samples.count == AudioWaveform.capacity)
        #expect(waveform.latest == 0.8)
        waveform.reset()
        #expect(waveform.samples.isEmpty && waveform.latest == 0)
        waveform.append(decibels: -160)
        #expect(waveform.samples == [0])
    }
}
