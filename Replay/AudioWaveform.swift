import Foundation

/// A three-second visual envelope of recorder power, sampled at 20 Hz.
/// This never changes the audio samples written by the recorder.
struct AudioWaveform {
    static let sampleInterval = 0.05
    static let capacity = 60
    private(set) var samples: [Double] = []
    var latest: Double { samples.last ?? 0 }

    mutating func append(decibels: Float) {
        guard decibels.isFinite else { return }
        let level = Double(min(0, max(-60, decibels)) + 60) / 60
        if samples.count == Self.capacity { samples.removeFirst() }
        samples.append(level)
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }
}

#if !SWIFT_PACKAGE
import SwiftUI

struct RecordingWaveformView: View {
    let waveform: AudioWaveform
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            Text(reduceMotion ? "Microphone level" : "Live waveform").font(.title3)
            if reduceMotion {
                ProgressView(value: waveform.latest).tint(.red).frame(minHeight: 40, idealHeight: 80, maxHeight: 120)
            } else {
                Canvas { context, size in
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                    baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    let padding = AudioWaveform.capacity - waveform.samples.count
                    let spacing = size.width / Double(AudioWaveform.capacity)
                    var bars = Path()
                    for (index, value) in waveform.samples.enumerated() where value > 0 {
                        let x = (Double(index + padding) + 0.5) * spacing
                        let height = max(2, value * size.height * 0.9)
                        bars.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                        bars.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                    }
                    context.stroke(bars, with: .color(.red), style: StrokeStyle(lineWidth: max(1, spacing * 0.55), lineCap: .round))
                }.frame(minHeight: 40, idealHeight: 140, maxHeight: 180)
            }
            Text(waveform.samples.isEmpty ? "Listening…" : waveform.latest < 0.02 ? "Quiet" : "Microphone input")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live audio waveform")
        .accessibilityValue(waveform.samples.isEmpty ? "Waiting for microphone" : waveform.latest < 0.02 ? "Quiet" : "Input level \(Int(waveform.latest * 100)) percent")
        .accessibilityIdentifier("audio.waveform")
    }
}
#endif
