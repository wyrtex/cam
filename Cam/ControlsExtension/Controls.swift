import WidgetKit
import SwiftUI
import AppIntents

@main
struct CamControlsBundle: WidgetBundle {
    var body: some Widget {
        CamCaptureControl()
    }
}

struct CamCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wyrtex.cam.capture-control") {
            ControlWidgetButton(action: CamCaptureIntent()) {
                Label("Cam Pro", systemImage: "camera.aperture")
            }
        }
        .displayName("Cam Pro")
        .description("Открыть камеру Cam Pro")
    }
}
