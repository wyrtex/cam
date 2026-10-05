import Foundation
import CoreImage
import CoreGraphics

/// Inversion + glitch (RGB split, sliding strips, pixel blocks) inside a quad.
enum GlitchQuad {

    fileprivate struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s % 1_000_000) / 1_000_000
        }
    }

    /// `quad` — 4 points, normalized, origin top-left. May self-intersect.
    static func apply(_ image: CIImage, quad: [CGPoint], seed: UInt64, strength: Double, effects: Set<QuadEffect>) -> CIImage {
        guard quad.count == 4, !effects.isEmpty else { return image }
        let e = image.extent
        guard e.width > 8, e.height > 8 else { return image }
        let k = max(0.1, min(1, strength))

        let px = quad.map { CGPoint(x: e.minX + $0.x * e.width, y: e.minY + (1 - $0.y) * e.height) }
        var minX = px.map(\.x).min()!, maxX = px.map(\.x).max()!
        var minY = px.map(\.y).min()!, maxY = px.map(\.y).max()!
        minX = max(e.minX, minX); maxX = min(e.maxX, maxX)
        minY = max(e.minY, minY); maxY = min(e.maxY, maxY)
        guard maxX - minX > 4, maxY - minY > 4 else { return image }
        let region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral.intersection(e)

        var rng = RNG(s: seed &* 2654435761 &+ 88172645463325252)
        _ = rng.next()

        var work = image.cropped(to: region)

        if effects.contains(.thermal) {
            work = work.applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIFalseColor", parameters: [
                    "inputColor0": CIColor(red: 0.10, green: 0.0, blue: 0.35),
                    "inputColor1": CIColor(red: 1.0, green: 0.92, blue: 0.2)
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.25, kCIInputSaturationKey: 1.4])
                .cropped(to: region)
        }

        if effects.contains(.twirl) {
            let center = CIVector(x: region.midX, y: region.midY)
            work = work.clampedToExtent()
                .applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: center,
                    kCIInputRadiusKey: max(region.width, region.height) * 0.6,
                    kCIInputAngleKey: 2.0 + 4.0 * k
                ])
                .cropped(to: region)
        }

        if effects.contains(.mosaic) {
            let scale = max(8, region.width * (0.02 + 0.07 * k))
            work = work.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputCenterKey: CIVector(x: region.minX, y: region.minY)
                ])
                .cropped(to: region)
        }

        if effects.contains(.invert) {
            work = work.applyingFilter("CIColorInvert").cropped(to: region)
        }

        if effects.contains(.glitch) {
            work = glitch(work, region: region, k: k, rng: &rng)
        }

        guard let mask = makeMask(points: px, extent: e) else { return image }
        return work
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            .cropped(to: e)
    }

    private static func glitch(_ input: CIImage, region: CGRect, k: Double, rng: inout RNG) -> CIImage {
        let clamped = input.clampedToExtent()

        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            clamped.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        }
        let split = region.width * 0.03 * k * (0.4 + rng.next())
        let red = channel(1, 0, 0).transformed(by: CGAffineTransform(translationX: split, y: 0))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).transformed(by: CGAffineTransform(translationX: -split, y: split * 0.3))
        var out = red
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: region)

        let strips = 4 + Int(6 * k)
        let shifted = out.clampedToExtent()
        for _ in 0..<strips {
            let h = region.height * (0.03 + 0.10 * rng.next())
            let y = region.minY + (region.height - h) * rng.next()
            let dx = (rng.next() - 0.5) * 2 * region.width * 0.35 * k
            let strip = shifted
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                .cropped(to: CGRect(x: region.minX, y: y, width: region.width, height: h))
            out = strip.composited(over: out)
        }

        let blocks = 2 + Int(4 * k)
        let base = out.clampedToExtent()
        for _ in 0..<blocks {
            let bw = region.width * (0.10 + 0.25 * rng.next())
            let bh = region.height * (0.05 + 0.18 * rng.next())
            let bx = region.minX + (region.width - bw) * rng.next()
            let by = region.minY + (region.height - bh) * rng.next()
            let scale = max(6, region.width * (0.03 + 0.06 * rng.next()))
            let block = base
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputCenterKey: CIVector(x: region.minX, y: region.minY)
                ])
                .cropped(to: CGRect(x: bx, y: by, width: bw, height: bh))
            out = block.composited(over: out)
        }
        return out.cropped(to: region)
    }

    private static func makeMask(points: [CGPoint], extent e: CGRect) -> CIImage? {
        let mw = 320
        let mh = max(Int((320.0 * e.height / e.width).rounded()), 8)
        guard let ctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.setFillColor(gray: 1, alpha: 1)
        let pts = points.map { CGPoint(x: ($0.x - e.minX) / e.width * CGFloat(mw), y: ($0.y - e.minY) / e.height * CGFloat(mh)) }
        ctx.beginPath()
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath(using: .winding)
        guard let cg = ctx.makeImage() else { return nil }
        let img = CIImage(cgImage: cg)
        return img
            .transformed(by: CGAffineTransform(scaleX: e.width / CGFloat(mw), y: e.height / CGFloat(mh)))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .applyingGaussianBlur(sigma: 1.5 * e.width / CGFloat(mw))
            .cropped(to: e)
    }
}
