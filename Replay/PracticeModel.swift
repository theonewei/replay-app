import AVFoundation
import Combine
import UIKit

struct RecordedTake: Equatable {
    let id: UUID
    let mode: RecordingMode
    let url: URL
}

struct AudioExportRequest: Identifiable {
    let id: UUID
    let take: RecordedTake
}

enum ExportOutcome { case saved, cancelled }

@MainActor
final class PracticeModel: ObservableObject {
    typealias Mode = RecordingMode
    @Published private(set) var session = PracticeSession()
    @Published private(set) var take: RecordedTake?
    @Published private(set) var cameraReady = false
    @Published private(set) var inputs: [AVAudioSessionPortDescription] = []
    @Published private(set) var savedTakeID: UUID?
    @Published var message: String?
    @Published var audioExport: AudioExportRequest?
    @Published var selectedInput: String?
    let playback = PlaybackController()
    private let capture: any PracticeCapturing
    private let videoExport: any VideoExporting
    private let folder: URL
    private var pending: [UUID: RecordedTake] = [:]
    private var finalizing = Set<UUID>()
    private var startTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var readinessSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var position: AVCaptureDevice.Position = .front

    var mode: Mode {
        get { session.selectedMode }
        set {
            send(.selectMode(newValue))
            Task { await prepare() }
        }
    }
    var takeMode: Mode { take?.mode ?? mode }
    var takeURL: URL? { take?.url }
    var player: AVPlayer? { take?.mode == mode ? playback.player : nil }
    var cameraSession: AVCaptureSession? { capture.cameraSession }
    var recording: Bool { session.state == .recording }
    var busy: Bool { !session.canChangeMode }
    var canSave: Bool {
        take?.mode == mode && (session.state == .paused || session.state == .replaying) && !saved
    }
    var saved: Bool { take != nil && savedTakeID == take?.id }
    var recordLabel: String {
        if session.state == .preparing { return "Cancel or stop recording" }
        return recording ? "Stop and replay" : "Record new take"
    }
    var status: String {
        switch session.state {
        case .preparing: return "Preparing recording…"
        case .recording: return "Tap stop to replay"
        case .finishing: return "Preparing replay…"
        case .exporting: return "Saving…"
        default: return take == nil ? "Only your latest take stays here" : playback.loopEnabled ? "Loop is on" : "Plays once · Turn on Loop to repeat"
        }
    }
    var inputName: String { inputs.first { $0.uid == selectedInput }?.portName ?? "System microphone" }

    init(capture: (any PracticeCapturing)? = nil, videoExport: (any VideoExporting)? = nil, storage: URL? = nil) {
        #if DEBUG
        self.capture = capture ?? (ProcessInfo.processInfo.arguments.contains("--fixture-capture") ? FixtureCaptureDriver() : SystemCaptureDriver())
        #else
        self.capture = capture ?? SystemCaptureDriver()
        #endif
        self.videoExport = videoExport ?? PhotosExporter()
        folder = storage ?? FileManager.default.temporaryDirectory.appendingPathComponent("ReplayTakes", isDirectory: true)
        // Retain the prototype's existing relaunch policy; injected test stores are isolated.
        if storage == nil { try? FileManager.default.removeItem(at: folder) }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { message = error.localizedDescription }
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        playback.$isPlaying.dropFirst().sink { [weak self] playing in
            guard let self, !playing, let take = self.take else { return }
            self.send(.playbackStopped(take.id))
        }.store(in: &subscriptions)
        playback.onError = { [weak self] message in
            guard let self, let take = self.take else { return }
            self.send(.playbackFailed(take.id, message))
            self.message = message
        }
        observeInterruptions()
    }

