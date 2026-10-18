import Foundation

enum RecordingMode: String, Sendable {
    case audio
    case video
}

/// Hardware-independent transitions. Services execute effects and return events
/// carrying the same operation ID, so old callbacks cannot change a new session.
struct PracticeSession {
    enum State: Equatable {
        case ready
        case preparing
        case recording
        case finishing
        case replaying
        case paused
        case exporting
        case recoverableError(String)
    }

    enum Event {
        case record(UUID)
        case captureStarted(UUID)
        case stop
        case captureFinished(UUID, takeID: UUID)
        case playbackReady(UUID)
        case failure(UUID, String)
        case pause
        case play
        case selectMode(RecordingMode)
        case export(UUID)
        case exportFinished(UUID)
        case dismissError
    }

    enum Effect: Equatable {
        case startCapture(UUID, RecordingMode)
        case stopCapture(UUID)
        case replaceTake(UUID?)
        case preparePlayback(UUID, UUID)
        case play(UUID)
        case pause(UUID)
        case export(UUID, UUID)
    }

    private(set) var state: State = .ready
    private(set) var selectedMode: RecordingMode = .audio
    private(set) var takeID: UUID?
    private(set) var takeMode: RecordingMode?
    private(set) var operationID: UUID?
    private var captureMode: RecordingMode?
    private var stopQueued = false
    private var waitingForPlayback = false

    var canChangeMode: Bool {
        switch state {
        case .ready, .replaying, .paused, .recoverableError: return true
        default: return false
        }
    }

    var canRecord: Bool { canChangeMode }

    var canStop: Bool { state == .preparing || state == .recording }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .record(let id):
            guard canRecord else { return [] }
            var effects: [Effect] = []
            if let takeID { effects.append(.pause(takeID)) }
            operationID = id
            captureMode = selectedMode
            stopQueued = false
            waitingForPlayback = false
            state = .preparing
            effects.append(.startCapture(id, selectedMode))
            return effects

        case .captureStarted(let id):
            guard operationID == id, state == .preparing else { return [] }
            let previous = takeID
            takeID = nil
            takeMode = nil
            state = stopQueued ? .finishing : .recording
            return [.replaceTake(previous)] + (stopQueued ? [.stopCapture(id)] : [])

        case .stop:
            if state == .preparing {
                stopQueued = true
                return []
            }
            guard state == .recording, let operationID else { return [] }
            state = .finishing
            return [.stopCapture(operationID)]

        case .captureFinished(let id, let completedTake):
            guard operationID == id, !waitingForPlayback,
                  state == .finishing || state == .recording else { return [] }
            takeID = completedTake
            takeMode = captureMode
            waitingForPlayback = true
            state = .finishing
            return [.preparePlayback(id, completedTake)]

        case .playbackReady(let id):
            guard operationID == id, waitingForPlayback, state == .finishing,
                  let takeID else { return [] }
            waitingForPlayback = false
            operationID = nil
            state = .replaying
            return [.play(takeID)]

        case .failure(let id, let message):
            guard operationID == id else { return [] }
            operationID = nil
            waitingForPlayback = false
            stopQueued = false
            state = .recoverableError(message)
            return []

        case .pause:
            guard state == .replaying, let takeID else { return [] }
            state = .paused
            return [.pause(takeID)]

        case .play:
            guard state == .paused, takeMode == selectedMode, let takeID else { return [] }
            state = .replaying
            return [.play(takeID)]

        case .selectMode(let mode):
            guard canChangeMode else { return [] }
            selectedMode = mode
            let effects: [Effect] = state == .replaying ? takeID.map { [.pause($0)] } ?? [] : []
            state = takeID != nil && takeMode == mode ? .paused : .ready
            return effects

        case .export(let id):
            guard (state == .replaying || state == .paused), let takeID else { return [] }
            state = .exporting
            operationID = id
            return [.pause(takeID), .export(id, takeID)]

        case .exportFinished(let id):
            guard state == .exporting, operationID == id else { return [] }
            operationID = nil
            state = .paused
            return []

        case .dismissError:
            guard case .recoverableError = state else { return [] }
            state = takeID != nil && takeMode == selectedMode ? .paused : .ready
            return []
        }
    }
}
