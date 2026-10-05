import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Normalized rectangles, origin = top-left, 0...1.
struct FingerInfo: Equatable {
    let name: String
    let rect: CGRect
    let tip: CGPoint
}

struct Detections: Equatable {
    var faces: [CGRect] = []
    var hands: [CGRect] = []
    var fingers: [FingerInfo] = []
}

/// Apple Vision: faces, hand pose, fingers. Runs on a background queue, one request at a time.
final class VisionTracker {
    private let queue = DispatchQueue(label: "cam.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var faces: [CGRect] = []
    private var facesTime = CFAbsoluteTimeGetCurrent()
    private var quadPts: [CGPoint]?
    private var quadTime = CFAbsoluteTimeGetCurrent()
    var onResult: ((Detections) -> Void)?

    func isIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !busy
    }

    /// Latest face rects (empty if stale).
    func faceRects() -> [CGRect] {
        lock.lock(); defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - facesTime < 0.5 ? faces : []
    }

    /// Latest quad [index1, index2, thumb2, thumb1] (normalized, top-left origin); nil if stale.
    func quad() -> [CGPoint]? {
        lock.lock(); defer { lock.unlock() }
        guard let q = quadPts, CFAbsoluteTimeGetCurrent() - quadTime < 0.25 else { return nil }
        return q
    }

    func reset() {
        lock.lock(); faces = []; quadPts = nil; lock.unlock()
    }

    func process(_ pb: CVPixelBuffer, faces wantFaces: Bool, hands wantHands: Bool, fingers wantFingers: Bool, quad wantQuad: Bool) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()

        queue.async {
            var result = Detections()
            var tipPairs: [(idx: CGPoint, thumb: CGPoint)] = []
            var requests: [VNRequest] = []
            let faceReq = VNDetectFaceRectanglesRequest()
            let handReq = VNDetectHumanHandPoseRequest()
            handReq.maximumHandCount = 4
            if wantFaces { requests.append(faceReq) }
            if wantHands || wantFingers || wantQuad { requests.append(handReq) }

            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            try? handler.perform(requests)

            if wantFaces {
                result.faces = (faceReq.results ?? []).map { Self.flip($0.boundingBox) }
            }
            if wantHands || wantFingers || wantQuad {
                for obs in handReq.results ?? [] {
                    if wantQuad, let all = try? obs.recognizedPoints(.all),
                       let i = all[.indexTip], let t = all[.thumbTip], i.confidence > 0.3, t.confidence > 0.3 {
                        tipPairs.append((CGPoint(x: i.location.x, y: 1 - i.location.y),
                                         CGPoint(x: t.location.x, y: 1 - t.location.y)))
                    }
                    if let all = try? obs.recognizedPoints(.all) {
                        let pts = all.values.filter { $0.confidence > 0.25 }.map { $0.location }
                        if let r = Self.bounds(of: pts, pad: 0.02) { result.hands.append(r) }
                    }
                    if wantFingers {
                        let groups: [(VNHumanHandPoseObservation.JointsGroupName, VNHumanHandPoseObservation.JointName, String)] = [
                            (.thumb, .thumbTip, "Большой"),
                            (.indexFinger, .indexTip, "Указательный"),
                            (.middleFinger, .middleTip, "Средний"),
                            (.ringFinger, .ringTip, "Безымянный"),
                            (.littleFinger, .littleTip, "Мизинец")
                        ]
                        for (g, tipName, label) in groups {
                            guard let pts = try? obs.recognizedPoints(g) else { continue }
                            let loc = pts.values.filter { $0.confidence > 0.25 }.map { $0.location }
                            guard loc.count >= 2, let r = Self.bounds(of: loc, pad: 0.008),
                                  let tip = pts[tipName], tip.confidence > 0.25 else { continue }
                            result.fingers.append(FingerInfo(name: label, rect: r,
                                                             tip: CGPoint(x: tip.location.x, y: 1 - tip.location.y)))
                        }
                    }
                }
            }

            var newQuad: [CGPoint]?
            if wantQuad && tipPairs.count >= 2 {
                let two = tipPairs.sorted { $0.idx.x < $1.idx.x }.prefix(2)
                let a = two[two.startIndex], b = two[two.startIndex + 1]
                newQuad = [a.idx, b.idx, b.thumb, a.thumb]
            }

            self.lock.lock()
            if let q = newQuad { self.quadPts = q; self.quadTime = CFAbsoluteTimeGetCurrent() }
            if wantFaces { self.faces = result.faces; self.facesTime = CFAbsoluteTimeGetCurrent() }
            self.busy = false
            self.lock.unlock()
            self.onResult?(result)
        }
    }

    /// Vision rect (origin bottom-left) -> top-left origin.
    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Bounding box of Vision points (origin bottom-left), returned with top-left origin.
    private static func bounds(of points: [CGPoint], pad: CGFloat) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let rect = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
        return flip(rect)
    }

    /// One-shot face detection for still photos.
    static func detectFaces(in image: CIImage) -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        try? handler.perform([req])
        return (req.results ?? []).map { flip($0.boundingBox) }
    }
}

enum FaceBlur {
    /// Blurs round regions around the given faces (normalized, top-left origin).
    /// `strength` 0...1 (0 = barely, 1 = very strong).
    static func apply(_ image: CIImage, faces: [CGRect], strength: Double = 0.5) -> CIImage {
        guard !faces.isEmpty else { return image }
        let e = image.extent
        var mask = CIImage(color: CIColor.black).cropped(to: e)
        for f in faces {
            let cx = e.minX + f.midX * e.width
            let cy = e.minY + (1 - f.midY) * e.height
            let r = max(f.width * e.width, f.height * e.height) * 0.75
            guard let g = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: cx, y: cy),
                "inputRadius0": r * 0.85,
                "inputRadius1": r * 1.05,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black
            ])?.outputImage else { continue }
            mask = g.cropped(to: e).applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: mask])
        }
        let sigma = max(1.5, Double(e.width) * (0.0005 + 0.015 * pow(max(0, min(1, strength)), 1.5)))
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
        return blurred
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            .cropped(to: e)
    }
}
