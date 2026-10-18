import SwiftUI
import AVFoundation
import UIKit

struct PracticeView: View {
    @StateObject private var model = PracticeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Recording mode", selection: $model.mode) {
                    Text("Audio").tag(PracticeModel.Mode.audio)
                    Text("Video").tag(PracticeModel.Mode.video)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("practice.mode")
                .disabled(model.recording || model.busy)

                Group {
                    if let player = model.player {
                        ZStack {
                            if model.takeMode == .video {
                                VideoPlaybackSurface(player: player)
                            } else {
                                VStack(spacing: 16) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 64, weight: .ultraLight))
                                        .foregroundStyle(.secondary)
                                    Text("Audio take").font(.title3)
                                    Text(model.playback.hasFinished ? "Finished" : model.playback.isPlaying ? "Playing" : "Paused")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            if !model.playback.isReady {
                                ProgressView("Preparing replay")
                            }
                        }
                    } else if model.mode == .video && model.cameraReady, let camera = model.cameraSession {
                        CameraPreview(session: camera)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: model.mode == .audio ? "waveform" : "video")
                                .font(.system(size: 64, weight: .ultraLight))
                                .foregroundStyle(model.recording ? .red : .secondary)
                            Text(model.recording ? "Recording" : "Ready when you are")
                                .font(.title3)
                            Text(model.recording ? "Stop to hear your take." : "Record. Replay. Try again.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 24))

                if model.player != nil {
                    PlaybackControls(playback: model.playback, togglePlayback: model.togglePlayback)
                        .disabled(model.recording || model.busy)
                }

                if model.mode == .audio {
                    Menu {
                        Button("System microphone") { model.selectedInput = nil }
                        ForEach(model.inputs, id: \.uid) { input in
                            Button(input.portName) { model.selectedInput = input.uid }
                        }
                    } label: {
                        Label(model.inputName, systemImage: "mic")
                            .font(.subheadline)
                    }
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
                    Button {
                        model.toggleRecording()
                    } label: {
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
                    Button {
                        model.save()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                            Text(model.saved ? "Saved" : "Save").font(.caption)
                        }.frame(width: 64, height: 44)
                    }
                    .accessibilityIdentifier("practice.save")
                    .accessibilityLabel(model.saved ? "Saved" : "Save")
                    .disabled(!model.canSave)
                }
                Text(model.status)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("practice.status")
            }
            .padding()
            .navigationTitle("Replay")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.prepare() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.suspend() }
                else if phase == .active { Task { await model.resume() } }
            }
            .sheet(item: $model.audioExport) { request in
                AudioExporter(url: request.take.url) { outcome in
                    model.completeAudioExport(id: request.id, outcome: outcome)
                }
                // Files can dismiss before its delegate reports success. Use its explicit Cancel action.
                .interactiveDismissDisabled()
            }
            .alert("Replay", isPresented: Binding(get: { model.message != nil }, set: { presented in
                // SwiftUI can write this binding while updating the alert hierarchy.
                if !presented, model.message != nil { Task { @MainActor in model.dismissError() } }
            })) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: { Text(model.message ?? "") }
        }
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
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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
