import AVFoundation
import ImageIO

protocol DelayedClipEncoding: Sendable {
    func encode(_ clip: DelayedFrameBuffer.Clip, to url: URL) async throws
}

/// Only one decoded frame is allocated at a time; source history stays compressed.
actor DelayedClipEncoder: DelayedClipEncoding {
    func encode(_ clip: DelayedFrameBuffer.Clip, to url: URL) async throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              clip.duration.isFinite, clip.duration > 0, clip.duration <= 30,
              let first = clip.frames.first, first.time <= clip.startTime + 1e-9 else {
            throw PracticeError("The buffered clip is incomplete.")
        }
        let firstImage = try decode(first.data)
        let width = max(2, firstImage.width / 2 * 2)
        let height = max(2, firstImage.height / 2 * 2)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
        ])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw PracticeError("This device could not prepare a video clip.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PracticeError("The video clip could not start.") }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var succeeded = false
        defer {
            if !succeeded {
                if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: url)
            }
        }
        var previousTime = -1.0
        for frame in clip.frames where frame.time < clip.endTime {
            try Task.checkCancellation()
            let seconds = max(0, frame.time - clip.startTime)
            guard seconds > previousTime else { continue }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? PracticeError("Preparing the video clip timed out. Please try again.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            try autoreleasepool {
                let image = try decode(frame.data)
                var pixel: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess,
                      let pixel else { throw PracticeError("There was not enough memory to prepare the clip.") }
                CVPixelBufferLockBaseAddress(pixel, [])
                defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw PracticeError("The clip frame could not be prepared.")
                }
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
                let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
                // Preserve upright pixels and the entire frame if the phone
                // rotated during the selected interval. Letterbox, never crop.
                context.draw(image, in: CGRect(x: (Double(width) - size.width) / 2,
                                               y: (Double(height) - size.height) / 2, width: size.width, height: size.height))
                guard adaptor.append(pixel, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000)) else {
                    throw writer.error ?? PracticeError("The video clip could not be encoded.")
                }
            }
            previousTime = seconds
        }
        guard previousTime >= 0 else { throw PracticeError("The buffered clip contains no video.") }
        writer.endSession(atSourceTime: CMTime(seconds: clip.duration, preferredTimescale: 60_000))
        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? PracticeError("The video clip could not finish.") }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - clip.duration) < 0.02, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw PracticeError("The video clip could not be validated.")
        }
        succeeded = true
    }

    private func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= 1920, image.height <= 1920 else {
            throw PracticeError("A buffered video frame could not be read.")
        }
        return image
    }
}
