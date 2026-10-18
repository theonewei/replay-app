import AVFoundation
import Combine
import Photos
import UIKit

@MainActor
final class PracticeModel: ObservableObject {
    enum Mode { case audio, video }
    @Published var mode: Mode = .audio
    @Published var takeMode: Mode = .audio
    @Published var recording = false
    @Published var busy = false
    @Published var saved = false
    @Published var cameraReady = false
    @Published var message: String?
    let playback = PlaybackController()
    var player: AVPlayer? { playback.player }
    @Published var takeURL: URL?
    @Published var inputs: [AVAudioSessionPortDescription] = []
    @Published var selectedInput: String?
    let camera = CameraRecorder()
    private var recorder: AVAudioRecorder?
    private var playbackObservation: AnyCancellable?
    private var interruptionObserver: NSObjectProtocol?
    private var pendingURL: URL?
    private var position: AVCaptureDevice.Position = .front
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReplayTakes", isDirectory: true)

    var inputName: String {
        inputs.first { $0.uid == selectedInput }?.portName ?? "System microphone"
    }

    init() {
        playbackObservation = playback.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        playback.onError = { [weak self] in self?.message = $0 }
        // The app owns this folder exclusively. Unsaved takes do not survive a launch.
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }
    }

    func prepare() async {
        guard !recording, !busy, player == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-audio") {
            do {
                replay(try PreviewMedia.makeAudio(in: folder),
                       autoplay: !ProcessInfo.processInfo.arguments.contains("--preview-paused"))
            }
            catch { message = error.localizedDescription }
            return
        }
        #endif
        busy = true
        defer { busy = false }
        do {
            if mode == .audio {
                await camera.stopSession()
                cameraReady = false
                try configureInput()
            } else {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw PracticeError("Allow camera access in Settings to record video.")
                }
                try await camera.prepare(position: position)
                cameraReady = true
            }
        } catch { message = error.localizedDescription }
    }

    private func configureInput() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        inputs = session.availableInputs ?? []
        let input = inputs.first { $0.uid == selectedInput }
        if selectedInput != nil && input == nil { selectedInput = nil }
        try session.setPreferredInput(input)
    }

    func refreshInputs() {
        // Switching to the recording category would interrupt replay, so refresh
        // the full list at preparation and just inspect it while playing.
        if player == nil { try? configureInput() }
    }

    func toggleRecording() async {
        guard !busy else { return }
        if recording { stop(); return }
        busy = true
        defer { busy = false }
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw PracticeError("Allow microphone access in Settings to record a take.")
            }
            if mode == .video {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw PracticeError("Allow camera access in Settings to record video.")
                }
            }
            playback.pause()
            if mode == .audio {
                await camera.stopSession()
                try configureInput()
            } else {
                try await camera.prepare(position: position)
                cameraReady = true
            }
            let url = folder.appendingPathComponent("Take-\(UUID().uuidString).\(mode == .audio ? "wav" : "mov")")
            if mode == .audio {
                let settings = try RecordingFormat.settings(sampleRate: AVAudioSession.sharedInstance().sampleRate)
                let newRecorder = try AVAudioRecorder(url: url, settings: settings)
                guard newRecorder.record() else { throw PracticeError("Recording could not start. Please try again.") }
                recorder = newRecorder
            } else {
                camera.record(to: url) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        self.recording = false
                        self.busy = true
                        await self.camera.stopSession()
                        self.cameraReady = false
                        switch result {
                        case .success(let url): self.replay(url)
                        case .failure(let error):
                            self.message = error.localizedDescription
                            if let pending = self.pendingURL { try? FileManager.default.removeItem(at: pending) }
                        }
                        self.pendingURL = nil
                        self.busy = false
                    }
                }
            }
            clearTake()
            takeMode = mode
            pendingURL = url
            recording = true
            saved = false
            UIApplication.shared.isIdleTimerDisabled = true
        } catch { message = error.localizedDescription }
    }

    private func stop() {
        guard recording else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        if takeMode == .audio {
            recorder?.stop()
            recorder = nil
            recording = false
            if let url = pendingURL { replay(url) }
            pendingURL = nil
        } else {
            busy = true
            camera.stopRecording()
        }
    }

    private func replay(_ url: URL, autoplay: Bool = true) {
        takeURL = url
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            playback.load(url, autoplay: autoplay && UIApplication.shared.applicationState == .active)
        } catch { message = error.localizedDescription }
    }

    private func clearTake() {
        playback.clear()
        if let url = takeURL { try? FileManager.default.removeItem(at: url) }
        takeURL = nil
    }

    func flipCamera() async {
        position = position == .front ? .back : .front
        await prepare()
    }

    func suspend() {
        if recording { stop() }
        playback.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func saveVideo() async {
        guard let url = takeURL, !busy else { return }
        playback.pause()
        busy = true
        defer { busy = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Allow Photos access in Settings to save this video. Your take is still available here."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            saved = true
        } catch { message = error.localizedDescription }
    }
}

struct PracticeError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Replay.camera")
    private let output = AVCaptureMovieFileOutput()
    private var completion: ((Result<URL, Error>) -> Void)?

    func prepare(position: AVCaptureDevice.Position) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.session.isRunning { self.session.stopRunning() }
                    self.session.beginConfiguration()
                    do {
                        self.session.sessionPreset = .high
                        for input in self.session.inputs { self.session.removeInput(input) }
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                            throw PracticeError("No camera is available on this device.")
                        }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else { throw PracticeError("Cannot access the camera.") }
                        self.session.addInput(input)
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                           let mic = AVCaptureDevice.default(for: .audio) {
                            let audio = try AVCaptureDeviceInput(device: mic)
                            if self.session.canAddInput(audio) { self.session.addInput(audio) }
                        }
                        if !self.session.outputs.contains(self.output) {
                            guard self.session.canAddOutput(self.output) else { throw PracticeError("Cannot record video on this device.") }
                            self.session.addOutput(self.output)
                        }
                        if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                        self.session.commitConfiguration()
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }
                    self.session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func record(to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }
    func stopRecording() { queue.async { if self.output.isRecording { self.output.stopRecording() } } }
    func stopSession() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                self.completion?(.failure(error))
            } else { self.completion?(.success(url)) }
            self.completion = nil
        }
    }
}
