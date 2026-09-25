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
- **Adjustable strictness:** a Strict ↔ Lenient slider, an optional blink check with three strengths (**Light**, **Regular**, **Hard**), and a delay before scanning starts.
- **Local only:** no network code at all. Face data and settings never leave your Mac.
- **Diagnostic log:** `~/Library/Logs/Glimpse.log` records lock and scan events. It never contains images or your password.

## Installing

1. Download `Glimpse.dmg` from the [Releases](../../releases) page, or build it yourself (see below).
2. Open the DMG and drag **Glimpse** into **Applications**.
3. Open Glimpse. A face icon appears in the menu bar and the setup window opens.

> **Seeing "Glimpse" Not Opened?** That's expected the first time. See [Fixing "Glimpse Not Opened"](#fixing-glimpse-not-opened) below.

### Install or update with one command

Paste this into Terminal. It quits Glimpse if it's running, downloads the **latest** release, replaces the copy in Applications, and opens it. Because it downloads with Terminal, the "Glimpse Not Opened" warning doesn't appear.

```bash
osascript -e 'quit app "Glimpse"' 2>/dev/null; curl -fL -o /tmp/Glimpse.dmg https://github.com/AKAbhinav99/glimpse/releases/latest/download/Glimpse.dmg && hdiutil attach -nobrowse -quiet /tmp/Glimpse.dmg -mountpoint /tmp/GlimpseDMG && rm -rf /Applications/Glimpse.app && cp -R /tmp/GlimpseDMG/Glimpse.app /Applications/ && hdiutil detach -quiet /tmp/GlimpseDMG && xattr -dr com.apple.quarantine /Applications/Glimpse.app && open /Applications/Glimpse.app
```

Your faces and settings are kept when you update.

### After an update: allow access to your saved password

Glimpse isn't signed with a paid Apple Developer ID, so macOS links your saved password to the exact version of the app that saved it. After each update, Glimpse shows **"Allow Glimpse to use your saved password"** once:

- **Enter Password Again** (easiest): type your Mac password in the **Password** tab and click **Replace**.
- **Continue**: macOS asks for your login keychain password. Type your Mac password and click **Always Allow** (not just *Allow*).

Until you do one of these, Glimpse won't try to unlock, and it never shows Keychain prompts in the background or at the lock screen. You can also do this later from the menu bar icon (**⚠︎ Allow access to your saved password**).

### Opening Settings

Glimpse lives in the menu bar and has no Dock icon. To open Settings, either:
- click the face icon in the menu bar and choose **Settings…**, or
- open **Glimpse** from Applications, Launchpad or Spotlight. The Settings window appears even if Glimpse is already running.

> On MacBooks with a notch, menu bar icons can be hidden behind the notch when the menu bar is full. If you can't see the face icon, open Glimpse from Applications instead.

## Fixing "Glimpse Not Opened"

The first time you open Glimpse, macOS may show:

> **"Glimpse" Not Opened**
> Apple could not verify "Glimpse" is free of malware that may harm your Mac or compromise your privacy.

**Why this happens:** Apple only trusts apps automatically when the developer pays for an Apple Developer account ($99/year) and sends every build to Apple to be checked ("notarized"). Glimpse is a free, open-source project, so it isn't notarized. The warning doesn't mean anything was found in the app; it means Apple hasn't checked it. You can read all the code in this repo.

**Don't click "Move to Trash".** Click **Done**, then use one of these fixes.

### Option 1: Allow it in System Settings (recommended)

1. Try to open **Glimpse** from Applications once, so the warning appears, then click **Done**.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the **Security** section. You'll see *"Glimpse" was blocked to protect your Mac.*
4. Click **Open Anyway**.
5. Enter your Mac password (or use Touch ID) when asked.
6. Open Glimpse again and click **Open Anyway** in the final dialog.

You only need to do this once. After that, Glimpse opens normally.

> On macOS 14 (Sonoma) you can also right-click Glimpse in Applications, choose **Open**, then click **Open** again. From macOS 15 (Sequoia) onward, that shortcut was removed, so use the steps above.

### Option 2: Use Terminal

If you're comfortable with Terminal, this removes the "downloaded from the internet" flag from Glimpse only:

```bash
xattr -dr com.apple.quarantine /Applications/Glimpse.app
```

Then open Glimpse normally.

