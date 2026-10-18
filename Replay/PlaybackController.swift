import AVFoundation
import Combine
import UIKit

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published var loopEnabled = false

    var onError: ((String) -> Void)?
    private var wantsToPlay = false
    private var isScrubbing = false
    private var isSeeking = false
    private var generation = UUID()
    private var seekID = UUID()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var durationTask: Task<Void, Never>?

    var positionLabel: String { Self.timeLabel(position) }
    var durationLabel: String { Self.timeLabel(duration) }
    var hasFinished: Bool { isReady && !isPlaying && position >= duration }

    func load(_ url: URL, autoplay: Bool = true) {
        clear()
        let generation = self.generation
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let next = AVPlayer(playerItem: item)
        next.actionAtItemEnd = .pause
        player = next
        wantsToPlay = autoplay

        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if item.status == .failed {
                    self.fail(item.error?.localizedDescription ?? "This take could not be played.")
                } else {
                    self.startWhenReady()
                }
            }
        }
        timeObserver = next.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      !self.isScrubbing, !self.isSeeking else { return }
                self.position = self.clamped(time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.didReachEnd()
            }
        }
        durationTask = Task { [weak self] in
            do {
                let seconds = try await asset.load(.duration).seconds
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                guard seconds.isFinite, seconds > 0 else {
                    self.fail("This recording is empty or could not be read. Please record another take.")
                    return
                }
                self.duration = seconds
                self.startWhenReady()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func startWhenReady() {
        guard !isReady, duration > 0, player?.currentItem?.status == .readyToPlay else { return }
        isReady = true
        if wantsToPlay { play() }
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard isReady, let player, UIApplication.shared.applicationState == .active else { return }
        wantsToPlay = true
        isPlaying = true
        if position >= duration {
            seek(to: 0)
        } else if !isSeeking, !isScrubbing {
            player.play()
        }
    }

    func pause() {
        wantsToPlay = false
        isPlaying = false
        player?.pause()
    }

    func beginScrubbing() {
        guard isReady else { return }
        isScrubbing = true
        player?.pause()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: position)
    }

    func seek(to seconds: Double) {
        guard isReady, let player else { return }
        let destination = clamped(seconds)
        position = destination
        isSeeking = true
        let requestID = UUID()
        let generation = self.generation
        seekID = requestID
        player.pause()
        player.seek(to: CMTime(seconds: destination, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.seekID == requestID else { return }
                self.isSeeking = false
                guard finished else { self.pause(); return }
                if destination >= self.duration {
                    // Scrubbing to the end stops even when Loop is enabled.
                    self.pause()
                } else if self.wantsToPlay, !self.isScrubbing,
                          UIApplication.shared.applicationState == .active {
                    self.player?.play()
                }
            }
        }
    }

    private func didReachEnd() {
        guard !isSeeking, !isScrubbing, wantsToPlay else { return }
        if loopEnabled, UIApplication.shared.applicationState == .active {
            seek(to: 0)
        } else {
            position = duration
            pause()
        }
    }

    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), duration)
    }

    private func fail(_ message: String) {
        pause()
        isReady = false
        onError?(message)
    }

    func clear() {
        generation = UUID()
        seekID = UUID()
        durationTask?.cancel()
        durationTask = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        wantsToPlay = false
        isScrubbing = false
        isSeeking = false
        isPlaying = false
        isReady = false
        position = 0
        duration = 0
    }

    isolated deinit {
        durationTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
    }

    static func timeLabel(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
