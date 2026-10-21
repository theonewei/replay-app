import AVFoundation
import Combine
import UIKit

@MainActor
final class DelayedStreamModel: ObservableObject {
    enum State: Equatable { case stopped, starting, buffering, streaming, finishing, reviewing, failed(String) }
    @Published private(set) var state: State = .stopped
    @Published private(set) var image: UIImage?
    @Published private(set) var buffered = 0.0
    @Published private(set) var measuredDelay: Double?
    @Published var delay = 15
    var isRunning: Bool { state == .starting || state == .buffering || state == .streaming }
    var isBusy: Bool { isRunning || state == .finishing }
    var canClip: Bool { state == .streaming && buffered >= Double(delay) - 0.001 }
    var onClipReady: ((URL) -> Bool)?
    private let driver: any DelayedVideoCapturing
    private let encoder: any DelayedClipEncoding
    private var mailbox = StreamMailbox()
    private var id: UUID?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var lastUpdate = ProcessInfo.processInfo.systemUptime

    init(driver: (any DelayedVideoCapturing)? = nil, encoder: any DelayedClipEncoding = DelayedClipEncoder()) {
        self.encoder = encoder
        #if DEBUG
        self.driver = driver ?? (ProcessInfo.processInfo.arguments.contains("--fixture-stream") ? FixtureDelayedVideoCapture() : DelayedVideoCapture())
        #else
        self.driver = driver ?? DelayedVideoCapture()
        #endif
    }

    func start() {
        guard !isBusy, (5...30).contains(delay) else { return }
        let id = UUID()
        self.id = id
        mailbox = StreamMailbox()
        let mailbox = self.mailbox
        state = .starting
        UIApplication.shared.isIdleTimerDisabled = true
        image = nil
        buffered = 0
        measuredDelay = nil
        let driver = self.driver
        let seconds = Double(delay)
        task = Task { [weak self] in
            do {
                try await driver.start(id: id, delay: seconds, mailbox: mailbox)
                guard let self, self.id == id, !Task.isCancelled else { await driver.stop(id: id); return }
                self.state = .buffering
                self.lastUpdate = ProcessInfo.processInfo.systemUptime
                self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.poll(id: id) }
                }
            } catch {
                guard let self, self.id == id else { return }
                self.stop()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func poll(id: UUID? = nil) {
        guard isRunning, id == nil || self.id == id else { return }
        guard let update = mailbox.take() else {
            if ProcessInfo.processInfo.systemUptime - lastUpdate > 3 {
                stop()
                state = .failed("The camera stopped sending video. Start again to refill the delay.")
            }
            return
        }
        lastUpdate = ProcessInfo.processInfo.systemUptime
        if let error = update.error { stop(); state = .failed(error); return }
        buffered = update.buffered
        measuredDelay = update.measuredDelay
        if let data = update.data, let image = UIImage(data: data) {
            self.image = image
            state = .streaming
        } else if update.buffered < Double(delay) {
            image = nil
            state = .buffering
        }
    }

    func stop() {
        let oldID = id
        id = nil
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        image = nil
        buffered = 0
        measuredDelay = nil
        state = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
        let driver = self.driver
        if let oldID { Task { await driver.stop(id: oldID) } }
    }

    @discardableResult
    func makeClip(to url: URL) -> Task<Void, Never>? {
        guard canClip, let id, !FileManager.default.fileExists(atPath: url.path) else { return nil }
        timer?.invalidate()
        timer = nil
        state = .finishing
        UIApplication.shared.isIdleTimerDisabled = false
        let driver = self.driver
        let encoder = self.encoder
        task = Task { [weak self] in
            do {
                let clip = try await driver.clip(id: id)
                try Task.checkCancellation()
                try await encoder.encode(clip, to: url)
                guard let self, self.id == id, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard self.onClipReady?(url) == true else { throw PracticeError("The clip could not be opened. Please try again.") }
                self.id = nil
                self.image = nil
                self.state = .reviewing
            } catch {
                await driver.stop(id: id)
                try? FileManager.default.removeItem(at: url)
                guard let self, self.id == id else { return }
                self.stop()
                self.state = .failed(error.localizedDescription)
            }
        }
        return task
    }

    isolated deinit {
        timer?.invalidate()
        task?.cancel()
        let driver = self.driver
        if let id { Task { await driver.stop(id: id) } }
    }
}
