import SwiftUI
import AVFoundation

final class DisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct CameraPreview: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> DisplayView {
        let v = DisplayView()
        v.backgroundColor = .black
        v.displayLayer.videoGravity = .resizeAspect
        engine.displayLayer = v.displayLayer
        return v
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        if engine.displayLayer !== uiView.displayLayer { engine.displayLayer = uiView.displayLayer }
    }
}
