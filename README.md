# Glimpse

**Face unlock for your Mac, with an iPhone-style Face ID animation.**

Glimpse is a small menu bar app. When your Mac's lock screen appears, it uses the built-in camera to look for a face you've set up. If it recognizes you, it unlocks the Mac. While it scans, a Face ID animation grows out of the notch at the top of the screen, like the iPhone's Dynamic Island.

It's an open, local-only alternative to apps like Glance. You can read every line of code that touches your password.

---

## Features

- **Face setup you control:** faces are only added when you enroll them (about 30 samples while you slowly move your head). You can add more than one person, add samples in different lighting or with glasses, rename faces, or delete them.
- **Automatic scanning:** scanning starts when the lock screen appears, when the display wakes, or when you touch the keyboard or trackpad while locked. You don't need to click or blink.
- **Dynamic Island animation:** on Macs with a notch, the notch expands into a black panel. The Face ID icon looks around while scanning, turns into a spinning ring, draws a checkmark, and then shrinks back. If recognition fails, the panel shakes. On Macs without a notch, a pill drops in from the top of the screen.
- **Test mode:** a live camera view shows your match score against the limit, so you can check that other people (and photos) are rejected.
- **Adjustable strictness:** a Strict ↔ Lenient slider, an optional blink check, and a delay before scanning starts.
- **Local only:** no network code at all. Face data and settings never leave your Mac.
- **Diagnostic log:** `~/Library/Logs/Glimpse.log` records lock and scan events. It never contains images or your password.

## Installing

1. Download `Glimpse.dmg` from the [Releases](../../releases) page, or build it yourself (see below).
2. Open the DMG and drag **Glimpse** into **Applications**.
3. Open Glimpse. A face icon appears in the menu bar and the setup window opens.

> The app is signed with a local self-signed certificate, not an Apple Developer ID. If macOS blocks a downloaded copy, right-click the app, choose **Open**, then **Open** again. Building it yourself avoids this.

## Setup

| Tab | What to do |
| --- | --- |
| **Faces** | Click **Set Up a Face…**, enter a name, and slowly move your head until the ring fills. |
| **Password** | Enter your Mac login password. Glimpse checks it's correct before saving it (see [Security](#security)). |
| **Settings** | Allow **Camera** and **Accessibility**, and turn on **Open Glimpse at login**. |
| **Test** | Check that you're recognized. Then try someone else, or a photo of you; they should stay above the limit. |

The menu bar icon shows **✓ Ready** once everything is set up. Otherwise it lists what's missing.

Menu bar options:
- **Face Unlock**: turn the feature on or off
- **Play Unlock Animation**: demo of the animation without using the camera
- **Preview Lock Scan**: a real camera scan with the animation, without unlocking
- **Settings…**, **Show Log**, **Quit**

## How it works

```
Lock screen appears / display wakes / you touch the keyboard
        │
        ▼
LockMonitor ── starts ──▶ FaceScanner (camera + Vision)
        │                          │
        │          same enrolled face matches on 3 frames in a row
        ▼                          ▼
Dynamic Island animation     Unlocker types your password
(above the lock screen)      from the Keychain + Return
```

1. **Detecting the lock screen:** `LockMonitor` listens for the `com.apple.screenIsLocked` / `screenIsUnlocked` notifications and for screen wake. While locked, it checks keyboard and mouse idle time to notice when you come back.
2. **Recognition:** `FaceEngine` uses Apple's Vision framework to find the largest face. It levels the eyes, crops the face, converts it to grayscale, and computes a `VNFeaturePrint`. `FaceStore` compares that with your enrolled samples. The score is a ratio against your own typical variation (worked out when you enroll), so **lower = more similar**. A frame counts as a match when the ratio is under the limit (default 1.6), and the same face has to match on 3 frames in a row.
3. **Animation above the lock screen:** normal windows can't draw over the lock screen. `Overlay.swift` uses the private SkyLight window-server API (the same approach as [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow)) to put the window on space level 400, which sits just above the lock screen (level 300).
4. **Unlocking:** macOS has no public API for unlocking the screen. Glimpse, like Glance and every similar app, types your password into the lock screen and presses Return, using Accessibility access. It matches your keyboard layout, clears the field first, and tries only once per scan.

