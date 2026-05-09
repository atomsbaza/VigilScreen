# Vigil Screen

🛡️ **Auto-lock your Mac on proximity + panic-hide sensitive apps with one hotkey**

A privacy-first macOS security app.

[![GitHub license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](#tech-stack)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-green.svg)](#requirements)
[![Liquid Glass](https://img.shields.io/badge/macOS%2026-Liquid%20Glass-purple.svg)](#liquid-glass)

---

## Features

### 🔒 **Proximity Lock**
Auto-lock your Mac when you step away from your desk.
- Detects when your iPhone or Apple Watch goes out of Bluetooth range
- Smart hysteresis logic prevents false triggers
- Customizable lock delay (5-30 seconds)
- Works with Bluetooth or WiFi signal strength
- **Auto-triggers Panic Mode** before locking — apps stay hidden even if the screen is woken without authentication

### 🚨 **Panic Mode**
Blur everything instantly with one keystroke — only your trusted apps stay visible.
- Single hotkey (default: `⌘+Shift+L`) blurs all screens immediately and hides non-safelisted apps
- **Safelist model**: apps you trust (Terminal, IDE, browsers, etc.) remain visible and interactive above the blur; everything else vanishes
- **Fullscreen & Chromium support**: safelisted apps remain visible whether they are in a normal window, fullscreen Space, or are Chromium-based (Chrome, Edge, Brave, Arc)
- **Audio mute** *(v0.3.3)*: system audio is silenced on panic and restored to its prior state on release
- **Clipboard clear** *(v0.3.3)*: anything in the clipboard is wiped on panic — recently-copied passwords can't be pasted by a bystander
- Release with Touch ID for added security

### 📸 **Intruder Capture**
Automatically photographs anyone who fails a panic-release attempt.
- Captures a photo from the front camera on wrong Touch ID or password attempt
- Saved locally to `~/Pictures/Vigil Screen Captures/` — never uploaded
- Sends a macOS notification so you know even when you're away from the History tab
- Visible in the History log with thumbnail — tap to enlarge
- Toggle on/off in Settings → Panic Mode

### 👀 **Shoulder Surfing Detection**
Automatically triggers Panic Mode when someone looks over your shoulder.
- Continuous face detection via Vision + AVFoundation — no camera upload, fully local
- Configurable sensitivity and minimum detection duration before triggering
- Auto-release: Panic Mode lifts automatically (no Touch ID required) once the threat clears for a set delay (3–30 s)
- Lock History records shoulder surfing events with a purple badge
- Toggle on/off in Settings → Shoulder Surfing

### 📋 **Lock History**
A full audit log of every lock event.
- Records Proximity Lock triggers, Panic Mode activations, and failed unlock attempts
- View in Settings → History
- Clear at any time

### 📊 **Menubar Live Stats**
At-a-glance Bluetooth and countdown info next to the menu bar icon.
- Shows live RSSI and lock countdown without opening the popover
- Toggle in Settings → General

### 🎉 **First-Run Onboarding**
Get set up in seconds with a guided welcome checklist.
- Live status for Accessibility, Bluetooth pairing, and app blocklist
- Opens directly from the menu bar popover
- Dismisses automatically once you're ready

### ✨ **Liquid Glass (macOS 26)**
Native macOS 26 visual design when available.
- Panic button uses `.glassEffect` with live tint (green/red)
- Onboarding footer uses `.buttonStyle(.glassProminent)`
- Graceful fallback to standard SwiftUI on macOS 15–25

### 🔐 **Security First**
- **Local-first**: All processing happens on your Mac. No network calls, no telemetry
- **iCloud Sync** *(v0.2.0)*: Settings, App Safelist, and Lock History sync across your Macs via `NSUbiquitousKeyValueStore` — never sent to third parties
- **Open source**: Community audits the code
- **Zero dependencies**: Pure Apple frameworks only
- **Privacy-focused**: We don't collect telemetry or analytics
- **PrivacyInfo.xcprivacy**: Declares all accessed APIs (Bluetooth, Keychain) for notarization compliance

---

## Screenshots & Demo

> 🎬 Demo GIF coming soon (Screen Recording + Gifski)

---

## Installation

### Option 1: Download .dmg (Recommended)

1. Download the latest release from [GitHub Releases](https://github.com/atomsbaza/VigilScreen/releases)
2. Open `Vigil Screen.dmg`
3. Drag **Vigil Screen.app** to Applications
4. Launch from Applications folder
5. Grant permissions (Bluetooth, Accessibility) when prompted

> Vigil Screen is notarized by Apple (since v0.3.0) — no Gatekeeper warning on launch.

### Option 2: Homebrew

```bash
brew install --cask atomsbaza/tap/vigil-screen
```

To upgrade later:

```bash
brew upgrade --cask vigil-screen
```

### Option 3: Build from Source

```bash
git clone https://github.com/atomsbaza/VigilScreen.git
cd VigilScreen
open VigilScreen.xcodeproj
```

**Requirements:**
- Xcode 16+
- macOS 15 Sequoia or later
- Swift 6.0+

---

## Quick Start

### 1. **Enable Proximity Lock**

1. Open Vigil Screen → Settings
2. Go to **Proximity Lock** tab
3. Toggle **Enable**
4. Click **Scan for Devices** and select your iPhone or Apple Watch
5. Tune signal threshold if needed (move farther away to adjust)

### 2. **Set Up Panic Mode**

1. Go to **Panic Mode** tab
2. Review the **App Safelist** — apps in this list stay visible above the blur (default: Terminal, Xcode, VS Code, Safari, Chrome, Slack, Notion)
3. Add trusted apps by clicking **+** and selecting from running apps, or remove ones you don't need
4. Customize keyboard shortcut (default: `⌘+Shift+L`)
5. Toggle **Require authentication to release** for extra security

> Apple Watch double-press also unlocks Panic Mode if you have **"Use your Apple Watch to unlock apps and your Mac"** enabled in **System Settings → Touch ID & Password**. Touch ID and password fallback work as well.

### 3. **Grant Accessibility Permission**

Vigil Screen will prompt for Accessibility access on every launch until it's granted — this is required for the global `⌘+Shift+L` shortcut to work.

1. Click **Open Settings** in the prompt
2. Find **Vigil Screen** in the Accessibility list and turn it **on**
3. **Quit and reopen Vigil Screen** — the shortcut will not work until you restart the app after granting permission

> **Note:** macOS requires a restart of the app any time Accessibility permission is newly granted or toggled.

### 4. **Test It Out**

- **Proximity Lock**: Walk away from your desk with Bluetooth enabled → Mac locks
- **Panic Mode**: Press `⌘+Shift+L` → selected apps disappear instantly

---

## Architecture

```
VigilScreen/
├── App/
│   ├── DockLockApp.swift          # @main entry point
│   └── AppDelegate.swift          # NSApplicationDelegate + NSWindowDelegate
│
├── MenuBar/
│   ├── MenuBarManager.swift       # NSStatusItem + dynamic-height popover
│   ├── MenuBarView.swift          # SwiftUI popover UI (welcome gate)
│   └── WelcomeView.swift          # First-run onboarding checklist
│
├── Features/
│   ├── PanicMode/
│   │   ├── PanicModeManager.swift # Blur/unhide logic (@MainActor)
│   │   ├── AppBlocklist.swift     # Safelist — apps that stay visible during panic
│   │   └── PanicModeView.swift    # Settings UI
│   │
│   ├── ProximityLock/
│   │   ├── BluetoothMonitor.swift # CoreBluetooth RSSI scanning + DiscoveredDevice model
│   │   ├── LockTrigger.swift      # Hysteresis + lock action
│   │   └── ProximityView.swift    # Settings UI
│   │
│   ├── ShoulderSurfing/
│   │   ├── ShoulderSurfingDetector.swift # Vision + AVFoundation face detection
│   │   └── ShoulderSurfingView.swift     # Settings UI
│   │
│   └── History/
│       └── LockHistoryView.swift  # Lock event audit log UI
│
├── Core/
│   ├── LockEngine.swift           # Sends lock screen command
│   ├── SettingsStore.swift        # UserDefaults wrapper
│   ├── PermissionManager.swift    # Requests OS permissions (@MainActor)
│   ├── IntruderCaptureManager.swift # Front-camera capture on failed auth
│   ├── LockHistoryStore.swift     # Persisted audit log of lock events
│   └── CloudSyncStore.swift       # iCloud KV sync coordinator (NSUbiquitousKeyValueStore)
│
├── Settings/
│   └── SettingsView.swift         # Main settings window
│
└── Resources/
    ├── VigilScreen.entitlements      # App entitlements
    └── PrivacyInfo.xcprivacy      # Apple privacy manifest (notarization)
```

---

## Liquid Glass

Vigil Screen uses the macOS 26 Liquid Glass design language when available, with a clean fallback for macOS 15–25:

| Element | macOS 26 | macOS 15–25 |
|---|---|---|
| Panic button | `.glassEffect(.regular.tint(...).interactive())` with `exclamationmark.shield.fill` icon + `⌘⇧L` shortcut hint | Filled `.background` (red/green) + rounded clip + `⌘⇧L` hint |
| Onboarding CTA | `.buttonStyle(.glassProminent)` | `.buttonStyle(.borderedProminent)` |

All glass effects are gated with `#available(macOS 26, *)` — the app compiles and runs identically on both targets.

---

## Tech Stack

| Component | Choice | Why |
|---|---|---|
| **Language** | Swift 6.0+ | Strict concurrency enforced across the codebase |
| **UI** | SwiftUI 6 + AppKit | Native macOS feel, menu bar integration |
| **Frameworks** | CoreBluetooth, LocalAuthentication, AVFoundation, Vision, CoreGraphics, Security | Pure Apple APIs, zero external dependencies |
| **Liquid Glass** | macOS 26+ `.glassEffect` | Adaptive — falls back gracefully on macOS 15–25 |
| **Min Target** | macOS 15 Sequoia | Broad compatibility, Ships on all modern Macs |
| **Build System** | Xcode 16+ | Native Swift 6 strict concurrency support |

---

## Permissions

Vigil Screen requests only the permissions it needs:

| Permission | Why | Prompt |
|---|---|---|
| **Bluetooth** | To scan for nearby iPhone/Watch | When enabling Proximity Lock |
| **Accessibility** | To register global keyboard shortcut | When customizing Panic Mode hotkey |
| **Touch ID** | To authenticate panic release | When enabling Panic Mode |
| **Camera** | Intruder Capture (failed-unlock photo) and Shoulder Surfing Detection (face detection, fully on-device) | On first failed auth attempt, or when enabling Shoulder Surfing Detection |

**What we DON'T ask for:** Microphone, Location, Network

---

## FAQ

**Q: Does Vigil Screen work with multiple Macs?**
A: Yes — iCloud Sync (added in v0.2.0) automatically syncs Settings, App Safelist, and Lock History across all your Macs.

**Q: What if my iPhone is out of battery?**
A: Proximity Lock won't trigger. Panic Mode still works independently.

**Q: Which apps stay visible during Panic Mode?**
A: Only apps in your **Safelist** remain visible above the blur (default: Terminal, Xcode, VS Code, Safari, Chrome, Slack, Notion). Everything else is hidden. Add or remove apps in Panic Mode settings.

**Q: Is my data safe?**
A: Completely safe. All processing is local. No cloud, no analytics, no telemetry. It's open source — audit the code yourself.

**Q: Does it work on Apple Silicon?**
A: Yes. Optimized for M1/M2/M3/M4 Macs.

---

## Known Issues

| Issue | Status | Workaround |
|---|---|---|
| **Panic Mode — secondary monitor not covered when connected mid-panic** | Open — planned fix in v0.3.1 | Overlays are created once at panic start. Re-trigger Panic Mode (`⌘+Shift+L` twice) after connecting the display. |

---

## Privacy & Security

### Privacy-First Storage
- Settings, Safelist, and History sync via iCloud KV store (v0.2.0) — no third-party servers
- No accounts, no logins
- Bluetooth pairing info in system Keychain (encrypted)
- Intruder photos stored locally only (`~/Pictures/Vigil Screen Captures/`) — never synced

### No Telemetry
- No usage tracking, crash reporting, or analytics

### Open Source
- Full source code on GitHub
- MIT License — fork and audit freely

### Apple Privacy Manifest
- `PrivacyInfo.xcprivacy` declares all accessed APIs (Bluetooth, Keychain)
- Required for macOS 15+ notarization
- Confirms: `NSPrivacyTracking: false`, zero collected data types

### Responsible Disclosure
Found a security issue? Report privately to [atomsbaza2@gmail.com](mailto:atomsbaza2@gmail.com). See [SECURITY.md](SECURITY.md).

---

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md).

### Ways to Help
- 🐛 Report bugs
- 💡 Suggest features
- 📝 Improve docs
- 🔍 Audit security
- 🌍 Translate

---

## Roadmap

### ✅ v0.1.0
- Panic Mode — instant full-screen blur on all screens, safelist keeps trusted apps visible
- Proximity Lock (Bluetooth) — auto-triggers Panic Mode before locking
- Intruder Capture — front-camera photo on failed unlock, saved to `~/Pictures/Vigil Screen Captures/`
- Lock History — full audit log of lock events
- Menubar Live Stats — live RSSI + countdown in menu bar
- Local settings, first-run onboarding
- Liquid Glass UI (macOS 26)
- Swift 6 strict concurrency
- Apple Privacy Manifest (PrivacyInfo.xcprivacy)

### ✅ v0.2.0
- iCloud Sync — Settings, App Safelist, and Lock History sync across Macs via `NSUbiquitousKeyValueStore`

### ✅ v0.2.1
- Fix: eliminated overlay flash when switching to a safelisted app during Panic Mode — overlay alpha resets instantly on activation, mask rebuilds after a 70 ms settling window, then fades back in over 180 ms

### ✅ v0.3.0
- Shoulder Surfing Detection — continuous face detection via Vision + AVFoundation; triggers Panic Mode automatically when 2+ faces are detected for a configurable duration
- Sensitivity slider and live face count in Settings → Shoulder Surfing tab
- Auto-release: camera stays running during Panic Mode; releases without Touch ID after the threat clears for a set delay (3–30 s)
- Lock History shows shoulder surfing events with a purple badge
- Camera API declared in PrivacyInfo.xcprivacy
- Notarized release — no Gatekeeper warning

### ✅ v0.3.1
- iCloud Key-Value Storage entitlement enabled

### ✅ v0.3.2
- Fix: crash on launch when iCloud sync contained duplicate lock history UUIDs (`Dictionary(uniqueKeysWithValues:)` → `uniquingKeysWith:`)

### ✅ v0.3.3 (Current)
- Panic Mode now mutes system audio on trigger and restores the prior mute state on release
- Panic Mode now clears the clipboard on trigger (not restored — intentional, prevents bystanders from pasting copied passwords)
- Both behaviors are toggleable in Settings → Panic Mode

### 🔜 Planned
- Fix: blur overlay for secondary monitors
- Custom app modes / profiles (office, café, travel)
- Multiple paired Bluetooth devices (iPhone + Apple Watch)

---

## License

MIT License — see [LICENSE](LICENSE).

---

## Support

- 📖 [Documentation](CONTRIBUTING.md)
- 🐛 [Report Bug](https://github.com/atomsbaza/VigilScreen/issues/new)
- 💡 [Request Feature](https://github.com/atomsbaza/VigilScreen/issues/new?labels=enhancement)
- 🔒 [Security Issue](mailto:atomsbaza2@gmail.com)

---

**Made with ❤️ for developers who care about privacy**
