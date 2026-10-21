import SwiftUI
import AVFoundation
import UIKit

struct PracticeView: View {
    @StateObject private var model = PracticeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullscreen = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if fullscreen {
                    Color.black
                } else if geometry.size.width > geometry.size.height {
                    HStack(spacing: 16) {
                        media
                        ScrollView { controls }.frame(width: min(300, geometry.size.width * 0.42))
                    }.padding()
                } else {
                    VStack(spacing: 16) {
                        modePicker
                        media
                        actions
                    }.padding()
                }
            }
            .navigationTitle("Replay")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-stream") {
                    model.mode = .video
                    model.setDelayedMode(true)
                    await model.startDelayedStream()
                } else { await model.prepare() }
                #else
                await model.prepare()
                #endif
            }
            .onChange(of: model.playback.isReady) { _, ready in
                if ready, model.mode == .video, !model.isDelayedMode { fullscreen = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.suspend() }
                else if phase == .active { Task { await model.resume() } }
            }
            .fullScreenCover(isPresented: $fullscreen) {
                FullscreenVideoView(model: model) { fullscreen = false }
            }
            .sheet(item: $model.audioExport) { request in
                AudioExporter(url: request.take.url) { outcome in
                    model.completeAudioExport(id: request.id, outcome: outcome)
                }
                .interactiveDismissDisabled()
            }
            .alert("Replay", isPresented: Binding(get: { model.message != nil && !fullscreen }, set: { presented in
                if !presented, !fullscreen, model.message != nil { Task { @MainActor in model.dismissError() } }
            })) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: { Text(model.message ?? "") }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) { modePicker; actions }
    }

    private var modePicker: some View {
        VStack(spacing: 8) {
            Picker("Recording mode", selection: $model.mode) {
                Text("Audio").tag(PracticeModel.Mode.audio)
                Text("Video").tag(PracticeModel.Mode.video)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("practice.mode")
            .disabled(model.recording || model.busy)
            if model.mode == .video {
                Picker("Video mode", selection: Binding(get: { model.isDelayedMode }, set: { model.setDelayedMode($0) })) {
                    Text("Record").tag(false)
                    Text("Delayed stream").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("video.style")
                .disabled(model.busy)
            }
        }
    }

    private var media: some View {
        Group {
            if model.isDelayedMode, model.mode == .video {
                DelayedStreamSurface(stream: model.delayed)
            } else if let player = model.player {
                ZStack {
                    if model.takeMode == .video {
                        if fullscreen { Color.black } else { VideoPlaybackSurface(player: player) }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "waveform").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.secondary)
                            Text("Audio take").font(.title3)
                            Text(model.playback.hasFinished ? "Finished" : model.playback.isPlaying ? "Playing" : "Paused")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if !model.playback.isReady { ProgressView("Preparing replay") }
                }
            } else if model.mode == .video, model.cameraReady, let camera = model.cameraSession {
                CameraPreview(session: camera)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: model.mode == .audio ? "waveform" : "video")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(model.recording ? .red : .secondary)
                    Text(model.recording ? "Recording" : "Ready when you are").font(.title3)
                    Text(model.recording ? "Stop to hear your take." : "Record. Replay. Try again.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var actions: some View {
        if model.isDelayedMode, model.mode == .video {
            DelayedStreamControls(stream: model.delayed, start: { Task { await model.startDelayedStream() } })
        } else {
            if model.player != nil {
                PlaybackControls(playback: model.playback, togglePlayback: model.togglePlayback)
                    .disabled(model.recording || model.busy)
                if model.takeMode == .video {
                    Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") { fullscreen = true }
                        .accessibilityIdentifier("video.fullscreen")
                }
            }
            if model.mode == .audio {
                Menu {
                    Button("System microphone") { model.selectedInput = nil }
                    ForEach(model.inputs, id: \.uid) { input in
                        Button(input.portName) { model.selectedInput = input.uid }
                    }
                } label: { Label(model.inputName, systemImage: "mic").font(.subheadline) }
                .disabled(model.recording || model.busy)
                .simultaneousGesture(TapGesture().onEnded { model.refreshInputs() })
            } else {
                Button(action: { Task { await model.flipCamera() } }) {
                    Label("Flip camera", systemImage: "arrow.triangle.2.circlepath.camera")
                }.disabled(model.recording || model.busy || model.player != nil)
            }
            HStack {
                Color.clear.frame(width: 64, height: 44).accessibilityHidden(true)
                Spacer()
                Button { model.toggleRecording() } label: {
                    ZStack {
                        Circle().stroke(.red, lineWidth: 3).frame(width: 80, height: 80)
                        if model.session.canStop {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(.red).frame(width: 66, height: 66)
                        }
                    }
                }
                .accessibilityIdentifier("practice.record")
                .accessibilityLabel(model.recordLabel)
                .disabled(!model.session.canRecord && !model.session.canStop)
                Spacer()
                Button { model.save() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                        Text(model.saved ? "Saved" : "Save").font(.caption)
                    }.frame(width: 64, height: 44)
                }
                .accessibilityIdentifier("practice.save")
                .accessibilityLabel(model.saved ? "Saved" : "Save")
                .disabled(!model.canSave)
            }
            Text(model.status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("practice.status")
        }
    }
}

struct FullscreenVideoView: View {
    @ObservedObject var model: PracticeModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Done", action: close).accessibilityIdentifier("video.done").frame(minHeight: 44)
                Spacer()
                Button(model.saved ? "Saved" : "Save") { model.save() }.disabled(!model.canSave)
            }
            if let player = model.player { VideoPlaybackSurface(player: player) }
            PlaybackControls(playback: model.playback, togglePlayback: model.togglePlayback)
        }
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
        .alert("Replay", isPresented: Binding(get: { model.message != nil }, set: { _ in })) {
            Button("OK") { model.dismissError() }
        } message: { Text(model.message ?? "") }
    }
}

