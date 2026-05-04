# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Vigil Screen is a macOS menu bar app (Swift 6, SwiftUI, AppKit) that provides privacy protection via:
- **Panic Mode**: Instantly blur all screens and hide non-safelisted apps (⌘⇧L), released by Touch ID
- **Proximity Lock**: Auto-locks when a paired Bluetooth device (iPhone/Watch) moves out of range

- **Target:** macOS 15 Sequoia+, Xcode 16+, Swift 6.0+
- **Dependencies:** Zero external — pure Apple frameworks (CoreBluetooth, AVFoundation, LocalAuthentication, etc.)

## Build & Test Commands

```bash
# Open in Xcode
open VigilScreen.xcodeproj

# Build from CLI
xcodebuild -scheme DockLock -configuration Debug build

# Run all tests
xcodebuild -scheme DockLockTests -destination 'platform=macOS' test

# Run a single test class
xcodebuild -scheme DockLockTests -destination 'platform=macOS' test -only-testing:DockLockTests/AppBlocklistTests
```

## Architecture

### App Entry & Menu Bar
- `DockLockApp.swift` (`VigilScreenApp`) — `@main`, uses `.accessory` activation policy (no Dock icon), no SwiftUI window scenes
- `AppDelegate.swift` — `NSApplicationDelegate`, boots menu bar, registers global hotkey (⌘⇧L via `NSEvent.addGlobalMonitorForEvents`)
- `MenuBarManager.swift` — `NSStatusItem` + `NSPopover` with dynamic height resizing
- Settings window is a manually-created `NSWindow` (SwiftUI `.Settings` scene incompatible with `.accessory` policy)

### Core Feature: Panic Mode (`Features/PanicMode/`)
- `PanicModeManager.swift` (`@MainActor`) — orchestrates the full blur/hide sequence:
  1. Closes Notification Center (hides NC process + sends Escape)
  2. Exits full-screen on non-safelisted apps via `AXUIElement` (Accessibility API)
  3. Calls `.hide()` on all apps not in `AppSafelist`
  4. Shows pre-warmed `NSVisualEffectView` blur overlays on every screen (window level -1, below normal apps)
  5. 400ms later: re-hides newly-windowed apps, lowers overlay level
  6. Release requires Touch ID (`LocalAuthentication`); on failure, `IntruderCaptureManager` saves a camera photo
- `AppSafelist.swift` — `Set<String>` (bundle IDs) persisted to `UserDefaults` as JSON

### Core Feature: Proximity Lock (`Features/ProximityLock/`)
- `BluetoothMonitor.swift` — continuous `CBCentralManager` RSSI scanning; 8-second silence = device absent; paired device UUID stored in Keychain
- `LockTrigger.swift` — Combine-based hysteresis: if device absent/RSSI below threshold for N seconds, triggers `PanicModeManager` then `LockEngine.lockScreen()`
- `DiscoveredDevice.swift` — device model with signal strength classification

### Core Services (`Core/`)
- `LockEngine.swift` — `CGSession` lock + screensaver fallback
- `SettingsStore.swift` — `UserDefaults` wrapper; all `@Published` properties auto-persist via Combine `.sink`
- `PermissionManager.swift` — polls Accessibility permission every 1s, max 60 attempts
- `LockHistoryStore.swift` — JSON-encoded lock event log; photos at `~/Pictures/Vigil Screen Captures/`
- `IntruderCaptureManager.swift` — `AVCaptureSession` photo capture on failed auth

### State Persistence
- `SettingsStore` → `UserDefaults` (all app settings/toggles)
- `AppSafelist` → `UserDefaults` (JSON array of bundle IDs)
- `LockHistoryStore` → `UserDefaults` (JSON-encoded `[LockEvent]`)
- Paired BT device UUID → Keychain
- Intruder photos → `~/Pictures/Vigil Screen Captures/<uuid>.jpg`

## Swift 6 Concurrency Rules

The project enforces strict Swift 6 concurrency. Key patterns in use:
- `@MainActor` on all classes that touch UI or `NSApplication` APIs
- `Sendable` conformance required on types crossing actor boundaries
- Combine publishers used for cross-actor state observation (not `Task` + `await`)
- `NSEvent` global monitors and `CBCentralManagerDelegate` callbacks must be dispatched to `@MainActor` explicitly

## Test Coverage

39 tests in `DockLockTests/` — all passing:
- `AppBlocklistTests` — safelist CRUD and persistence
- `SettingsStoreTests` — defaults, clamping, round-trip
- `DiscoveredDeviceTests` — RSSI thresholds
- `LockTriggerTests` — countdown logic, no-op states
- `BluetoothMonitorTests` — scan state, pairing, presence timer

**Not unit-testable** (require real device/hardware): BT scanning, CGSession lock, Touch ID, `NSApplication.hide()`.
