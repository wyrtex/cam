import SwiftUI
import AVFoundation
import AVKit
import LockedCameraCapture

@main
struct CamCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            CaptureRootView(session: session)
        }
    }
}

final class MiniPreviewModel: ObservableObject {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cam.capture.ext")

    func start() {
        queue.async {
            guard !self.session.isRunning else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }
}

struct MiniPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct CaptureRootView: View {
    let session: LockedCameraCaptureSession
    @StateObject private var model = MiniPreviewModel()

    var body: some View {
        ZStack {
            MiniPreview(session: model.session).ignoresSafeArea()
            VStack {
                Spacer()
                Button {
                    openApp()
                } label: {
                    Label("Открыть Cam Pro", systemImage: "camera.aperture")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 14)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear { model.start() }
        .onCameraCaptureEvent { event in
            if event.phase == .ended { openApp() }
        }
    }

    private func openApp() {
        Task {
            let activity = NSUserActivity(activityType: "com.wyrtex.cam.open")
            try? await session.openApplication(for: activity)
        }
    }
}
