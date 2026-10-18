import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ReplayCore
#else
@testable import Replay
#endif

struct PracticeSessionTests {
    private func completeTake(_ session: inout PracticeSession, take: UUID) {
        let operation = UUID()
        _ = session.handle(.record(operation))
        _ = session.handle(.captureStarted(operation))
        _ = session.handle(.stop)
        _ = session.handle(.captureFinished(operation, takeID: take))
        _ = session.handle(.playbackReady(operation))
    }

    @Test func autoplayWaitsForFinalizationAndReadiness() {
        var session = PracticeSession()
        let operation = UUID()
        let take = UUID()
        #expect(session.handle(.record(operation)) == [.startCapture(operation, .audio)])
        #expect(session.handle(.playbackReady(operation)).isEmpty)
        #expect(session.handle(.captureStarted(operation)) == [.replaceTake(nil)])
        #expect(session.handle(.stop) == [.stopCapture(operation)])
        #expect(session.handle(.captureFinished(operation, takeID: take)) == [.preparePlayback(operation, take)])
        #expect(session.state == .finishing)
        #expect(session.handle(.playbackReady(operation)) == [.play(take)])
        #expect(session.handle(.playbackReady(operation)).isEmpty)
        #expect(session.state == .replaying)
    }

    @Test func repeatedRecordAndEarlyStopProduceOneCapture() {
        var session = PracticeSession()
        let operation = UUID()
        _ = session.handle(.record(operation))
        #expect(session.handle(.record(UUID())).isEmpty)
        #expect(session.canStop)
        #expect(!session.canChangeMode)
        #expect(session.handle(.stop).isEmpty)
        #expect(session.handle(.stop).isEmpty)
        #expect(session.handle(.captureStarted(operation)) == [.replaceTake(nil), .stopCapture(operation)])
        #expect(session.state == .finishing)
        #expect(session.handle(.stop).isEmpty)
        #expect(session.handle(.captureStarted(operation)).isEmpty)
    }

    @Test func failedNewStartPreservesPreviousTake() {
        var session = PracticeSession()
        let take = UUID()
        completeTake(&session, take: take)
        let operation = UUID()
        _ = session.handle(.record(operation))
        #expect(session.takeID == take)
        _ = session.handle(.failure(operation, "Microphone unavailable"))
        #expect(session.takeID == take)
        #expect(session.state == .recoverableError("Microphone unavailable"))
        _ = session.handle(.dismissError)
        #expect(session.state == .paused)
        #expect(session.handle(.play) == [.play(take)])
    }

    @Test func oldCallbacksCannotReplaceNewCapture() {
        var session = PracticeSession()
        let oldOperation = UUID()
        _ = session.handle(.record(oldOperation))
        _ = session.handle(.failure(oldOperation, "Start failed"))
        let operation = UUID()
        _ = session.handle(.record(operation))
        #expect(session.handle(.captureStarted(oldOperation)).isEmpty)
        #expect(session.handle(.captureFinished(oldOperation, takeID: UUID())).isEmpty)
        #expect(session.handle(.failure(oldOperation, "Stale error")).isEmpty)
        #expect(session.state == .preparing)
        #expect(session.operationID == operation)
    }

    @Test func duplicateFinalizationCannotChangeCurrentTake() {
        var session = PracticeSession()
        let operation = UUID()
        let take = UUID()
        _ = session.handle(.record(operation))
        _ = session.handle(.captureStarted(operation))
        _ = session.handle(.stop)
        _ = session.handle(.captureFinished(operation, takeID: take))
        #expect(session.handle(.captureFinished(operation, takeID: UUID())).isEmpty)
        #expect(session.takeID == take)
    }

    @Test func selectedModeAndRetainedTakeRemainIndependent() {
        var session = PracticeSession()
        let audio = UUID()
        completeTake(&session, take: audio)
        #expect(session.handle(.selectMode(.video)) == [.pause(audio)])
        #expect(session.state == .ready)
        #expect(session.takeID == audio)
        #expect(session.takeMode == .audio)
        #expect(session.selectedMode == .video)
        _ = session.handle(.selectMode(.audio))
        #expect(session.state == .paused)
        #expect(session.takeID == audio)
    }

    @Test func exportOwnsTakeUntilMatchingCompletion() {
        var session = PracticeSession()
        let take = UUID()
        completeTake(&session, take: take)
        let export = UUID()
        #expect(session.handle(.export(export)) == [.pause(take), .export(export, take)])
        #expect(session.handle(.record(UUID())).isEmpty)
        #expect(session.handle(.export(UUID())).isEmpty)
        #expect(session.handle(.exportFinished(UUID())).isEmpty)
        #expect(session.state == .exporting)
        _ = session.handle(.exportFinished(export))
        #expect(session.state == .paused)
        #expect(session.takeID == take)
    }
}