struct AudioExporter: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (ExportOutcome) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (ExportOutcome) -> Void
        init(onComplete: @escaping (ExportOutcome) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete(urls.isEmpty ? .cancelled : .saved)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.cancelled)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        view.configureRotation()
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { view.configureRotation() }
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        func configureRotation() {
            guard let device = (preview.session?.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            if rotation?.device != device {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
                rotation = coordinator
                observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.applyRotation() }
                }
            }
            applyRotation()
        }

        override func layoutSubviews() { super.layoutSubviews(); applyRotation() }

        private func applyRotation() {
            guard let connection = preview.connection, let rotation else { return }
            let angle = rotation.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = rotation.device?.position == .front
            }
        }
    }
}


struct PlaybackControls: View {
    @ObservedObject var playback: PlaybackController
    let togglePlayback: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(get: { playback.position }, set: { playback.seek(to: $0) }),
                in: 0...max(playback.duration, 0.001),
                onEditingChanged: { editing in
                    if editing { playback.beginScrubbing() } else { playback.endScrubbing() }
                }
            )
            .accessibilityLabel("Recording timeline")
            .accessibilityValue("\(playback.positionLabel) of \(playback.durationLabel)")
            .accessibilityHint("Adjust to move through this recording.")
            .accessibilityIdentifier("playback.timeline")
            .disabled(!playback.isReady)

            HStack {
                Text(playback.positionLabel).accessibilityIdentifier("playback.elapsed")
                Spacer()
                Text(playback.durationLabel).accessibilityIdentifier("playback.duration")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Button(action: togglePlayback) {
                    Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 80, minHeight: 44)
                }
                .accessibilityIdentifier("playback.playPause")
                .disabled(!playback.isReady)

                Spacer()
                Text("Loop")
                Toggle("Loop", isOn: $playback.loopEnabled)
                    .labelsHidden()
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("playback.loop")
                    .accessibilityHint("Repeat this take until paused.")
            }
        }
    }
}

struct VideoPlaybackSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.layerPlayer.videoGravity = .resizeAspect
        view.layerPlayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.layerPlayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