    func prepare() async {
        guard session.canChangeMode else { return }
        #if DEBUG
        if take == nil, ProcessInfo.processInfo.arguments.contains("--preview-audio") {
            do {
                let preview = RecordedTake(id: UUID(), mode: .audio, url: try PreviewMedia.makeAudio(in: folder))
                take = preview
                send(.loadTake(UUID(), takeID: preview.id, mode: .audio,
                               autoplay: !ProcessInfo.processInfo.arguments.contains("--preview-paused")))
            } catch { message = error.localizedDescription }
            return
        }
        #endif
        previewTask?.cancel()
        previewGeneration = UUID()
        let generation = previewGeneration
        let mode = self.mode
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                if mode == .video && self.take?.mode != .video {
                    try await self.capture.prepareVideo(position: self.position)
                    guard !Task.isCancelled, self.previewGeneration == generation, self.session.canChangeMode else { return }
                    self.cameraReady = true
                } else {
                    await self.capture.stopPreview()
                    guard !Task.isCancelled, self.previewGeneration == generation else { return }
                    self.cameraReady = false
                }
                self.refreshInputs()
            } catch {
                if !Task.isCancelled, self.previewGeneration == generation { self.message = error.localizedDescription }
            }
        }
        await previewTask?.value
    }

    func refreshInputs() {
        guard player == nil else { return }
        inputs = capture.inputs(prepare: session.state == .ready && mode == .audio)
    }

    func toggleRecording() {
        if session.canStop { send(.stop) }
        else if session.canRecord { send(.record(UUID())) }
    }

    func togglePlayback() {
        if session.state == .replaying { send(.pause) }
        else if session.state == .paused { send(.play) }
    }

    func save() {
        guard canSave else { return }
        send(.export(UUID()))
    }

    func completeAudioExport(id: UUID, outcome: ExportOutcome) {
        completeExport(id: id, result: .success(outcome))
    }

    private func completeExport(id: UUID, result: Result<ExportOutcome, Error>) {
        guard session.state == .exporting, session.operationID == id, let take,
              session.takeID == take.id else { return }
        switch result {
        case .success(let outcome):
            if case .saved = outcome { savedTakeID = take.id }
            send(.exportFinished(id))
        case .failure(let error):
            send(.failure(id, error.localizedDescription))
            message = error.localizedDescription
        }
        audioExport = nil
    }

    func dismissError() {
        message = nil
        send(.dismissError)
    }

    private func send(_ event: PracticeSession.Event) {
        let effects = session.handle(event)
        UIApplication.shared.isIdleTimerDisabled = session.state == .recording
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: PracticeSession.Effect) {
        switch effect {
        case .startCapture(let id, let mode):
            previewTask?.cancel()
            previewGeneration = UUID()
            let url = folder.appendingPathComponent("Take-\(id.uuidString).\(mode == .audio ? "wav" : "mov")")
            pending[id] = RecordedTake(id: id, mode: mode, url: url)
            startTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.capture.start(id: id, mode: mode, url: url, inputID: self.selectedInput, position: self.position,
                        started: { [weak self] in
                            guard let self, self.session.operationID == id else { return }
                            self.send(.captureStarted(id))
                            self.inputs = self.capture.inputs(prepare: false)
                        }, finished: { [weak self] result in
                            Task { @MainActor [weak self] in await self?.captureFinished(id: id, result: result) }
                        })
                } catch {
                    self.deletePending(id)
                    guard self.session.operationID == id else { return }
                    self.send(.failure(id, error.localizedDescription))
                    self.message = error.localizedDescription
                }
            }
        case .stopCapture(let id): capture.stop(id: id)
        case .cancelCapture(let id):
            startTask?.cancel()
            capture.stop(id: id)
        case .replaceTake(let previous):
            readinessSubscription = nil
            playback.clear()
            if let old = take, old.id == previous {
                take = nil
                deleteFile(old.url)
            }
            savedTakeID = nil
        case .preparePlayback(let id, let takeID):
            guard let take, take.id == takeID else { return }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback)
                try audio.setActive(true)
                playback.load(take.url, autoplay: false)
                // Prefix the next readiness event to this operation and this take.
                readinessSubscription = playback.$isReady.dropFirst().filter { $0 }.prefix(1).sink { [weak self] _ in
                    guard let self, self.session.operationID == id, self.take?.id == takeID else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.session.operationID == id, self.take?.id == takeID else { return }
                        if UIApplication.shared.applicationState != .active { self.send(.suspend) }
                        self.send(.playbackReady(id))
                    }
                }
            } catch {
                send(.failure(id, error.localizedDescription))
                message = error.localizedDescription
            }
        case .play(let id):
            guard take?.id == id else { return }
            do {
                let audio = AVAudioSession.sharedInstance()
                if audio.category != .playback || audio.mode != .default { try audio.setCategory(.playback, mode: .default) }
                try audio.setActive(true)
                playback.play()
            } catch {
                send(.playbackFailed(id, error.localizedDescription))
                message = error.localizedDescription
            }
        case .pause(let id):
            guard take?.id == id else { return }
            playback.pause()
        case .export(let id, let takeID):
            guard let take, take.id == takeID else { return }
            if take.mode == .audio {
                audioExport = AudioExportRequest(id: id, take: take)
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.videoExport.save(take.url)
                        self.completeExport(id: id, result: .success(.saved))
                    } catch { self.completeExport(id: id, result: .failure(error)) }
                }
            }
        }
    }

    private func captureFinished(id: UUID, result: Result<URL, Error>) async {
        guard let pendingTake = pending[id], !finalizing.contains(id) else { return }
        guard session.operationID == id else { deletePending(id); return }
        finalizing.insert(id)
        defer { finalizing.remove(id) }
        do {
            let url = try result.get()
            guard url == pendingTake.url else { throw PracticeError("The recorder returned an unexpected file.") }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw PracticeError("The recording is empty. Please try again.") }
            let tracks = try await asset.loadTracks(withMediaType: pendingTake.mode == .audio ? .audio : .video)
            guard !tracks.isEmpty else { throw PracticeError("The recording is missing its media track. Please try again.") }
            guard session.operationID == id else { deletePending(id); return }
            guard session.state == .recording || session.state == .finishing else {
                throw PracticeError("Recording could not confirm its start. Please try again.")
            }
            take = pendingTake
            pending[id] = nil
            cameraReady = false
            send(.captureFinished(id, takeID: pendingTake.id))
        } catch {
            deletePending(id)
            guard session.operationID == id else { return }
            send(.failure(id, error.localizedDescription))
            message = error.localizedDescription
        }
    }

    private func deletePending(_ id: UUID) {
        if let pendingTake = pending.removeValue(forKey: id) { deleteFile(pendingTake.url) }
    }

    private func deleteFile(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { message = "A temporary recording could not be removed: \(error.localizedDescription)" }
    }

    func flipCamera() async {
        guard session.canChangeMode else { return }
        position = position == .front ? .back : .front
        await prepare()
    }

    func suspend() {
        previewTask?.cancel()
        previewGeneration = UUID()
        send(.suspend)
    }

    func resume() async {
        send(.resume)
        await prepare()
    }

    private func observeInterruptions() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor [weak self] in
                if began { self?.suspend() }
                else if UIApplication.shared.applicationState == .active { await self?.resume() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let removed = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            guard removed else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.recording {
                    self.send(.suspend)
                    self.send(.resume)
                    self.message = "The audio device was disconnected. Recording has stopped."
                } else { self.send(.pause) }
                self.refreshInputs()
            }
        })
    }

    isolated deinit {
        startTask?.cancel()
        previewTask?.cancel()
        if let id = session.operationID { capture.stop(id: id) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

struct PracticeError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