### Option 3: Build it yourself

Apps you build on your own Mac aren't marked as downloaded, so this warning never appears. See [Building from source](#building-from-source).

> **Only do this for a copy you got from this repository** ([AKAbhinav99/glimpse](https://github.com/AKAbhinav99/glimpse)). Don't bypass this warning for copies from anywhere else.

## Setup

| Tab | What to do |
| --- | --- |
| **Faces** | Click **Set Up a Face…**, enter a name, and slowly move your head until the ring fills. |
| **Password** | Enter your Mac login password. Glimpse checks it's correct before saving it (see [Security](#security)). |
| **Settings** | Allow **Camera** and **Accessibility**, and turn on **Open Glimpse at login**. |
| **Test** | Check that you're recognized. Then try someone else, or a photo of you; they should stay above the limit. The **Eyes** bar shows how open your eyes are, so you can check that your blink registers. |

### Blink check (optional)

Blinking is **off by default**, and Glimpse unlocks as soon as it recognizes you. If you want extra protection against photos, turn on **Also require a blink** in the **Settings** tab and choose how strong the blink has to be:

| Strength | What counts | Good for |
| --- | --- | --- |
| **Light** | Any normal blink, even a small one | Convenience; works best with glasses or in dim light |
| **Regular** (default) | A clear, normal blink | A good balance |
| **Hard** | Squeezing your eyes shut for about ⅕ of a second | The strongest protection; a quick natural blink won't count |

Try each one in the **Test** tab. The Eyes bar has to drop past the line and come back up for a blink to count. When a blink is required, the lock screen shows *"Blink to unlock"*, or *"Blink firmly to unlock"* on Hard.

The menu bar icon shows **✓ Ready** once everything is set up. Otherwise it lists what's missing.

Menu bar options:
- **Face Unlock**: turn the feature on or off
- **Play Unlock Animation**: demo of the animation without using the camera
- **Preview Lock Scan**: a real camera scan with the animation, without unlocking
- **⚠︎ items**: anything that still needs setting up. Click one to fix it.
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

- **Your password:** apps like this all need your password, because typing it is the only way to unlock. Glimpse stores it only in **your login Keychain**, limited to this app's code signature. It's never written to a file, logged, or sent anywhere. It's only read at the moment of unlocking, never in the background, so Glimpse can't trigger surprise Keychain prompts. The app checks the password against your account (OpenDirectory) before saving, so it never types a wrong one.
- **Not as strong as Face ID:** Macs don't have the iPhone's 3D depth camera. Recognition uses the regular webcam and Vision feature prints, which aren't designed for identity checks. Someone who looks like you, or a good photo or video of you, *might* get through. To reduce that risk:
  - Use the **Test** tab to set the strictness slider as strict as still works for you.
  - Turn on **Also require a blink** (off by default) to make photos much harder to use. Set the strength to **Hard** for the most protection, since a quick flicker in a video won't count.
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
| "Glimpse" Not Opened / "Apple could not verify…" | See [Fixing "Glimpse Not Opened"](#fixing-glimpse-not-opened). |
| "Accessibility not allowed" even though it's switched on | The switch belongs to an older copy of the app. In **Settings**, click **Fix & Allow**, then turn Glimpse on again. |
| "Allow access to your saved password" / Keychain prompts after updating | Normal once per update. See [After an update](#after-an-update-allow-access-to-your-saved-password). The easiest fix is to enter your password again in the **Password** tab. |
| Opening Glimpse seems to do nothing / "loading forever" | Update to 1.2 or later: opening Glimpse now always shows Settings. On older versions, use the menu bar icon (it may be hidden behind the notch). |
| No animation on the lock screen | Choose **Show Log** from the menu bar icon and look for `Scan skipped` (it says what's missing) or `SkyLight` errors. |
| Doesn't recognize you | In **Faces**, click **Add Samples** in the lighting you usually use, or move the slider toward Lenient. |
| Recognizes someone else | Move the slider toward Strict and turn on the blink check. |
| Blink isn't detected | Use the **Test** tab to watch the Eyes bar. Choose a lighter blink strength, or add face samples in better light. |
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
3. In Keychain Access, search for **"Glimpse unlock password"** and delete every item it finds (re-saving the password creates a new item).
4. Remove Glimpse under System Settings → Privacy & Security → Camera / Accessibility.

## License

MIT
