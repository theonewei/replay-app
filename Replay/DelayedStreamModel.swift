import AVFoundation
import Combine
import UIKit

@MainActor
final class DelayedStreamModel: ObservableObject {
    enum State: Equatable { case stopped, previewing, starting, buffering, streaming, finishing, reviewing, failed(String) }
    @Published private(set) var state: State = .stopped
    @Published private(set) var image: UIImage?
    @Published private(set) var buffered = 0.0
    @Published private(set) var measuredDelay: Double?
    @Published var delay = 15
    @Published private(set) var viewed = 0.0
    @Published private(set) var isLive = false
    private var viewedStart: Double?
    private var viewedEnd: Double?
    var isPreviewing: Bool { state == .previewing }
    var isRunning: Bool { state == .starting || state == .buffering || state == .streaming }
    var isBusy: Bool { isRunning || state == .finishing }
    var canClip: Bool { state == .streaming && viewed >= Double(delay) - 0.001 }
    var onClipReady: ((URL) -> Bool)?
    private let driver: any DelayedVideoCapturing
    private let encoder: any DelayedClipEncoding
    private var mailbox = StreamMailbox()
    private var id: UUID?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var previewFrameRate: Int?
    private var lastUpdate = ProcessInfo.processInfo.systemUptime

    init(driver: (any DelayedVideoCapturing)? = nil, encoder: any DelayedClipEncoding = DelayedClipEncoder()) {
        self.encoder = encoder
        #if DEBUG
        self.driver = driver ?? (ProcessInfo.processInfo.arguments.contains("--fixture-stream") ? FixtureDelayedVideoCapture() : DelayedVideoCapture())
        #else
        self.driver = driver ?? DelayedVideoCapture()
        #endif
    }

    func preview() {
        guard !isBusy, state != .reviewing else { return }
        if isPreviewing, previewFrameRate == VideoCaptureSettings.frameRate() { return }
        begin(preview: true)
    }

    func start() {
        guard !isBusy, (5...60).contains(delay) else { return }
        begin(preview: false)
    }

    private func begin(preview: Bool) {
        let oldID = id
        let previousTask = task
        let previousCleanup = cleanup
        previousTask?.cancel()
        timer?.invalidate()
        timer = nil
        let id = UUID()
        self.id = id
        mailbox = StreamMailbox()
        let mailbox = self.mailbox
        state = preview ? .previewing : .starting
        UIApplication.shared.isIdleTimerDisabled = !preview
        if !isLive { image = nil }
        buffered = 0
        measuredDelay = nil
        viewed = 0
        viewedStart = nil
        viewedEnd = nil
        isLive = image != nil
        let driver = self.driver
        let seconds = Double(delay)
        let frameRate = VideoCaptureSettings.frameRate()
        previewFrameRate = preview ? frameRate : nil
        task = Task { [weak self] in
            await previousCleanup?.value
            await previousTask?.value
            if let oldID { await driver.stop(id: oldID) }
            do {
                try Task.checkCancellation()
                if preview { try await driver.preview(id: id, frameRate: frameRate, mailbox: mailbox) }
                else { try await driver.start(id: id, delay: seconds, frameRate: frameRate, mailbox: mailbox) }
                guard let self, self.id == id, !Task.isCancelled else { await driver.stop(id: id); return }
                self.state = preview ? .previewing : .buffering
                self.lastUpdate = ProcessInfo.processInfo.systemUptime
                self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(frameRate), repeats: true) { [weak self] _ in
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
        guard isRunning || isPreviewing, id == nil || self.id == id else { return }
        guard let update = mailbox.take() else {
            if ProcessInfo.processInfo.systemUptime - lastUpdate > 3 {
                stop()
                state = .failed("The camera stopped sending video. Start again to refill the delay.")
            }
            return
        }
        lastUpdate = ProcessInfo.processInfo.systemUptime
        if let error = update.error { stop(); state = .failed(error); return }
        buffered = isPreviewing ? 0 : update.buffered
        measuredDelay = isPreviewing ? nil : update.measuredDelay
        if let data = update.data, let image = UIImage(data: data) {
            self.image = image
            isLive = update.isLive
            if update.isLive || isPreviewing {
                isLive = true
                state = isPreviewing ? .previewing : .buffering
                viewedStart = nil
                viewedEnd = nil
                viewed = 0
            } else {
                if let time = update.sourceTime {
                    if viewedStart == nil || viewedEnd.map({ time < $0 || time - $0 > 1 }) == true { viewedStart = time }
                    viewedEnd = time
                    viewed = min(Double(delay), time - (viewedStart ?? time))
                }
                state = .streaming
            }
        } else if update.buffered < Double(delay) {
            image = nil
            state = .buffering
        }
    }

    func stop() {
        let oldID = id
        let previousTask = task
        let previousCleanup = cleanup
        id = nil
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        image = nil
        buffered = 0
        measuredDelay = nil
        viewed = 0
        viewedStart = nil
        viewedEnd = nil
        isLive = false
        state = .stopped
        UIApplication.shared.isIdleTimerDisabled = false
        let driver = self.driver
        cleanup = Task {
            await previousCleanup?.value
            await previousTask?.value
            if let oldID { await driver.stop(id: oldID) }
        }
    }

    @discardableResult
    func makeClip(to url: URL) -> Task<Void, Never>? {
        guard canClip, let id, let endingAt = viewedEnd, !FileManager.default.fileExists(atPath: url.path) else { return nil }
        timer?.invalidate()
        timer = nil
        state = .finishing
        UIApplication.shared.isIdleTimerDisabled = false
        let driver = self.driver
        let encoder = self.encoder
        task = Task { [weak self] in
            do {
                let clip = try await driver.clip(id: id, endingAt: endingAt)
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
