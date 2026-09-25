import AppKit
import AVFoundation
import SwiftUI

/// What still needs doing before face unlock can work.
enum Setup {
    static var problems: [String] {
        var p: [String] = []
        if FaceStore.shared.profiles.isEmpty { p.append("Set up a face (Faces tab)") }
        if !Keychain.exists { p.append("Save your Mac password (Password tab)") }
        else if !Keychain.accessGranted { p.append("Allow access to your saved password") }
        if Camera.authorization != .authorized { p.append("Allow Camera (Settings tab)") }
        if !Unlocker.hasAccessibility { p.append("Allow Accessibility (Settings tab)") }
        return p
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let monitor = LockMonitor()
    private let scanner = FaceScanner()
    private let overlay = OverlayController()

    private var scanning = false
    private var attempts = 0
    private var lastScanEnd = Date.distantPast
    private var unlockedThisLock = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        Log.write("Glimpse launched")
        setupStatusItem()
        overlay.prepare()

        monitor.onLocked = { [weak self] in
            self?.attempts = 0
            self?.unlockedThisLock = false
        }
        monitor.onUnlocked = { [weak self] in
            guard let self else { return }
            // Let the checkmark finish playing if we just unlocked; otherwise tuck the island away.
            if self.scanning || self.overlay.model.phase != .success { self.endScan(hideAfter: 0) }
        }
        monitor.onShouldScan = { [weak self] trigger in
            guard let self else { return }
            if trigger == .wake { self.attempts = 0 }
            self.startScan(preview: false, reason: trigger.rawValue)
        }
        monitor.start()

        if Keychain.exists && !Keychain.accessGranted {
            DispatchQueue.main.async { self.askForKeychainAccess() }
        }

        let problems = Setup.problems.filter { !$0.hasPrefix("Allow access") }
        if !problems.isEmpty {
            Log.write("Setup incomplete: \(problems.joined(separator: "; "))")
        }
        // Opened by you (not automatically at login right after startup) => show Settings.
        let launchedAtStartup = ProcessInfo.processInfo.systemUptime < 180
        if !problems.isEmpty || !launchedAtStartup { openSettings() }
    }

    /// Opening Glimpse again (Applications, Launchpad, Spotlight) while it's running shows Settings.
    /// Without this nothing appears, because Glimpse only lives in the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: Scanning

    private func startScan(preview: Bool, reason: String = "preview") {
        let d = UserDefaults.standard
        guard !scanning else { return }
        if !preview {
            guard d.bool(forKey: Prefs.enabled), monitor.isLocked, !unlockedThisLock,
                  attempts < 4, Date().timeIntervalSince(lastScanEnd) > 2.0 else { return }
            let problems = Setup.problems
            guard problems.isEmpty else {
                Log.write("Scan skipped (\(reason)): \(problems.joined(separator: "; "))")
                return
            }
            Log.write("Scan started (\(reason))")
        }
        scanning = true
        if !preview { attempts += 1 }

        let requireBlink = d.bool(forKey: Prefs.requireBlink)
        overlay.model.blinkCaption = Prefs.strength.caption
        overlay.model.phase = .scanning
        overlay.model.name = ""
        overlay.show()

        scanner.onUpdate = { [weak self] info in
            guard let self, self.scanning, requireBlink, info.isMatch, !info.blinked,
                  self.overlay.model.phase == .scanning else { return }
            self.overlay.model.phase = .blink
        }
        scanner.onMatch = { [weak self] profile in
            guard let self, self.scanning else { return }
            self.overlay.model.name = profile.name
            self.overlay.model.phase = .success
            Log.write("Recognized \(profile.name)")
            if !preview {
                self.unlockedThisLock = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    if LockMonitor.screenIsLocked { Unlocker.unlock() }
                }
            }
            self.endScan(hideAfter: 1.6)
        }
        scanner.onTimeout = { [weak self] in
            guard let self, self.scanning else { return }
            self.overlay.model.phase = .failed
            Log.write("No match before timeout")
            self.endScan(hideAfter: 1.5)
        }
        scanner.start(timeout: requireBlink ? 10 : 8, requireBlink: requireBlink, stopOnMatch: true)
    }

    private func endScan(hideAfter delay: TimeInterval) {
        scanner.stop()
        scanning = false
        lastScanEnd = Date()
        overlay.hide(after: delay)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "Glimpse")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = UserDefaults.standard.bool(forKey: Prefs.enabled)
        let toggle = NSMenuItem(title: "Face Unlock", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        let problems = Setup.problems
        if problems.isEmpty {
            let status = NSMenuItem(title: "✓ Ready", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else {
            for problem in problems {
                let action = problem.hasPrefix("Allow access") ? #selector(askForKeychainAccess) : #selector(openSettings)
                menu.addItem(item("⚠︎ " + problem, action))
            }
        }
        menu.addItem(.separator())

        menu.addItem(item("Play Unlock Animation", #selector(demoAnimation)))
        menu.addItem(item("Preview Lock Scan", #selector(previewScan)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Glimpse", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Prefs.enabled), forKey: Prefs.enabled)
    }

    @objc private func previewScan() { startScan(preview: true) }

    /// Plays the island animation without using the camera: scan → blink → success.
    @objc private func demoAnimation() {
        guard !scanning else { return }
        overlay.model.phase = .scanning
        overlay.model.name = NSFullUserName().components(separatedBy: " ").first ?? ""
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.overlay.model.phase = .blink }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { self.overlay.model.phase = .success }
        overlay.hide(after: 5.0)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Glimpse"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    /// After an update macOS needs one approval before this build may read the saved password.
    @objc func askForKeychainAccess() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Glimpse to use your saved password"
        alert.informativeText = """
        Glimpse was updated, so macOS needs to confirm it can still read the password you saved.

        Next, macOS will ask for your login keychain password. Type your Mac login password and click "Always Allow" (not just "Allow").

        If that doesn't work, choose "Enter Password Again" instead.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Enter Password Again")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !Keychain.requestAccess() {
                let fail = NSAlert()
                fail.messageText = "Access wasn't allowed"
                fail.informativeText = "No problem — enter your Mac password again in the Password tab and Glimpse will save a fresh copy."
                fail.runModal()
                openSettings()
            }
        case .alertSecondButtonReturn:
            openSettings()
        default:
            break
        }
    }

    @objc private func showLog() {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Glimpse.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
