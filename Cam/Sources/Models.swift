import Foundation
import AVFoundation
import CoreGraphics

enum CaptureMode: String, CaseIterable, Identifiable {
    case video = "ВИДЕО"
    case photo = "ФОТО"
    case slomo = "SLO-MO"
    case timelapse = "TIMELAPSE"
    var id: String { rawValue }
    var isVideoLike: Bool { self != .photo }
}

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4k = "4K"
    var id: String { rawValue }
    var width: Int32 {
        switch self { case .hd720: return 1280; case .hd1080: return 1920; case .uhd4k: return 3840 }
    }
    var height: Int32 {
        switch self { case .hd720: return 720; case .hd1080: return 1080; case .uhd4k: return 2160 }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC"
    case h264 = "H.264"
    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}

enum BitrateQuality: String, CaseIterable, Identifiable {
    case standard = "Стандарт"
    case high = "Высокий"
    case max = "Максимум"
    var id: String { rawValue }
    /// bits per pixel (HEVC); H.264 gets a multiplier.
    var bpp: Double {
        switch self { case .standard: return 0.07; case .high: return 0.12; case .max: return 0.22 }
    }
}

enum StabilizationOption: String, CaseIterable, Identifiable {
    case off = "Выкл"
    case standard = "Стандарт"
    case cinematic = "Кино"
    case auto = "Авто"
    var id: String { rawValue }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .auto: return .auto
        }
    }
}

enum GridType: String, CaseIterable, Identifiable {
    case off = "Выкл"
    case thirds = "3×3 (9 частей)"
    case grid4 = "4×4"
    case golden = "Золотое сечение"
    case diagonals = "Диагонали"
    case cross = "Центр"
    var id: String { rawValue }
}

enum FrameGuide: String, CaseIterable, Identifiable {
    case off = "Выкл"
    case r169 = "16:9"
    case r239 = "2.39:1"
    case r43 = "4:3"
    case r11 = "1:1"
    case r916 = "9:16"
    var id: String { rawValue }
    /// width / height
    var ratio: CGFloat? {
        switch self {
        case .off: return nil
        case .r169: return 16.0 / 9.0
        case .r239: return 2.39
        case .r43: return 4.0 / 3.0
        case .r11: return 1
        case .r916: return 9.0 / 16.0
        }
    }
}

enum LensKind: String, CaseIterable, Identifiable {
    case ultraWide = "0.5×"
    case wide = "1×"
    case tele = "Tele"
    case front = "Фронт"
    var id: String { rawValue }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide, .front: return .builtInWideAngleCamera
        case .tele: return .builtInTelephotoCamera
        }
    }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
}

enum FlashOption: String, CaseIterable, Identifiable {
    case off = "Выкл", auto = "Авто", on = "Вкл"
    var id: String { rawValue }
    var mode: AVCaptureDevice.FlashMode {
        switch self { case .off: return .off; case .auto: return .auto; case .on: return .on }
    }
}

enum ManualParam: String, CaseIterable, Identifiable {
    case focus = "FOCUS"
    case shutter = "SHUTTER"
    case iso = "ISO"
    case ev = "EV"
    case wb = "WB"
    case tint = "TINT"
    case zoom = "ZOOM"
    var id: String { rawValue }
}

struct PhotoResolutionOption: Identifiable, Hashable {
    let dims: CMVideoDimensions
    var id: String { "\(dims.width)x\(dims.height)" }
    var label: String {
        let mp = Double(Int(dims.width) * Int(dims.height)) / 1_000_000
        return String(format: "%.0f MP", mp.rounded())
    }
    static func == (l: Self, r: Self) -> Bool { l.dims.width == r.dims.width && l.dims.height == r.dims.height }
    func hash(into h: inout Hasher) { h.combine(dims.width); h.combine(dims.height) }
}

func formatShutter(_ d: CMTime) -> String {
    let s = CMTimeGetSeconds(d)
    if s <= 0 { return "—" }
    if s >= 0.5 { return String(format: "%.1fs", s) }
    return "1/\(Int((1.0 / s).rounded()))"
}

func formatTimecode(_ seconds: Double, fps: Int = 30) -> String {
    let total = max(0, seconds)
    let h = Int(total) / 3600
    let m = (Int(total) % 3600) / 60
    let s = Int(total) % 60
    let f = Int((total - Double(Int(total))) * Double(fps))
    return String(format: "%02d:%02d:%02d:%02d", h, m, s, min(f, fps - 1))
}

func formatShutterSeconds(_ s: Double) -> String {
    if s <= 0 { return "—" }
    if s >= 0.5 { return String(format: "%.1fs", s) }
    return "1/\(Int((1.0 / s).rounded()))"
}

func formatRemaining(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00:00" }
    let t = Int(min(seconds, 99 * 3600))
    return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
}
