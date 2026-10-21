import SwiftUI

struct DelayedStreamSurface: View {
    @ObservedObject var stream: DelayedStreamModel

    var body: some View {
        ZStack {
            Color.black
            if let image = stream.image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Delayed camera video")
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "video.badge.waveform").font(.largeTitle)
                    Text(stream.isRunning ? "Filling video delay" : "Delayed video").font(.title2)
                    if stream.isRunning {
                        ProgressView(value: stream.buffered, total: Double(stream.delay))
                        Text("\(Int(stream.buffered)) of \(stream.delay) seconds")
                    } else { Text("See your movement \(stream.delay) seconds later.") }
                }.foregroundStyle(.white).padding()
            }
        }
        .accessibilityIdentifier("stream.surface")
    }
}

struct DelayedStreamControls: View {
    @ObservedObject var stream: DelayedStreamModel
    let start: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Stepper("Delay: \(stream.delay) seconds", value: $stream.delay, in: 5...30)
                .disabled(stream.isRunning)
                .accessibilityIdentifier("stream.delay")
            Button(stream.isRunning ? "Stop stream" : "Start stream", systemImage: stream.isRunning ? "stop.fill" : "video.fill") {
                if stream.isRunning { stream.stop() } else { start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(stream.isRunning ? .red : .accentColor)
            .frame(minHeight: 44)
            .accessibilityIdentifier("stream.startStop")
            Group {
                switch stream.state {
                case .starting: Text("Starting camera…")
                case .buffering: Text("Buffering · \(Int(stream.buffered)) / \(stream.delay) seconds")
                case .streaming: Text("\(stream.delay)-second delay · Streaming")
                case .failed(let error): Text(error).foregroundStyle(.red)
                case .stopped: Text("Silent video · Set delay before starting")
                }
            }.font(.footnote).accessibilityIdentifier("stream.status")
        }
    }
}
