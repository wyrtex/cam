import AppIntents

struct CamCaptureContext: Codable, Sendable {}

/// Позволяет выбрать Cam Pro в настройках Camera Control, на экране блокировки и в Пункте управления.
struct CamCaptureIntent: CameraCaptureIntent {
    typealias AppContext = CamCaptureContext

    static let title: LocalizedStringResource = "Cam Pro"
    static let description = IntentDescription("Открыть камеру Cam Pro")

    func perform() async throws -> some IntentResult {
        .result()
    }
}
