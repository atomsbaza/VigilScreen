# DockLock

🛡️ **Auto-lock your Mac on proximity + panic-hide sensitive apps with one hotkey**

A privacy-first macOS security app for developers, consultants, and anyone handling sensitive data (source code, credentials, API keys, documents).

[![GitHub license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](#tech-stack)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-green.svg)](#requirements)

---

## Features

### 🔒 **Proximity Lock**
Auto-lock your Mac when you step away from your desk.
- Detects when your iPhone or Apple Watch goes out of Bluetooth range
- Smart hysteresis logic prevents false triggers
- Customizable lock delay (5-30 seconds)
- Works with Bluetooth or WiFi signal strength

### 🚨 **Panic Mode**
Hide sensitive apps instantly with one keystroke.
- Single hotkey (default: `⌘+Shift+L`) hides Terminal, IDE, browsers, Slack, etc.
- Customizable blocklist — choose which apps to protect
- Release with Touch ID for added security
- Hides even full-screen applications

### 🔐 **Security First**
- **Local-first**: All processing happens on your Mac. No cloud sync, no network calls
- **Open source**: Community audits the code
- **Zero dependencies**: Pure Apple frameworks only
- **Privacy-focused**: We don't collect telemetry or analytics

---

## Screenshots & Demo

> 🎬 Demo GIF coming soon (Screen Recording + Gifski)

---

## Installation

### Option 1: Download .dmg (Recommended)

1. Download the latest release from [GitHub Releases](https://github.com/atomsbaza/DockLock/releases)
2. Open `DockLock.dmg`
3. Drag **DockLock.app** to Applications
4. Launch from Applications folder
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
2. Check apps you want to hide (default: Terminal, Xcode, VS Code, Safari, Chrome, Slack, Notion)
3. Add more apps by clicking **+** and selecting from running apps
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
│   └── AppDelegate.swift          # NSApplicationDelegate
│
├── MenuBar/
│   ├── MenuBarManager.swift       # NSStatusItem + popover
│   └── MenuBarView.swift          # SwiftUI popover UI
│
├── Features/
│   ├── PanicMode/
│   │   ├── PanicModeManager.swift # Hide/unhide app logic
│   │   ├── AppBlocklist.swift     # Managed list of apps to hide
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
│   └── PermissionManager.swift    # Requests OS permissions
│
├── Settings/
│   └── SettingsView.swift         # Main settings window
│
└── Resources/
    └── DockLock.entitlements      # App entitlements
```

---

## Tech Stack

| Component | Choice | Why |
|---|---|---|
| **Language** | Swift 6.0+ | Full concurrency support, modern syntax |
| **UI** | SwiftUI 6 + AppKit | Native macOS feel, menu bar integration |
| **Frameworks** | CoreBluetooth, LocalAuthentication, CoreGraphics, Security | Pure Apple APIs, zero external dependencies |
| **Min Target** | macOS 15 Sequoia | Latest stable APIs |
| **Build System** | Xcode 16+ | Native Swift 6 strict concurrency support |

---

## Permissions

DockLock requests only the permissions it needs:

| Permission | Why | Prompt |
|---|---|---|
| **Bluetooth** | To scan for nearby iPhone/Watch | When enabling Proximity Lock |
| **Accessibility** | To register global keyboard shortcut | When customizing Panic Mode hotkey |
| **Face ID/Touch ID** | To authenticate panic release | When enabling Panic Mode |

**What we DON'T ask for:** Camera, Microphone, Location, Network

---

## FAQ

**Q: Does DockLock work with multiple Macs?**
A: Currently no — MVP focuses on single-Mac setup. iCloud Sync is planned for Phase 2.

**Q: What if my iPhone is out of battery?**
A: Proximity Lock won't trigger. Panic Mode still works independently.

**Q: Can I hide custom apps?**
A: Yes! Click **+** in Panic Mode settings and select from running apps.

**Q: Is my data safe?**
A: Completely safe. All processing is local. No cloud, no analytics, no telemetry. It's open source — audit the code yourself.

**Q: Does it work on Apple Silicon?**
A: Yes. Optimized for M1/M2/M3 Macs.

---

## Privacy & Security

### No Cloud Storage
- Settings stay on your Mac only
- No accounts, no logins
- Bluetooth pairing info in system Keychain (encrypted)

### No Telemetry
- No usage tracking, crash reporting, or analytics

### Open Source
- Full source code on GitHub
- MIT License — fork and audit freely

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

### ✅ v0.1.0 (MVP)
- Panic Mode
- Proximity Lock (Bluetooth)
- Local settings

### 🚀 Phase 2
- Menubar stats
- Lock history log
- Intruder Capture

### 💡 Future
- iCloud Sync
- Custom app modes
- Third-party integrations

---

## License

MIT License — see [LICENSE](LICENSE).

---

## Support

- 📖 [Documentation](CONTRIBUTING.md)
- 🐛 [Report Bug](https://github.com/atomsbaza/DockLock/issues/new)
- 💡 [Request Feature](https://github.com/atomsbaza/DockLock/discussions)
- 🔒 [Security Issue](mailto:atomsbaza2@gmail.com)

---

**Made with ❤️ for developers who care about privacy**
