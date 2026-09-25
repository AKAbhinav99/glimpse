import AppKit
import Carbon
import CryptoKit
import IOKit.pwr_mgt
import OpenDirectory
import Security

/// The unlock password lives only in your login Keychain, readable only by this app.
///
/// Without a paid Apple Developer ID, macOS ties Keychain access to the exact build that saved the
/// password, so after an update macOS asks once before the new build may read it. To avoid surprise
/// prompts (or prompt loops), Glimpse never reads the password in the background: it remembers which
/// build has been granted access and only reads when unlocking, or when you explicitly allow access.
enum Keychain {
    private static let service = "com.local.glimpse.unlock"
    private static let accountKey = "keychainAccount"
    private static let grantedKey = "keychainGrantedBuild"

    /// Each save uses a fresh account name so saving never has to touch (and get prompted for) an older item.
    private static var account: String {
        UserDefaults.standard.string(forKey: accountKey) ?? NSUserName()
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Fingerprint of this exact build of the app.
    static let buildID: String = {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url) else { return "unknown" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }()

    /// This build has been allowed to read the password (so reading it at the lock screen won't prompt).
    static var accessGranted: Bool {
        exists && UserDefaults.standard.string(forKey: grantedKey) == buildID
    }

    private static func markGranted(_ granted: Bool) {
        UserDefaults.standard.set(granted ? buildID : nil, forKey: grantedKey)
    }

    @discardableResult
    static func save(_ password: String) -> Bool {
        let newAccount = "\(NSUserName())-\(Int(Date().timeIntervalSince1970))"
        var q = query(newAccount)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "Glimpse unlock password"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.write("Keychain save failed: \(status)")
            return false
        }
        UserDefaults.standard.set(newAccount, forKey: accountKey)
        markGranted(true)   // this build created it, so it can read it without asking
        Log.write("Password saved to Keychain")
        return true
    }

    /// Reads the password. Only call this at unlock time (when `accessGranted`) or when the user
    /// has just asked to allow access, because macOS may show its Keychain prompt.
    static func load() -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            Log.write("Keychain read failed: \(status)")
            if status == errSecUserCanceled || status == errSecAuthFailed { markGranted(false) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Asks macOS for access right now (the user is present). Returns true if access was allowed.
    static func requestAccess() -> Bool {
        guard load() != nil else { return false }
        markGranted(true)
        Log.write("Keychain access allowed for this build")
        return true
    }

    /// Only checks that an item exists (attributes only, never prompts).
    static var exists: Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query(account) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: accountKey)
        markGranted(false)
    }
}

/// Checks a password against your macOS account, so we never store (and later type) a wrong one.
enum PasswordVerifier {
    static func verify(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}

enum Unlocker {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Clears a stale Accessibility entry (left over from an older build) and asks again.
    static func resetAndRequestAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.local.glimpse"]
        try? p.run()
        p.waitUntilExit()
        requestAccessibility()
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Types the stored password into the lock screen and presses Return. Tries once per call.
    static func unlock() {
        guard hasAccessibility else { Log.write("Unlock aborted: Accessibility permission missing"); return }
        guard Keychain.accessGranted else { Log.write("Unlock aborted: Keychain access not allowed for this build yet"); return }
        guard var password = Keychain.load() else { Log.write("Unlock aborted: password unavailable"); return }
        Log.write("Typing password at lock screen")

        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Glimpse unlock" as CFString, kIOPMUserActiveLocal, &assertion)

        let map = KeyMap.current()
        DispatchQueue.global(qos: .userInteractive).async {
            let typer = KeyTyper(map: map)
            usleep(150_000)
            // Clear anything already typed into the field (e.g. the key that woke the screen).
            typer.selectAllAndDelete()
            usleep(60_000)
            typer.type(password)
            usleep(40_000)
            typer.press(CGKeyCode(kVK_Return))
            password = ""
            if assertion != 0 { IOPMAssertionRelease(assertion) }
        }
    }
}

/// Maps characters to key codes for the *current* keyboard layout, so typing works on non-US layouts too.
struct KeyMap {
    var keys: [Character: (CGKeyCode, CGEventFlags)] = [:]

    static func current() -> KeyMap {
        var map = KeyMap()
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return map }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let modifierSets: [(UInt32, CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for (mod, flags) in modifierSets {
                for code in 0..<128 {
                    var dead: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mod,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &dead, 4, &len, &chars)
                    guard status == noErr, len == 1,
                          let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let ch = Character(scalar)
                    if map.keys[ch] == nil { map.keys[ch] = (CGKeyCode(code), flags) }
                }
            }
        }
        return map
    }
}

struct KeyTyper {
    let map: KeyMap
    private let source = CGEventSource(stateID: .hidSystemState)

    init(map: KeyMap) { self.map = map }

    func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(8_000)
        up?.post(tap: .cghidEventTap)
        usleep(12_000)
    }

    func selectAllAndDelete() {
        let a = map.keys["a"]?.0 ?? CGKeyCode(kVK_ANSI_A)
        press(a, flags: .maskCommand)
        press(CGKeyCode(kVK_Delete))
        for _ in 0..<3 { press(CGKeyCode(kVK_Delete)) }
    }

    func type(_ text: String) {
        for ch in text {
            if let (code, flags) = map.keys[ch] {
                press(code, flags: flags)
            } else {
                // Fallback for characters not on the current layout.
                var utf16 = Array(String(ch).utf16)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down?.post(tap: .cghidEventTap)
                usleep(8_000)
                up?.post(tap: .cghidEventTap)
                usleep(12_000)
            }
        }
    }
}
