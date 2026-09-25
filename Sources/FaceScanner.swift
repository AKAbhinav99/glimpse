import AVFoundation
import QuartzCore
import Vision

struct ScanInfo {
    var faceFound = false
    var match: MatchResult?
    var isMatch = false
    var blinked = false
    var blinkCount = 0
    /// Eye openness relative to normal (1 = fully open) and the level a blink must reach, for live feedback.
    var eyeOpenness: CGFloat?
    var blinkThreshold: CGFloat?
}

enum Prefs {
    static let enabled = "enabled"
    static let strictness = "strictness"         // max distance ratio accepted
    static let requireBlink = "requireBlink"
    static let minLockSeconds = "minLockSeconds"
    static let blinkStrength = "blinkStrength"

    static func register() {
        let d = UserDefaults.standard
        d.register(defaults: [
            enabled: true, strictness: 1.3, requireBlink: false, minLockSeconds: 3.0,
            blinkStrength: BlinkStrength.regular.rawValue,
        ])
        // v1 defaulted to requiring a blink; scanning is now fully automatic unless you opt in.
        if d.double(forKey: strictness) > strictnessRange.upperBound {
            d.set(strictnessRange.upperBound, forKey: strictness)
        }
        if !d.bool(forKey: "migratedV2") {
            d.set(false, forKey: requireBlink)
            d.set(true, forKey: "migratedV2")
        }
    }
    static var strength: BlinkStrength {
        BlinkStrength(rawValue: UserDefaults.standard.string(forKey: blinkStrength) ?? "") ?? .regular
    }
    /// Slider range for the match limit (lower = stricter).
    static let strictnessRange: ClosedRange<Double> = 0.8...2.0
    /// Frames in a row the same face must match before unlocking.
    static let framesRequired = 4

    static var threshold: Float {
        let v = UserDefaults.standard.double(forKey: strictness)
        return Float(min(max(v, strictnessRange.lowerBound), strictnessRange.upperBound))
    }

    /// Human-readable name for a limit value.
    static func strictnessName(_ v: Double) -> String {
        switch v {
        case ..<1.0: return "Very strict"
        case ..<1.25: return "Strict"
        case ..<1.5: return "Balanced"
        case ..<1.75: return "Relaxed"
        default: return "Lenient"
        }
    }
}

/// Runs the camera and decides when a face is recognised.
/// Success = the same enrolled face matched on `Prefs.framesRequired` consecutive frames (+ a blink when required).
final class FaceScanner {
    private let camera = Camera()
    private let engine = FaceEngine()
    private let lock = NSLock()

    var session: AVCaptureSession { camera.session }

    var onUpdate: ((ScanInfo) -> Void)?
    var onMatch: ((FaceProfile) -> Void)?
    var onTimeout: (() -> Void)?

    private var active = false
    private var deadline: Date?
    private var stopOnMatch = true
    private var requireBlink = true
    private var consecutive = 0
    private var lastID: UUID?
    private var blink = BlinkTracker()

    func start(timeout: TimeInterval?, requireBlink: Bool, stopOnMatch: Bool) {
        lock.lock()
        active = true
        deadline = timeout.map { Date().addingTimeInterval($0) }
        self.stopOnMatch = stopOnMatch
        self.requireBlink = requireBlink
        consecutive = 0
        lastID = nil
        blink = BlinkTracker(strength: Prefs.strength)
        lock.unlock()
        camera.onFrame = { [weak self] pb in self?.process(pb) }
        camera.start()
    }

    func stop() {
        lock.lock(); active = false; lock.unlock()
        camera.onFrame = nil
        camera.stop()
    }

    /// Called on the camera's video queue.
    private func process(_ pb: CVPixelBuffer) {
        lock.lock()
        guard active else { lock.unlock(); return }
        if let d = deadline, Date() > d {
            active = false
            lock.unlock()
            camera.stop()
            DispatchQueue.main.async { self.onTimeout?() }
            return
        }
        lock.unlock()

        var info = ScanInfo()
        if let sample = engine.analyze(pb) {
            info.faceFound = true
            if let e = sample.eyeOpenness { blink.feed(e, at: CACurrentMediaTime()) }
            if let p = sample.print, let m = FaceStore.shared.match(p) {
                info.match = m
                if m.ratio <= Prefs.threshold {
                    consecutive = (lastID == m.profile.id) ? consecutive + 1 : 1
                    lastID = m.profile.id
                } else {
                    consecutive = 0
                }
            } else {
                consecutive = 0
            }
        } else {
            consecutive = 0
        }
        info.blinked = blink.blinked
        info.blinkCount = blink.blinkCount
        if info.faceFound {
            info.eyeOpenness = blink.relativeOpenness
            info.blinkThreshold = blink.strength.closeRatio
        }
        info.isMatch = consecutive >= Prefs.framesRequired

        let succeeded = info.isMatch && (!requireBlink || blink.blinked)
        let profile = info.match?.profile
        if succeeded && stopOnMatch {
            lock.lock(); active = false; lock.unlock()
            camera.stop()
        }
        DispatchQueue.main.async {
            self.onUpdate?(info)
            if succeeded, let profile { self.onMatch?(profile) }
        }
    }
}
