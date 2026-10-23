import AVFoundation
import CoreImage
import ImageIO
import UIKit

struct StreamUpdate: Sendable {
    let data: Data?
    let buffered: Double
    let measuredDelay: Double?
    let error: String?
    var sourceTime: Double?
    var isLive = false
}

/// A single-slot mailbox prevents capture from queuing images on a busy UI thread.
final class StreamMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var update: StreamUpdate?
    func put(_ value: StreamUpdate) { lock.lock(); update = value; lock.unlock() }
    func take() -> StreamUpdate? {
        lock.lock()
        defer { lock.unlock() }
        let value = update
        update = nil
        return value
    }
}

protocol DelayedVideoCapturing: Sendable {
    func preview(id: UUID, frameRate: Int, mailbox: StreamMailbox) async throws
    func start(id: UUID, delay: Double, frameRate: Int, mailbox: StreamMailbox) async throws
    func clip(id: UUID, endingAt: Double) async throws -> DelayedFrameBuffer.Clip
    func stop(id: UUID) async
}

/// Session, encoder, queue and rotation state are confined to `queue`.
final class DelayedVideoCapture: NSObject, DelayedVideoCapturing, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Replay.delayedVideo", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var activeID: UUID?
    private var buffer: DelayedFrameBuffer?
    private var mailbox: StreamMailbox?
    private var lastSample = -Double.infinity
    private var frameRate = 60
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    func preview(id: UUID, frameRate: Int, mailbox: StreamMailbox) async throws {
        try await begin(id: id, delay: nil, frameRate: frameRate, mailbox: mailbox)
    }

    func start(id: UUID, delay: Double, frameRate: Int, mailbox: StreamMailbox) async throws {
        try await begin(id: id, delay: delay, frameRate: frameRate, mailbox: mailbox)
    }

    private func begin(id: UUID, delay: Double?, frameRate: Int, mailbox: StreamMailbox) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw PracticeError("Allow camera access in Settings to use delayed video.")
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.activeID == nil else { throw PracticeError("The previous stream is still stopping. Please try again.") }
                    self.session.beginConfiguration()
                    do {
                        self.session.sessionPreset = .vga640x480
                        for input in self.session.inputs { self.session.removeInput(input) }
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                            throw PracticeError("No camera is available on this device.")
                        }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else { throw PracticeError("Cannot access the camera.") }
                        self.session.addInput(input)
                        if !self.session.outputs.contains(self.output) {
                            guard self.session.canAddOutput(self.output) else { throw PracticeError("Delayed video is unavailable on this device.") }
                            self.session.addOutput(self.output)
                        }
                        self.output.videoSettings = [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480
                        ]
                        try VideoCaptureSettings.configure(device, frameRate: frameRate, delayed: true)
                        self.frameRate = frameRate
                        self.output.alwaysDiscardsLateVideoFrames = true
                        self.output.setSampleBufferDelegate(self, queue: self.queue)
                        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                        self.rotation = rotation
                        self.rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak owner = self] coordinator, _ in
                            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                            owner?.setRotation(angle, id: id)
                        }
                        self.applyRotation(rotation.videoRotationAngleForHorizonLevelCapture)
                        self.session.commitConfiguration()
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }
                    self.activeID = id
                    self.buffer = delay.map { DelayedFrameBuffer(delay: $0) }
                    self.mailbox = mailbox
                    self.lastSample = -.infinity
                    for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { [weak owner = self] _ in
                            owner?.fail("The camera stream was interrupted. Start again when the camera is available.", id: id)
                        })
                    }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw PracticeError("The camera stream could not start.") }
                    continuation.resume()
                } catch {
                    if self.activeID == nil || self.activeID == id { self.clear() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setRotation(_ angle: CGFloat, id: UUID) {
        queue.async { if self.activeID == id { self.applyRotation(angle) } }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let id = activeID else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite, time - lastSample >= 0.9 / Double(frameRate) else { return }
        lastSample = time
        autoreleasepool {
            do {
                guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer),
                      let data = context.jpegRepresentation(of: CIImage(cvPixelBuffer: pixel), colorSpace: CGColorSpaceCreateDeviceRGB(),
                        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.65]) else {
                    throw PracticeError("The camera frame could not be prepared.")
                }
                let frame = try buffer?.append(time: time, data: data)
                mailbox?.put(StreamUpdate(data: frame?.data ?? data, buffered: buffer?.buffered ?? 0,
                                          measuredDelay: frame.map { time - $0.time }, error: nil, sourceTime: frame?.time, isLive: frame == nil))
            } catch {
                fail("The delayed video buffer could not continue. Try a shorter delay or restart the stream.", id: id)
            }
        }
    }

    private func fail(_ message: String, id: UUID) {
        queue.async {
            guard self.activeID == id else { return }
            self.mailbox?.put(StreamUpdate(data: nil, buffered: 0, measuredDelay: nil, error: message))
            self.clear()
        }
    }

    func stop(id: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.activeID == id { self.clear() }
                continuation.resume()
            }
        }
    }

    func clip(id: UUID, endingAt: Double) async throws -> DelayedFrameBuffer.Clip {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.activeID == id else {
                    continuation.resume(throwing: PracticeError("The stream is no longer available. Start it again to capture a clip."))
                    return
                }
                do {
                    guard let clip = try self.buffer?.clip(endingAt: endingAt) else { throw DelayedFrameBuffer.BufferError.insufficientHistory }
                    self.clear() // Capture has actually stopped before returning the snapshot.
                    continuation.resume(returning: clip)
                } catch {
                    self.clear()
                    continuation.resume(throwing: PracticeError("Wait until the selected interval has been viewed before clipping."))
                }
            }
        }
    }

    private func clear() {
        activeID = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        rotationObservation = nil
        rotation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for input in session.inputs { session.removeInput(input) }
        buffer = nil
        mailbox = nil
        context.clearCaches()
    }
}
