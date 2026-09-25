import AppKit
import Carbon
import IOKit.pwr_mgt
import OpenDirectory
import Security

/// The unlock password lives only in your login Keychain, readable only by this app.
enum Keychain {
    private static let service = "com.local.glimpse.unlock"
    private static var account: String { NSUserName() }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(_ password: String) -> Bool {
        delete()
        var q = base
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "Glimpse unlock password"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// True when this app can read the password without macOS asking first
    /// (a prompt at the lock screen would block unlocking).
    static var readableWithoutPrompt: Bool { loadSilently() != nil }

    static func loadSilently() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { Log.write("Keychain read without prompt failed: \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static var exists: Bool {
        var q = base
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
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
        guard var password = Keychain.loadSilently() else { Log.write("Unlock aborted: password unavailable"); return }
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
