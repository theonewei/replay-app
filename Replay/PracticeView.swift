import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct PracticeView: View {
    @StateObject private var model = PracticeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Recording mode", selection: $model.mode) {
                    Text("Audio").tag(PracticeModel.Mode.audio)
                    Text("Video").tag(PracticeModel.Mode.video)
                }
                .pickerStyle(.segmented)
                .disabled(model.recording || model.busy)

                Group {
                    if let player = model.player {
                        VideoPlayer(player: player)
                            .overlay(alignment: .topLeading) {
                                if model.takeMode == .audio {
                                    Label("Audio take", systemImage: "waveform")
                                        .padding().foregroundStyle(.white)
                                        .allowsHitTesting(false)
                                }
                            }
                    } else if model.mode == .video && model.cameraReady {
                        CameraPreview(session: model.camera.session)
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
                        Task { await model.toggleRecording() }
                    } label: {
                        ZStack {
                            Circle().stroke(.red, lineWidth: 3).frame(width: 80, height: 80)
                            if model.recording {
                                RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                            } else {
                                Circle().fill(.red).frame(width: 66, height: 66)
                            }
                        }
                    }
                    .accessibilityLabel(model.recording ? "Stop and replay" : "Record new take")
                    .disabled(model.busy)
                    Spacer()
                    Button {
                        if model.takeMode == .video {
                            Task { await model.saveVideo() }
                        } else {
                            model.player?.pause()
                            exporting = true
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                            Text(model.saved ? "Saved" : "Save").font(.caption)
                        }.frame(width: 64, height: 44)
                    }.disabled(model.takeURL == nil || model.recording || model.busy || model.saved)
                }
                Text(model.recording ? "Tap stop to replay" : model.takeURL == nil ? "Only your latest take stays here" : "Loops until you record again")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Replay")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.prepare() }
            .onChange(of: model.mode) { _, _ in Task { await model.prepare() } }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.suspend() }
                else { Task { await model.prepare() } }
            }
            .sheet(isPresented: $exporting) {
                if let url = model.takeURL {
                    AudioExporter(url: url) { model.saved = true }
                }
            }
            .alert("Replay", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }
}

struct AudioExporter: UIViewControllerRepresentable {
    let url: URL
    let onSave: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSave: onSave) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSave: () -> Void
        init(onSave: @escaping () -> Void) { self.onSave = onSave }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty { onSave() }
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
