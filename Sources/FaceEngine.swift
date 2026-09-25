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

/// Detects a blink (open → closed → open) relative to the person's own open-eye baseline.
struct BlinkTracker {
    private var baseline: CGFloat = 0
    private var samples = 0
    private var closed = false
    private(set) var blinked = false

    mutating func feed(_ e: CGFloat) {
        baseline = max(e, baseline * 0.995)
        samples += 1
        guard samples >= 4, baseline > 0 else { return }
        if !closed && e < baseline * 0.6 { closed = true }
        if closed && e > baseline * 0.8 { closed = false; blinked = true }
    }
}
