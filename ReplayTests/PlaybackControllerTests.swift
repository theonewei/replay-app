import AVFoundation
import Combine
import Testing
import XCTest
@testable import Replay

@Suite(.serialized)
@MainActor
struct PlaybackControllerTests {
    private func fixture(duration: Double = 0.6) throws -> URL {
        try PreviewMedia.makeAudio(in: FileManager.default.temporaryDirectory, duration: duration)
    }

    private func ready(_ playback: PlaybackController, url: URL, autoplay: Bool = false) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let expectation = XCTestExpectation(description: "Player is ready")
        let subscription = playback.$isReady.dropFirst().filter { $0 }.prefix(1).sink { _ in expectation.fulfill() }
        playback.load(url, autoplay: autoplay)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10)
        #expect(result == .completed)
        withExtendedLifetime(subscription) {}
    }

    private func reachedEnd(_ playback: PlaybackController, action: () -> Void) async {
        let expectation = XCTestExpectation(description: "Playback stops at the end")
        let subscription = playback.$isPlaying.dropFirst().filter { !$0 }.prefix(1).sink { _ in expectation.fulfill() }
        action()
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 5)
        #expect(result == .completed)
        withExtendedLifetime(subscription) {}
    }

    @Test func playsOnceByDefaultAndCanReplay() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = PlaybackController()
        defer { playback.clear() }
        #expect(!playback.loopEnabled)
        await ready(playback, url: url, autoplay: true)
        #expect(abs(playback.duration - 0.6) < 0.01)
        await reachedEnd(playback) {}
        #expect(!playback.isPlaying)
        #expect(playback.position == playback.duration)
        // Replaying from the end seeks to zero and plays a second time.
        await reachedEnd(playback) { playback.play() }
        #expect(playback.position == playback.duration)
    }

    @Test func loopCanBeEnabledThenDisabled() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = PlaybackController()
        defer { playback.clear() }
        await ready(playback, url: url)
        playback.loopEnabled = true
        let repeated = XCTestExpectation(description: "Fixture reaches its end twice")
        repeated.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playback.player?.currentItem, queue: .main
        ) { _ in repeated.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        playback.play()
        #expect(await XCTWaiter.fulfillment(of: [repeated], timeout: 5) == .completed)
        #expect(playback.isPlaying)
        await reachedEnd(playback) { playback.loopEnabled = false }
        #expect(!playback.isPlaying)
    }

    @Test func pausedSeekingDoesNotStartPlaybackAndClampsTime() async throws {
        let url = try fixture(duration: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = PlaybackController()
        defer { playback.clear() }
        await ready(playback, url: url)
        playback.seek(to: -5)
        #expect(playback.position == 0)
        playback.seek(to: 7)
        #expect(playback.position == 7)
        #expect(!playback.isPlaying)
        playback.seek(to: 99)
        #expect(playback.position == 12)
        #expect(!playback.isPlaying)
    }

    @Test func pauseDuringLoopSeekDoesNotResume() async throws {
        let url = try fixture(duration: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = PlaybackController()
        defer { playback.clear() }
        await ready(playback, url: url)
        playback.loopEnabled = true
        playback.play()
        let sought = XCTestExpectation(description: "A seek after Pause completes")
        let observer = playback.player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { time in
            if time.seconds >= 3 { sought.fulfill() }
        }
        defer { if let observer { playback.player?.removeTimeObserver(observer) } }
        playback.seek(to: 3)
        playback.pause()
        #expect(await XCTWaiter.fulfillment(of: [sought], timeout: 5) == .completed)
        #expect(!playback.isPlaying)
        #expect(playback.player?.rate == 0)
    }

    @Test func replacingTakeInvalidatesPendingSeek() async throws {
        let first = try fixture(duration: 12)
        let second = try fixture(duration: 2)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let playback = PlaybackController()
        defer { playback.clear() }
        await ready(playback, url: first)
        playback.play()
        playback.seek(to: 8)
        await ready(playback, url: second)
        #expect(playback.duration == 2)
        #expect(!playback.isPlaying)
        #expect(playback.player?.rate == 0)
        #expect(playback.position == 0)
    }
}
