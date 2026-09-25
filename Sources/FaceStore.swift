import Foundation
import Vision

struct FaceProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var created: Date
    var sampleCount: Int
    /// Typical match distance between this person's own samples; live distances are expressed as a ratio of it.
    var calibration: Float
}

struct MatchResult {
    let profile: FaceProfile
    let ratio: Float
}

/// Stores enrolled faces locally in ~/Library/Application Support/Glimpse/Faces (owner-only permissions).
final class FaceStore: ObservableObject {
    static let shared = FaceStore()

    @Published private(set) var profiles: [FaceProfile] = [] {
        didSet { lock.lock(); profilesCopy = profiles; lock.unlock() }
    }
    private var profilesCopy: [FaceProfile] = []
    private var prints: [UUID: [VNFeaturePrintObservation]] = [:]
    private let lock = NSLock()
    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Glimpse/Faces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        load()
    }

    private var indexURL: URL { dir.appendingPathComponent("profiles.json") }
    private func printsURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).prints") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([FaceProfile].self, from: data) else { return }
        var loaded: [UUID: [VNFeaturePrintObservation]] = [:]
        for p in list {
            if let d = try? Data(contentsOf: printsURL(p.id)),
               let arr = (try? NSKeyedUnarchiver.unarchivedObject(
                   ofClasses: [NSArray.self, VNFeaturePrintObservation.self], from: d)) as? [VNFeaturePrintObservation] {
                loaded[p.id] = arr
            }
        }
        let valid = list.filter { loaded[$0.id] != nil }
        Log.write("Loaded \(valid.count) face(s) of \(list.count) in index")
        profiles = valid
        profilesCopy = valid
        prints = loaded
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(profiles) { try? write(data, to: indexURL) }
    }

    /// Creates a new face, or adds more samples to `existing` (useful for different lighting / glasses).
    func save(name: String, samples: [VNFeaturePrintObservation], existing: FaceProfile? = nil) {
        var profile = existing ?? FaceProfile(id: UUID(), name: name, created: Date(), sampleCount: 0, calibration: 1)
        let all = (existing.flatMap { prints[$0.id] } ?? []) + samples
        profile.sampleCount = all.count
        profile.calibration = Self.calibrate(all)
        if !name.isEmpty { profile.name = name }

        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: all, requiringSecureCoding: true) else { return }
        try? write(data, to: printsURL(profile.id))

        lock.lock(); prints[profile.id] = all; lock.unlock()
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
        saveIndex()
    }

    func delete(_ profile: FaceProfile) {
        try? FileManager.default.removeItem(at: printsURL(profile.id))
        lock.lock(); prints[profile.id] = nil; lock.unlock()
        profiles.removeAll { $0.id == profile.id }
        saveIndex()
    }

    func rename(_ profile: FaceProfile, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i].name = name
        saveIndex()
    }

    /// Best (lowest) distance ratio across all enrolled faces. Safe to call from any thread.
    func match(_ p: VNFeaturePrintObservation) -> MatchResult? {
        lock.lock(); let snapshot = prints; let profilesSnapshot = profilesCopy; lock.unlock()
        var best: MatchResult?
        for profile in profilesSnapshot {
            guard let enrolled = snapshot[profile.id], !enrolled.isEmpty else { continue }
            let score = Self.score(p, against: enrolled)
            let ratio = score / max(profile.calibration, 0.0001)
            if best == nil || ratio < best!.ratio { best = MatchResult(profile: profile, ratio: ratio) }
        }
        return best
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return nil }
        return d
    }

    /// Mean of the 3 nearest enrolled samples.
    static func score(_ p: VNFeaturePrintObservation, against enrolled: [VNFeaturePrintObservation]) -> Float {
        let ds = enrolled.compactMap { distance(p, $0) }.sorted()
        let k = min(3, ds.count)
        guard k > 0 else { return .infinity }
        return ds.prefix(k).reduce(0, +) / Float(k)
    }

    /// Leave-one-out score of each sample against the others (skipping its immediate neighbours in time,
    /// which are near-duplicates), then the median. That's the "normal" distance for this person.
    static func calibrate(_ all: [VNFeaturePrintObservation]) -> Float {
        guard all.count > 4 else { return 1 }
        var scores: [Float] = []
        for i in all.indices {
            let others = all.indices.filter { abs($0 - i) > 2 }.map { all[$0] }
            if !others.isEmpty { scores.append(score(all[i], against: others)) }
        }
        scores.sort()
        return max(scores[scores.count / 2], 0.0001)
    }
}
