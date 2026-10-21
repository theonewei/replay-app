import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ReplayCore
#else
@testable import Replay
#endif

struct DelayedFrameBufferTests {
    @Test(arguments: (5...30).map(Double.init)) func delayUsesCaptureTimeAndStaysBounded(delay: Double) throws {
        var buffer = DelayedFrameBuffer(delay: delay)
        for frame in 0..<3_000 {
            let time = 100 + Double(frame) / 15
            let output = try buffer.append(time: time, data: Data(repeating: UInt8(frame % 256), count: 256))
            if time >= 100 + delay {
                let output = try #require(output)
                #expect(time - output.time >= delay - 0.00001)
                #expect(time - output.time < delay + 0.07)
                #expect(output.data.first == UInt8(Int(((output.time - 100) * 15).rounded()) % 256))
            } else { #expect(output == nil) }
            #expect(buffer.frames.count <= Int(delay * 15) + 2)
            #expect(buffer.bytes == buffer.frames.count * 256)
        }
    }

    @Test func capacityFailureDoesNotExceedBudget() throws {
        var buffer = DelayedFrameBuffer(delay: 5, byteLimit: 20, frameLimit: 4)
        _ = try buffer.append(time: 0, data: Data(count: 15))
        #expect(throws: DelayedFrameBuffer.BufferError.self) { try buffer.append(time: 0.1, data: Data(count: 10)) }
        #expect(buffer.bytes == 15)
        #expect(buffer.frames.count == 1)
    }

    @Test func gapResetsHistoryAndRestartCannotRevealOldFrames() throws {
        var buffer = DelayedFrameBuffer(delay: 5)
        for frame in 0..<30 { _ = try buffer.append(time: Double(frame) / 10, data: Data([1])) }
        #expect(try buffer.append(time: 10, data: Data([2])) == nil)
        #expect(buffer.buffered == 0)
        #expect(buffer.frames.count == 1)
        buffer.reset()
        #expect(buffer.bytes == 0)
        #expect(try buffer.append(time: 20, data: Data([3])) == nil)
        #expect(buffer.frames.first?.data == Data([3]))
    }

    @Test func frameLimitAndInvalidTimestampsAreRejected() throws {
        var buffer = DelayedFrameBuffer(delay: 5, frameLimit: 1)
        _ = try buffer.append(time: 0, data: Data([1]))
        #expect(throws: DelayedFrameBuffer.BufferError.self) { try buffer.append(time: 0.1, data: Data([2])) }
        #expect(throws: DelayedFrameBuffer.BufferError.self) { try buffer.append(time: .nan, data: Data([2])) }
        #expect(buffer.frames.count == 1)
    }
}
