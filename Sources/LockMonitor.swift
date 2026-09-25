import AppKit
import CoreGraphics

/// Watches for the lock screen and tells the app when you've "opened" it
/// (display woke up, or you touched the keyboard / trackpad while locked).
final class LockMonitor {
    enum Trigger: String { case locked, wake, activity }

    var onShouldScan: ((Trigger) -> Void)?
    var onLocked: (() -> Void)?
    var onUnlocked: (() -> Void)?

    private(set) var isLocked = false
    private(set) var lockedAt = Date()
    private var timer: Timer?
    private var lastIdle: Double = .infinity

    static var screenIsLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.didLock()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.didUnlock()
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if Self.screenIsLocked {
                    if !self.isLocked { self.didLock() }
                    self.onShouldScan?(.wake)
                }
            }
        }
        if Self.screenIsLocked { didLock() }
    }

    private func didLock() {
        guard !isLocked else { return }
        isLocked = true
        lockedAt = Date()
        lastIdle = .infinity
        Log.write("Screen locked")
        onLocked?()
        // Automatically start looking once the lock screen has been up for a moment
        // (only if the display is on — no point scanning a sleeping screen).
        let delay = UserDefaults.standard.double(forKey: Prefs.minLockSeconds)
        let lockTime = lockedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isLocked, self.lockedAt == lockTime,
                  CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
            self.onShouldScan?(.locked)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func didUnlock() {
        guard isLocked else { return }
        Log.write("Screen unlocked")
        isLocked = false
        timer?.invalidate()
        timer = nil
        onUnlocked?()
    }

    private func poll() {
        guard Self.screenIsLocked else { didUnlock(); return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        defer { lastIdle = idle }
        let minLocked = UserDefaults.standard.double(forKey: Prefs.minLockSeconds)
        // Idle time dropped => someone just touched the keyboard/mouse at the lock screen.
        if idle < 1.0 && idle < lastIdle && Date().timeIntervalSince(lockedAt) >= minLocked {
            onShouldScan?(.activity)
        }
    }
}
