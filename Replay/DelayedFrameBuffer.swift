import Foundation

/// A timestamp-based compressed-frame queue. No camera buffers or decoded images
/// are retained. Limits are enforced before accepting another frame.
struct DelayedFrameBuffer {
    struct Frame: Sendable {
        let time: Double
        let data: Data
    }
    struct Clip: Sendable {
        let frames: [Frame]
        let startTime: Double
        let endTime: Double
        var duration: Double { endTime - startTime }
    }
    enum BufferError: Error { case invalidTimestamp, capacityExceeded, insufficientHistory }
    let delay: Double
    let byteLimit: Int
    let frameLimit: Int
    private(set) var frames: [Frame] = []
    private(set) var bytes = 0
    private(set) var buffered = 0.0
    private var firstTime: Double?
    private var lastTime: Double?

    init(delay: Double, byteLimit: Int = 256 * 1024 * 1024, frameLimit: Int = 7_500) {
        precondition(delay.isFinite && delay > 0 && delay <= 60)
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
        let retentionStart = time - 2 * delay - 3
        // Keep one predecessor at the left boundary. It supplies the exact
        // first frame of a clip when the chosen start falls between samples.
        while frames.count > 1, frames[1].time <= retentionStart + 1e-9 {
            bytes -= frames.removeFirst().data.count
        }
        let selected = frames.last { $0.time <= target + 1e-9 }
        guard data.count <= byteLimit - bytes, frames.count < frameLimit else { throw BufferError.capacityExceeded }
        frames.append(Frame(time: time, data: data))
        bytes += data.count
        return selected
    }

    /// The endpoint comes from the displayed frame, never from the capture head.
    func clip(endingAt endTime: Double) throws -> Clip {
        guard endTime.isFinite, let lastTime, endTime <= lastTime - delay + 1e-9,
              let first = frames.first, first.time <= endTime - delay + 1e-9 else {
            throw BufferError.insufficientHistory
        }
        let start = endTime - delay
        guard let predecessor = frames.lastIndex(where: { $0.time <= start + 1e-9 }) else {
            throw BufferError.insufficientHistory
        }
        return Clip(frames: Array(frames[predecessor...].prefix { $0.time <= endTime + 1e-9 }), startTime: start, endTime: endTime)
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: false)
        bytes = 0
        buffered = 0
        firstTime = nil
        lastTime = nil
    }
}
