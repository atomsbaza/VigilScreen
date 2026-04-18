# DockLock

🛡️ **Auto-lock your Mac on proximity + panic-hide sensitive apps with one hotkey**

A privacy-first macOS security app for developers, consultants, and anyone handling sensitive data (source code, credentials, API keys, documents).

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
- No flash, no polling — blur appears on all screens in a single frame
- Release with Touch ID for added security

### 📸 **Intruder Capture**
Automatically photographs anyone who fails a panic-release attempt.
- Captures a photo from the front camera on wrong Touch ID or password attempt
- Saved locally to `~/Pictures/DockLock Captures/` — never uploaded
- Sends a macOS notification so you know even when you're away from the History tab
- Visible in the History log with thumbnail — tap to enlarge
- Toggle on/off in Settings → Panic Mode

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

> **Note:** DockLock is not notarized yet. macOS will show a security warning on first launch.
> To open it, **right-click → Open → Open anyway**, or run in Terminal:
> ```bash
> xattr -cr /Applications/DockLock.app
> ```

1. Download the latest release from [GitHub Releases](https://github.com/atomsbaza/DockLock/releases)
2. Open `DockLock.dmg`
3. Drag **DockLock.app** to Applications
4. Launch from Applications folder — right-click → Open on first launch
5. Grant permissions (Bluetooth, Accessibility) when prompted

### Option 2: Homebrew (Coming Soon)

```bash
brew install --cask docklock
```

### Option 3: Build from Source

```bash
git clone https://github.com/atomsbaza/DockLock.git
cd DockLock
open DockLock.xcodeproj
```

**Requirements:**
- Xcode 16+
- macOS 15 Sequoia or later
- Swift 6.0+

---

## Quick Start

### 1. **Enable Proximity Lock**

1. Open DockLock → Settings
2. Go to **Proximity Lock** tab
3. Toggle **Enable**
4. Click **Scan for Devices** and select your iPhone or Apple Watch
5. Tune signal threshold if needed (move farther away to adjust)

### 2. **Set Up Panic Mode**

1. Go to **Panic Mode** tab
2. Review the **App Safelist** — apps in this list stay visible above the blur (default: Terminal, Xcode, VS Code, Safari, Chrome, Slack, Notion)
3. Add trusted apps by clicking **+** and selecting from running apps, or remove ones you don't need
4. Customize keyboard shortcut (default: `⌘+Shift+L`)
5. Toggle **Require Touch ID to release** for extra security

### 3. **Test It Out**

- **Proximity Lock**: Walk away from your desk with Bluetooth enabled → Mac locks
- **Panic Mode**: Press `⌘+Shift+L` → selected apps disappear instantly

---

## Architecture

```
DockLock/
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
│   └── ProximityLock/
│       ├── BluetoothMonitor.swift # CoreBluetooth RSSI scanning
│       ├── LockTrigger.swift      # Hysteresis + lock action
│       ├── DiscoveredDevice.swift # Device model + signal strength
│       └── ProximityView.swift    # Settings UI
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
    ├── DockLock.entitlements      # App entitlements
    └── PrivacyInfo.xcprivacy      # Apple privacy manifest (notarization)
```

---

## Liquid Glass

DockLock uses the macOS 26 Liquid Glass design language when available, with a clean fallback for macOS 15–25:

| Element | macOS 26 | macOS 15–25 |
|---|---|---|
| Panic button | `.glassEffect(.regular.tint(...).interactive())` | Colored `.background` + rounded clip |
| Onboarding CTA | `.buttonStyle(.glassProminent)` | `.buttonStyle(.borderedProminent)` |

All glass effects are gated with `#available(macOS 26, *)` — the app compiles and runs identically on both targets.

---

## Tech Stack

| Component | Choice | Why |
|---|---|---|
| **Language** | Swift 6.0+ | Strict concurrency enforced across the codebase |
| **UI** | SwiftUI 6 + AppKit | Native macOS feel, menu bar integration |
| **Frameworks** | CoreBluetooth, LocalAuthentication, CoreGraphics, Security | Pure Apple APIs, zero external dependencies |
| **Liquid Glass** | macOS 26+ `.glassEffect` | Adaptive — falls back gracefully on macOS 15–25 |
| **Min Target** | macOS 15 Sequoia | Broad compatibility, Ships on all modern Macs |
| **Build System** | Xcode 16+ | Native Swift 6 strict concurrency support |

---

## Permissions

DockLock requests only the permissions it needs:

| Permission | Why | Prompt |
|---|---|---|
| **Bluetooth** | To scan for nearby iPhone/Watch | When enabling Proximity Lock |
| **Accessibility** | To register global keyboard shortcut | When customizing Panic Mode hotkey |
| **Face ID/Touch ID** | To authenticate panic release | When enabling Panic Mode |
| **Camera** | Intruder Capture photo on failed unlock | On first failed auth attempt (lazy) |

**What we DON'T ask for:** Microphone, Location, Network

---

## FAQ

**Q: Does DockLock work with multiple Macs?**
A: iCloud Sync is implemented and will be activated in v0.2.0 — it syncs Settings, App Safelist, and Lock History across all your Macs automatically.

**Q: What if my iPhone is out of battery?**
A: Proximity Lock won't trigger. Panic Mode still works independently.

**Q: Which apps stay visible during Panic Mode?**
A: Only apps in your **Safelist** remain visible above the blur (default: Terminal, Xcode, VS Code, Safari, Chrome, Slack, Notion). Everything else is hidden. Add or remove apps in Panic Mode settings.

**Q: Is my data safe?**
A: Completely safe. All processing is local. No cloud, no analytics, no telemetry. It's open source — audit the code yourself.

**Q: Does it work on Apple Silicon?**
A: Yes. Optimized for M1/M2/M3 Macs.

---

## Known Issues

| Issue | Workaround |
|---|---|
| **Panic Mode — secondary monitor not covered when connected mid-panic** | Overlays are created once at panic start. A display plugged in *after* Panic Mode is already active will not have a blur overlay — its desktop, menu bar, and non-safelisted windows remain fully visible. Re-trigger Panic Mode after connecting the display as a workaround. |
| **Panic Mode — occasional blur flash when switching windows** | Switching between a non-safelisted and a safelisted app may briefly show a blur flash. This happens because some apps (e.g. Chrome) relayout their window chrome on activation, so the transparency hole in the overlay is momentarily too narrow before correcting itself. |

---

## Privacy & Security

### Privacy-First Storage
- Settings, Safelist, and History sync via iCloud KV store (v0.2.0) — no third-party servers
- No accounts, no logins
- Bluetooth pairing info in system Keychain (encrypted)
- Intruder photos stored locally only (`~/Pictures/DockLock Captures/`) — never synced

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

### ✅ v0.1.0 (Current)
- Panic Mode — instant full-screen blur on all screens, safelist keeps trusted apps visible
- Proximity Lock (Bluetooth) — auto-triggers Panic Mode before locking
- Intruder Capture — front-camera photo on failed unlock, saved to `~/Pictures/DockLock Captures/`
- Lock History — full audit log of lock events
- Menubar Live Stats — live RSSI + countdown in menu bar
- Local settings, first-run onboarding
- Liquid Glass UI (macOS 26)
- Swift 6 strict concurrency
- Apple Privacy Manifest (PrivacyInfo.xcprivacy)

### 🔜 v0.2.0 (Planned)
- Notarized release — no Gatekeeper warning, Homebrew Cask (`brew install --cask docklock`)
- iCloud Sync activated — Settings, App Safelist, and Lock History sync across Macs

### 💡 Future
- Custom app modes (office, café, etc.)
- Multiple paired Bluetooth devices (iPhone + Apple Watch)
- Shoulder surfing detection (Core ML + Vision)

---

## License

MIT License — see [LICENSE](LICENSE).

---

## Support

- 📖 [Documentation](CONTRIBUTING.md)
- 🐛 [Report Bug](https://github.com/atomsbaza/DockLock/issues/new)
- 💡 [Request Feature](https://github.com/atomsbaza/DockLock/issues/new?labels=enhancement)
- 🔒 [Security Issue](mailto:atomsbaza2@gmail.com)

---

**Made with ❤️ for developers who care about privacy**