## Security

Please read this before using it.

- **Your password:** apps like this all need your password, because typing it is the only way to unlock. Glimpse stores it only in **your login Keychain**, limited to this app's code signature. It's never written to a file, logged, or sent anywhere, and it's only read at the moment of unlocking. The app checks the password against your account (OpenDirectory) before saving, so it never types a wrong one.
- **Not as strong as Face ID:** Macs don't have the iPhone's 3D depth camera. Recognition uses the regular webcam and Vision feature prints, which aren't designed for identity checks. Someone who looks like you, or a good photo or video of you, *might* get through. To reduce that risk:
  - Use the **Test** tab to set the strictness slider as strict as still works for you.
  - Turn on **Require a blink** (off by default) to make photos much harder to use.
  - Don't rely on Glimpse where strong security matters.
- **Face data:** stored as feature prints (not photos) in `~/Library/Application Support/Glimpse/Faces`, readable only by your user account.
- **Limits on attempts:** up to 4 automatic scans per lock (the count resets when the screen wakes), each lasting about 8 seconds. After a successful unlock it won't scan again until the next lock.
- **Private API:** the lock-screen animation uses an undocumented macOS API. A future macOS update could break it. If it does, the animation stops showing, but recognition and unlocking still work.

## Building from source

Requirements: macOS 14 or later, and Xcode (or the Xcode Command Line Tools with Swift 5.9+).

```bash
./build.sh
```

This:
1. compiles a universal (Apple Silicon + Intel) binary with `swiftc`,
2. generates the app icon,
3. signs the app. `scripts/signing.sh` creates a **self-signed code-signing certificate** once, in its own keychain at `~/Library/Application Support/Glimpse-Signing` (not your login keychain). Every build is signed with it, so macOS keeps Camera and Accessibility permission and Keychain access when you rebuild,
4. packages `Glimpse.dmg` with an Applications shortcut.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Accessibility not allowed" even though it's switched on | The switch belongs to an older copy of the app. In **Settings**, click **Fix & Allow**, then turn Glimpse on again. |
| "Re-enter your password" | The password was saved by an older copy of the app. Enter it again in the **Password** tab. |
| No animation on the lock screen | Choose **Show Log** from the menu bar icon and look for `Scan skipped` (it says what's missing) or `SkyLight` errors. |
| Doesn't recognize you | In **Faces**, click **Add Samples** in the lighting you usually use, or move the slider toward Lenient. |
| Recognizes someone else | Move the slider toward Strict and turn on the blink check. |
| Changed your Mac password | Update it in the **Password** tab. |

## Project layout

```
Sources/
  main.swift          App delegate, menu bar, scan flow
  LockMonitor.swift   Lock / unlock / wake / activity detection
  Camera.swift        AVCaptureSession wrapper
  FaceEngine.swift    Vision face detection, alignment, feature prints, blink tracking
  FaceStore.swift     Enrolled faces on disk, matching, calibration
  FaceScanner.swift   Match decision logic, preferences
  Overlay.swift       Dynamic Island animation + SkyLight lock-screen window
  Unlocker.swift      Keychain, password verification, keystroke typing
  SettingsView.swift  SwiftUI setup window (Faces / Test / Password / Settings)
  Log.swift           Diagnostic log
Resources/Info.plist
scripts/make_icon.swift, scripts/signing.sh
build.sh
```

## Uninstalling

1. Quit Glimpse from the menu bar and delete it from Applications.
2. Delete `~/Library/Application Support/Glimpse`, `~/Library/Application Support/Glimpse-Signing`, and `~/Library/Logs/Glimpse.log`.
3. In Keychain Access, delete the item **"Glimpse unlock password"**.
4. Remove Glimpse under System Settings → Privacy & Security → Camera / Accessibility.

## License

MIT
