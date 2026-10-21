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
            if stream.state == .finishing {
                Color.black.opacity(0.35)
                ProgressView("Preparing clip").tint(.white).foregroundStyle(.white)
            }
        }
        .accessibilityIdentifier("stream.surface")
    }
}

struct DelayedStreamControls: View {
    @ObservedObject var stream: DelayedStreamModel
    let start: () -> Void
    let clip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Stepper("Delay: \(stream.delay) seconds", value: $stream.delay, in: 5...30)
                .disabled(stream.isBusy)
                .accessibilityIdentifier("stream.delay")
            Button(stream.isRunning ? "Stop stream" : "Start stream", systemImage: stream.isRunning ? "stop.fill" : "video.fill") {
                if stream.isRunning { stream.stop() } else { start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(stream.isRunning ? .red : .accentColor)
            .frame(minHeight: 44)
            .accessibilityIdentifier("stream.startStop")
            .disabled(stream.state == .finishing)
            if stream.isRunning || stream.state == .finishing {
                Button("Clip last \(stream.delay) seconds", systemImage: "scissors") { clip() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(!stream.canClip)
                    .accessibilityIdentifier("stream.clip")
            }
            Group {
                switch stream.state {
                case .starting: Text("Starting camera…")
                case .buffering: Text("Buffering · \(Int(stream.buffered)) / \(stream.delay) seconds")
                case .streaming: Text("\(stream.delay)-second delay · Streaming")
                case .finishing: Text("Preparing clip…")
                case .reviewing: Text("Clip ready · Review before saving")
                case .failed(let error): Text(error).foregroundStyle(.red)
                case .stopped: Text("Silent video · Set delay before starting")
                }
            }.font(.footnote).accessibilityIdentifier("stream.status")
        }
    }
}
