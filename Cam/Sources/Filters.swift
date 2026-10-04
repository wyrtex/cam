import Foundation
import CoreImage
import CoreGraphics
import simd

enum LookFilter: String, CaseIterable, Identifiable {
    case none = "Оригинал"
    case vivid = "Яркий"
    case cinema = "Кино"
    case warm = "Тёплый"
    case cold = "Холодный"
    case vintage = "Винтаж"
    case bleach = "Bleach"
    case matte = "Матовый"
    case noir = "Нуар"
    case mono = "Моно"
    case silver = "Серебро"
    case chrome = "Chrome"
    case instant = "Instant"
    case process = "Process"
    case transfer = "Transfer"
    case fade = "Fade"
    case sepia = "Сепия"
    case custom = "Мой LUT"
    var id: String { rawValue }

    var ciPhotoEffect: String? {
        switch self {
        case .noir: return "CIPhotoEffectNoir"
        case .mono: return "CIPhotoEffectMono"
        case .silver: return "CIPhotoEffectTonal"
        case .chrome: return "CIPhotoEffectChrome"
        case .instant: return "CIPhotoEffectInstant"
        case .process: return "CIPhotoEffectProcess"
        case .transfer: return "CIPhotoEffectTransfer"
        case .fade: return "CIPhotoEffectFade"
        default: return nil
        }
    }

    /// Color transform applied on gamma-encoded Rec.709 values (0...1).
    var transform: ((SIMD3<Float>) -> SIMD3<Float>)? {
        func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        func sat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> { let l = luma(c); return SIMD3<Float>(repeating: l) + (c - SIMD3<Float>(repeating: l)) * s }
        func contrast(_ c: SIMD3<Float>, _ k: Float) -> SIMD3<Float> { (c - SIMD3<Float>(repeating: 0.5)) * k + SIMD3<Float>(repeating: 0.5) }
        switch self {
        case .vivid:
            return { c in contrast(sat(c, 1.38), 1.08) }
        case .cinema:
            return { c in
                let l = luma(c)
                let sh = (1 - l) * (1 - l)
                let hi = l * l
                var o = c + sh * SIMD3<Float>(-0.045, 0.02, 0.065) + hi * SIMD3<Float>(0.07, 0.025, -0.06)
                o = contrast(o, 1.14)
                return sat(o, 1.05)
            }
        case .warm:
            return { c in sat(c * SIMD3<Float>(1.07, 1.0, 0.9), 1.06) }
        case .cold:
            return { c in sat(c * SIMD3<Float>(0.92, 1.0, 1.09), 1.04) }
        case .vintage:
            return { c in
                var o = sat(c, 0.78) * SIMD3<Float>(1.06, 1.0, 0.88)
                o = o * 0.92 + SIMD3<Float>(repeating: 0.06)
                return o
            }
        case .bleach:
            return { c in contrast(sat(c, 0.45), 1.35) }
        case .matte:
            return { c in
                let o = sat(c, 0.9)
                return contrast(o, 0.95) * 0.9 + SIMD3<Float>(repeating: 0.08)
            }
        default:
            return nil
        }
    }
}

struct CubeLUT: Identifiable {
    let id = UUID()
    let name: String
    let size: Int
    let data: Data

    enum LUTError: LocalizedError {
        case unsupported1D, invalid
        var errorDescription: String? {
            switch self {
            case .unsupported1D: return "1D LUT не поддерживается — нужен 3D .cube"
            case .invalid: return "Не удалось прочитать .cube файл"
            }
        }
    }

    static func parse(url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var floats = [Float]()
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.hasPrefix("LUT_1D_SIZE") { throw LUTError.unsupported1D }
            if t.hasPrefix("LUT_3D_SIZE") {
                size = Int(t.split(whereSeparator: { $0 == " " || $0 == "\t" }).last ?? "") ?? 0
                if size > 1 { floats.reserveCapacity(size * size * size * 4) }
                continue
            }
            if t.hasPrefix("TITLE") || t.hasPrefix("DOMAIN") { continue }
            let parts = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                floats.append(contentsOf: [r, g, b, 1])
            }
        }
        guard size > 1, floats.count == size * size * size * 4 else { throw LUTError.invalid }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(name: url.deletingPathExtension().lastPathComponent, size: size, data: data)
    }
}

/// Applies a look to CIImages. Not thread-safe: use one instance per queue.
final class LookRenderer {
    private let rec709 = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private var cubeFilters: [String: CIFilter] = [:]

    private static func makeCube(size: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> Data {
        var out = [Float]()
        out.reserveCapacity(size * size * size * 4)
        let m = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let o = f(SIMD3<Float>(Float(r) / m, Float(g) / m, Float(b) / m))
                    out.append(min(max(o.x, 0), 1))
                    out.append(min(max(o.y, 0), 1))
                    out.append(min(max(o.z, 0), 1))
                    out.append(1)
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func cubeFilter(key: String, size: Int, data: @autoclosure () -> Data) -> CIFilter? {
        if let f = cubeFilters[key] { return f }
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(size, forKey: "inputCubeDimension")
        f.setValue(data(), forKey: "inputCubeData")
        f.setValue(rec709, forKey: "inputColorSpace")
        cubeFilters[key] = f
        return f
    }

    func apply(look: LookFilter, lut: CubeLUT?, intensity: Double, to image: CIImage) -> CIImage {
        if look == .none { return image }
        var result: CIImage?

        if let name = look.ciPhotoEffect, let f = CIFilter(name: name) {
            f.setValue(image, forKey: kCIInputImageKey)
            result = f.outputImage
        } else if look == .sepia, let f = CIFilter(name: "CISepiaTone") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.9, forKey: kCIInputIntensityKey)
            result = f.outputImage
        } else if look == .custom, let lut {
            if let f = cubeFilter(key: "lut-\(lut.id)", size: lut.size, data: lut.data) {
                f.setValue(image, forKey: kCIInputImageKey)
                result = f.outputImage
            }
        } else if let t = look.transform {
            let size = 17
            if let f = cubeFilter(key: look.rawValue, size: size, data: Self.makeCube(size: size, t)) {
                f.setValue(image, forKey: kCIInputImageKey)
                result = f.outputImage
            }
        }

        guard var out = result else { return image }
        if intensity < 0.995, let mix = CIFilter(name: "CIDissolveTransition") {
            mix.setValue(image, forKey: kCIInputImageKey)
            mix.setValue(out, forKey: kCIInputTargetImageKey)
            mix.setValue(max(0, min(1, intensity)), forKey: kCIInputTimeKey)
            if let o = mix.outputImage { out = o }
        }
        return out.cropped(to: image.extent)
    }
}
