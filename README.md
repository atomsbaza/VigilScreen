# DockLock

A macOS Menu Bar app that protects sensitive information on your screen — combining **Bluetooth Proximity Detection** and **Panic Mode** for instant privacy protection. Local-first, no data leaves your device.

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Version](https://img.shields.io/badge/version-0.1.0-informational)

---

## Features

### Panic Mode
Hide all sensitive apps instantly with a single keystroke (`⌘⇧L`).

- One-shortcut hide for apps on your blocklist (Terminal, Xcode, Safari, Slack, Notion, and more)
- Touch ID / password required to restore apps
- Handles full-screen apps automatically
- Customizable app blocklist with import/export

### Proximity Lock
Automatically locks your screen when you walk away.

- Tracks RSSI of your paired iPhone via Bluetooth
- Hysteresis logic prevents false positives from brief signal drops
- Configurable lock delay (5–30 seconds) and signal threshold (-60 to -90 dBm)
- Live RSSI display and countdown timer in the menu bar

---

## Requirements

- macOS 15 Sequoia or later
- Xcode 16+ (to build from source)
- iPhone or Apple Watch for Proximity Lock

---

## Installation

### Build from Source

```bash
git clone https://github.com/atomsbaza/DockLock.git
cd DockLock
open DockLock.xcodeproj
```

Build and run in Xcode (`⌘R`).

### Permissions

DockLock will request the following permissions when needed:

| Permission | Used for |
|---|---|
| Bluetooth | Proximity Lock — detect your iPhone's RSSI |
| Accessibility | Global keyboard shortcut (`⌘⇧L`) |
| Touch ID / Face ID | Unlock Panic Mode |

No Camera, Microphone, Location, or Network access is requested or used.

---

## Architecture

```
DockLock/
├── App/               # @main entry, AppDelegate
├── MenuBar/           # NSStatusItem, popover UI
├── Features/
│   ├── PanicMode/     # Hide/unhide apps, blocklist, Touch ID release
│   └── ProximityLock/ # Bluetooth RSSI monitoring, lock trigger
├── Core/              # LockEngine, SettingsStore, PermissionManager
├── Settings/          # Settings window UI
└── Resources/         # Assets, entitlements
```

Pure Apple frameworks — no third-party dependencies.

---

## Privacy

DockLock is **fully local**. No analytics, no telemetry, no network requests. All settings are stored in `UserDefaults` and Keychain on your Mac.

---

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you'd like to change.

---

## License

[MIT](LICENSE) — Copyright (c) 2026 atomsbaza
