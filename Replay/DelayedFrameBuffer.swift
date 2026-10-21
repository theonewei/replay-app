import Foundation

/// A timestamp-based compressed-frame queue. No camera buffers or decoded images
/// are retained. Limits are enforced before accepting another frame.
struct DelayedFrameBuffer {
    struct Frame: Sendable {
        let time: Double
        let data: Data
    }
    enum BufferError: Error { case invalidTimestamp, capacityExceeded }
    let delay: Double
    let byteLimit: Int
    let frameLimit: Int
    private(set) var frames: [Frame] = []
    private(set) var bytes = 0
    private(set) var buffered = 0.0
    private var firstTime: Double?
    private var lastTime: Double?

    init(delay: Double, byteLimit: Int = 64 * 1024 * 1024, frameLimit: Int = 600) {
        precondition(delay.isFinite && delay > 0 && delay <= 30)
        self.delay = delay
        self.byteLimit = byteLimit
        self.frameLimit = frameLimit
    }

    mutating func append(time: Double, data: Data) throws -> Frame? {
        guard time.isFinite, lastTime.map({ time > $0 }) ?? true else { throw BufferError.invalidTimestamp }
        // A capture gap starts a fresh history rather than mislabelling a stale
        // image as having the selected delay.
        if let lastTime, time - lastTime > 1 { reset() }
        if firstTime == nil { firstTime = time }
        lastTime = time
        buffered = min(delay, time - (firstTime ?? time))
        let target = time - delay
        var selected: Frame?
        while let first = frames.first, first.time <= target + 1e-9 {
            selected = frames.removeFirst()
            bytes -= first.data.count
        }
        guard data.count <= byteLimit - bytes, frames.count < frameLimit else { throw BufferError.capacityExceeded }
        frames.append(Frame(time: time, data: data))
        bytes += data.count
        return selected
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: false)
        bytes = 0
        buffered = 0
        firstTime = nil
        lastTime = nil
    }
}
