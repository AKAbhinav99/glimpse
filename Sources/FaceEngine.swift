import Vision
import CoreImage

struct FaceSample {
    let print: VNFeaturePrintObservation?
    let eyeOpenness: CGFloat?
    let quality: Float
    let faceCount: Int
    let boundingBox: CGRect   // normalized, origin bottom-left
}

/// Detects the most prominent face in a frame, aligns and crops it, and produces a Vision feature print for it.
final class FaceEngine {
    private let ciContext = CIContext()
    static let cropSize: CGFloat = 256

    func analyze(_ pb: CVPixelBuffer, wantPrint: Bool = true, wantQuality: Bool = false) -> FaceSample? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        let landmarksReq = VNDetectFaceLandmarksRequest()
        do { try handler.perform([landmarksReq]) } catch { return nil }
        guard let faces = landmarksReq.results, !faces.isEmpty else { return nil }
        let face = faces.max { area($0.boundingBox) < area($1.boundingBox) }!

        var quality: Float = 1
        if wantQuality {
            let qReq = VNDetectFaceCaptureQualityRequest()
            qReq.inputFaceObservations = [face]
            try? handler.perform([qReq])
            quality = qReq.results?.first?.faceCaptureQuality ?? 0
        }

        let eyes = [face.landmarks?.leftEye, face.landmarks?.rightEye].compactMap { openness($0) }
        let eyeOpenness = eyes.isEmpty ? nil : eyes.reduce(0, +) / CGFloat(eyes.count)

        let print = wantPrint ? featurePrint(pb, face: face) : nil
        return FaceSample(print: print, eyeOpenness: eyeOpenness, quality: quality,
                          faceCount: faces.count, boundingBox: face.boundingBox)
    }

    private func featurePrint(_ pb: CVPixelBuffer, face: VNFaceObservation) -> VNFeaturePrintObservation? {
        let image = CIImage(cvPixelBuffer: pb)
        let size = image.extent.size

        // Level the eyes so head tilt doesn't change the print.
        var angle: CGFloat = 0
        if let l = face.landmarks?.leftEye?.pointsInImage(imageSize: size), !l.isEmpty,
           let r = face.landmarks?.rightEye?.pointsInImage(imageSize: size), !r.isEmpty {
            let lc = centroid(l), rc = centroid(r)
            var dx = rc.x - lc.x, dy = rc.y - lc.y
            if dx < 0 { dx = -dx; dy = -dy }
            angle = atan2(dy, dx)
        }

        let box = VNImageRectForNormalizedRect(face.boundingBox, Int(size.width), Int(size.height))
        let c = CGPoint(x: box.midX, y: box.midY)
        let side = max(box.width, box.height) * 1.15
        let rotate = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: -angle).translatedBy(x: -c.x, y: -c.y)
        let crop = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        let s = Self.cropSize / side

        let img = image.transformed(by: rotate)
            .cropped(to: crop)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.1])
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))

        guard let cg = ciContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: Self.cropSize, height: Self.cropSize)) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFill
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { return nil }
        return req.results?.first
    }

    private func openness(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
        guard let pts = region?.normalizedPoints, pts.count >= 4 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let w = xs.max()! - xs.min()!
        guard w > 0 else { return nil }
        return (ys.max()! - ys.min()!) / w
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}

/// How strong a blink has to be before it counts.
enum BlinkStrength: String, CaseIterable, Identifiable {
    case light, regular, hard
    var id: String { rawValue }

    /// Eyes count as closed below this fraction of the person's normal open-eye height.
    var closeRatio: CGFloat {
        switch self {
        case .light: return 0.72
        case .regular: return 0.60
        case .hard: return 0.40
        }
    }

    /// How long the eyes must stay shut. A hard blink has to be a squeeze, not a flicker.
    var minClosed: TimeInterval { self == .hard ? 0.20 : 0 }

    var title: String {
        switch self {
        case .light: return "Light"
        case .regular: return "Regular"
        case .hard: return "Hard"
        }
    }

    var caption: String { self == .hard ? "Blink firmly to unlock" : "Blink to unlock" }
}

/// Detects a blink (open → closed → open) relative to the person's own open-eye baseline.
struct BlinkTracker {
    let strength: BlinkStrength
    private var baseline: CGFloat = 0
    private var samples = 0
    private var closedAt: TimeInterval?
    private(set) var blinkCount = 0
    private(set) var lastOpenness: CGFloat?

    init(strength: BlinkStrength = .regular) { self.strength = strength }

    var blinked: Bool { blinkCount > 0 }

    /// Current openness as a fraction of the baseline (1 = fully open), for live feedback.
    var relativeOpenness: CGFloat? {
        guard let e = lastOpenness, baseline > 0, samples >= 4 else { return nil }
        return min(e / baseline, 1)
    }

    mutating func feed(_ e: CGFloat, at t: TimeInterval) {
        lastOpenness = e
        baseline = max(e, baseline * 0.995)
        samples += 1
        guard samples >= 4, baseline > 0 else { return }
        if closedAt == nil && e < baseline * strength.closeRatio { closedAt = t }
        if let start = closedAt, e > baseline * 0.8 {
            if t - start >= strength.minClosed { blinkCount += 1 }
            closedAt = nil
        }
    }
}
