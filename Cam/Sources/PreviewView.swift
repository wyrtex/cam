import SwiftUI
import AVFoundation
import AVKit

final class DisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var onHardwareButton: (() -> Void)?

    /// Volume +/- (and the Action button) act as a shutter, like in the system Camera.
    func installHardwareButtons() {
        let interaction = AVCaptureEventInteraction { [weak self] event in
            if event.phase == .ended { DispatchQueue.main.async { self?.onHardwareButton?() } }
        }
        addInteraction(interaction)
    }
}

struct CameraPreview: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> DisplayView {
        let v = DisplayView()
        v.backgroundColor = .black
        v.displayLayer.videoGravity = .resizeAspect
        engine.displayLayer = v.displayLayer
        v.installHardwareButtons()
        v.onHardwareButton = { [weak engine] in engine?.primaryAction() }
        return v
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        if engine.displayLayer !== uiView.displayLayer { engine.displayLayer = uiView.displayLayer }
    }
}
