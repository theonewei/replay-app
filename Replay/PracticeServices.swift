import AVFoundation
import Photos
import UIKit

@MainActor
protocol PracticeCapturing: AnyObject {
    var cameraSession: AVCaptureSession? { get }
    func inputs(prepare: Bool) -> [AVAudioSessionPortDescription]
    func audioPower(id: UUID) -> Float?
    func prepareVideo(position: AVCaptureDevice.Position) async throws
    func stopPreview() async
    func start(id: UUID, mode: RecordingMode, url: URL, inputID: String?, position: AVCaptureDevice.Position,
               started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor (Result<URL, Error>) -> Void) async throws
    func stop(id: UUID)
}

extension PracticeCapturing {
    func audioPower(id: UUID) -> Float? { nil }
}

@MainActor
protocol VideoExporting {
    func save(_ url: URL) async throws
}

struct PhotosExporter: VideoExporting {
    func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PracticeError("Allow Photos access in Settings to save this video. Your take is still available here.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

@MainActor
final class SystemCaptureDriver: NSObject, PracticeCapturing, AVAudioRecorderDelegate {
    private let camera = CameraRecorder()
    var cameraSession: AVCaptureSession? { camera.session }
    private var recorder: AVAudioRecorder?
    private var activeID: UUID?
    private var activeMode: RecordingMode?
    private var finished: (@MainActor (Result<URL, Error>) -> Void)?

    func inputs(prepare: Bool) -> [AVAudioSessionPortDescription] {
        let session = AVAudioSession.sharedInstance()
        if prepare, activeID == nil { try? session.setCategory(.record, mode: .measurement) }
        return session.availableInputs ?? []
    }

    func prepareVideo(position: AVCaptureDevice.Position) async throws {
        guard activeID == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw PracticeError("Allow camera access in Settings to record video.")
        }
        try Task.checkCancellation()
        try await camera.prepare(position: position, frameRate: VideoCaptureSettings.frameRate())
    }

    func stopPreview() async { await camera.stopSession() }

    func start(id: UUID, mode: RecordingMode, url: URL, inputID: String?, position: AVCaptureDevice.Position,
               started: @escaping @MainActor () -> Void,
               finished: @escaping @MainActor (Result<URL, Error>) -> Void) async throws {
        guard activeID == nil else { throw PracticeError("The previous recording is still finishing. Please try again.") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw PracticeError("Allow microphone access in Settings to record a take.")
        }
        try Task.checkCancellation()
        if mode == .video {
            try await prepareVideo(position: position)
        } else {
            await camera.stopSession()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let input = session.availableInputs?.first { $0.uid == inputID }
            if inputID != nil && input == nil {
                throw PracticeError("The selected microphone is no longer available. Choose another input.")
            }
            try session.setPreferredInput(input)
        }
        try Task.checkCancellation()
        guard activeID == nil else { throw PracticeError("The previous recording is still finishing. Please try again.") }
        activeID = id
        activeMode = mode
        self.finished = finished
        if mode == .audio {
            do {
                let next = try AVAudioRecorder(url: url, settings: RecordingFormat.settings(sampleRate: AVAudioSession.sharedInstance().sampleRate))
                next.delegate = self
                next.isMeteringEnabled = true
                recorder = next
                guard next.record() else { throw PracticeError("Recording could not start. Please try again.") }
                started()
            } catch {
                activeID = nil
                self.finished = nil
                recorder = nil
                throw error
            }
        } else {
            camera.record(to: url, started: { [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.activeID == id else { return }
                    started()
                }
            }, completion: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.activeID == id else { return }
                    await self.camera.stopSession()
                    self.complete(id: id, result: result)
                }
            })
        }
    }

    func stop(id: UUID) {
        guard activeID == id else { return }
        if activeMode == .audio {
            recorder?.isMeteringEnabled = false
            recorder?.stop()
        } else { camera.stopRecording() }
    }

    func audioPower(id: UUID) -> Float? {
        guard activeID == id, activeMode == .audio, let recorder, recorder.isRecording, recorder.isMeteringEnabled else { return nil }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    private func complete(id: UUID, result: Result<URL, Error>) {
        guard activeID == id else { return }
        let callback = finished
        activeID = nil
        activeMode = nil
        finished = nil
        recorder = nil
        callback?(result)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url, let id = self.activeID else { return }
            self.complete(id: id, result: flag ? .success(url) : .failure(PracticeError("The recording could not be finalized. Please try again.")))
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url, let id = self.activeID else { return }
            self.recorder?.stop()
            self.complete(id: id, result: .failure(error ?? PracticeError("Audio recording failed.")))
        }
    }
}

/// Capture session and callback state are accessed only on `queue`.
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Replay.camera")
    private let output = AVCaptureMovieFileOutput()
    private var completion: (@Sendable (Result<URL, Error>) -> Void)?
    private var started: (@Sendable () -> Void)?
    private var stopRequested = false
    private var rotation: AVCaptureDevice.RotationCoordinator?

    func prepare(position: AVCaptureDevice.Position, frameRate: Int) async throws {
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
                        self.rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                           let mic = AVCaptureDevice.default(for: .audio) {
                            let audio = try AVCaptureDeviceInput(device: mic)
                            if self.session.canAddInput(audio) { self.session.addInput(audio) }
                        }
                        if !self.session.outputs.contains(self.output) {
                            guard self.session.canAddOutput(self.output) else { throw PracticeError("Cannot record video on this device.") }
                            self.session.addOutput(self.output)
                        }
                        try VideoCaptureSettings.configure(device, frameRate: frameRate, delayed: false)
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

    func record(to url: URL, started: @escaping @Sendable () -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        queue.async {
            // Movie files have one orientation transform. Choose it at Record;
            // rotating the phone later does not rewrite the take's framing.
            if let connection = self.output.connection(with: .video), let rotation = self.rotation {
                let angle = rotation.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            self.completion = completion
            self.started = started
            self.stopRequested = false
            self.output.startRecording(to: url, recordingDelegate: self)
        }
    }
    func stopRecording() {
        queue.async {
            self.stopRequested = true
            if self.output.isRecording { self.output.stopRecording() }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            self.started?()
            self.started = nil
            if self.stopRequested { self.output.stopRecording() }
        }
    }
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
            self.started = nil
        }
    }
}
