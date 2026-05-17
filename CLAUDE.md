# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Vigil Screen is a macOS menu bar app (Swift 6, SwiftUI, AppKit) that provides privacy protection via Panic Mode (instant full-screen blur + app hiding on ⌘⇧L), Proximity Lock (auto-lock when a paired Bluetooth device leaves range), and Shoulder Surfing Detection (auto-trigger on second face in camera feed).

- **Target:** macOS 15 Sequoia+, Xcode 16+, Swift 6.0+
- **Dependencies:** Zero external — pure Apple frameworks (CoreBluetooth, AVFoundation, Vision, LocalAuthentication, Combine, Security, QuartzCore)

## Build & Test Commands

```bash
# Open in Xcode
open VigilScreen.xcodeproj

# Build from CLI
xcodebuild -scheme VigilScreen -configuration Debug build

# Run all tests
xcodebuild -scheme VigilScreenTests -destination 'platform=macOS' test

# Run a single test class
xcodebuild -scheme VigilScreenTests -destination 'platform=macOS' test -only-testing:VigilScreenTests/AppBlocklistTests
```

No linting tools configured. No Swift Package Manager dependencies.

## Project Structure

```
VigilScreen/                        # Main app source
├── App/
│   ├── DockLockApp.swift           # @main entry — no SwiftUI window scenes
│   └── AppDelegate.swift           # App lifecycle, settings window, Accessibility alert
├── MenuBar/
│   ├── MenuBarManager.swift        # NSStatusItem + NSPopover
│   ├── MenuBarView.swift           # Popover UI (welcome gate)
│   └── WelcomeView.swift           # First-run onboarding checklist
├── Features/
│   ├── PanicMode/
│   │   ├── PanicModeManager.swift  # @MainActor — blur/hide orchestrator
│   │   ├── AppBlocklist.swift      # Safelist (bundle IDs kept visible)
│   │   └── PanicModeView.swift
│   ├── ProximityLock/
│   │   ├── BluetoothMonitor.swift  # CBCentralManager RSSI scanning
│   │   ├── LockTrigger.swift       # Hysteresis + lock action
│   │   └── ProximityView.swift
│   ├── ShoulderSurfing/
│   │   ├── ShoulderSurfingDetector.swift  # Vision + AVFoundation, ~2 fps
│   │   └── ShoulderSurfingView.swift
│   └── History/
│       └── LockHistoryView.swift
├── Core/
│   ├── LockEngine.swift            # CGSession lock + screensaver fallback
│   ├── SettingsStore.swift         # UserDefaults wrapper, @Published + Combine persist
│   ├── PermissionManager.swift     # Accessibility permission poller (@MainActor)
│   ├── IntruderCaptureManager.swift # AVCaptureSession photo on failed auth
│   ├── LockHistoryStore.swift      # JSON-encoded audit log
│   └── CloudSyncStore.swift        # NSUbiquitousKeyValueStore coordinator
├── Settings/
│   └── SettingsView.swift
└── Resources/
    ├── VigilScreen.entitlements
    └── PrivacyInfo.xcprivacy

VigilScreenTests/                   # XCTest — 39 tests, all passing
docs/superpowers/specs/             # Feature specs and design docs
.claude/agents/                     # Sub-agents: swift-reviewer, ui-reviewer, xcode-build
.claude/commands/                   # Slash commands: /version-bump, /release, /pr-preflight
.agents/                            # Release pipeline agents (release-preflight, release-publish)
```

## Architecture

### App Entry & Menu Bar
- App uses `.accessory` activation policy (no Dock icon). Opens settings window by temporarily switching to `.regular` policy, then back to `.accessory` on window close — this is intentional and required for the settings window to receive focus immediately.
- Settings window is a manually-created `NSWindow` with `NSHostingController(rootView: SettingsView())` — the standard SwiftUI `.Settings` scene doesn't work with `.accessory` policy.
- `AppDelegate.applicationDidFinishLaunching` eagerly initializes all singletons: `PanicModeManager.shared`, `LockTrigger.shared`, `ShoulderSurfingDetector.shared`.

### Panic Mode (`Features/PanicMode/`)
`PanicModeManager` orchestrates the full sequence on trigger:
1. Closes Notification Center (AX Escape)
2. Exits full-screen on non-safelisted apps via `AXUIElement`
3. Calls `.hide()` on all non-safelisted `NSRunningApplication`s
4. Shows pre-warmed `NSVisualEffectView` blur overlays on every screen (level `.screenSaver` = 1000, never lowered during panic)
5. Mutes system audio; clears clipboard (both toggleable)
6. 400ms later: re-hides any newly-windowed apps
7. Release: `LAPolicy.deviceOwnerAuthentication` (Touch ID / password / Apple Watch double-press); failure → `IntruderCaptureManager` captures camera photo

Safelisted apps are kept visible through **transparent holes** in a `CGContext`-drawn `maskImage` applied to each overlay. Holes are sourced from `CGWindowListCopyWindowInfo` (not AX) for accurate Chromium/Electron bounds. A CGEvent tap intercepts left-mouse-down to pre-apply the hole before the activation notification fires, eliminating any full-blur flash.

`AppSafelist` is persisted to `UserDefaults` under key `"panicBlocklist"` (historical naming).

### Proximity Lock (`Features/ProximityLock/`)
- `BluetoothMonitor`: continuous `CBCentralManager` RSSI scanning; 8 s silence = device absent; paired device UUID in Keychain
- `LockTrigger`: Combine-based hysteresis; if absent/RSSI below threshold for N seconds → `PanicModeManager.triggerPanic()` then `LockEngine.lockScreen()`

### Shoulder Surfing (`Features/ShoulderSurfing/`)
- `ShoulderSurfingDetector`: `AVCaptureSession` + `VNDetectFaceRectanglesRequest` at ~2 fps; triggers panic when 2+ faces are detected for `triggerThreshold` consecutive frames; auto-releases if `shoulderSurfingAutoRelease` is on

### Core Services
- `SettingsStore`: all `@Published` properties auto-persist to `UserDefaults` + optionally `NSUbiquitousKeyValueStore` via Combine `.sink`. Per-machine security settings (`panicRequiresTouchID`, `intruderCaptureEnabled`, etc.) are local-only.
- `CloudSyncStore`: listens for `NSUbiquitousKeyValueStore.didChangeExternallyNotification` and fans out updates to `SettingsStore`, `AppSafelist`, and `LockHistoryStore`.

### State Persistence
| Data | Store |
|---|---|
| All settings/toggles | `UserDefaults` |
| App safelist | `UserDefaults["panicBlocklist"]` (JSON `[String]`) |
| Lock history | `UserDefaults["lockHistory"]` (JSON `[LockEvent]`) |
| Paired BT device UUID | Keychain |
| Intruder photos | `~/Pictures/Vigil Screen Captures/<uuid>.jpg` |
| Cloud sync (subset) | `NSUbiquitousKeyValueStore` |

## Swift 6 Concurrency Rules

- `@MainActor` on all classes that touch UI, `NSApplication`, `NSWindow`, or status items
- `Sendable` required on types crossing actor boundaries
- Combine publishers used for cross-actor observation — prefer over `Task` + `await` for continuity with existing code
- `CBCentralManagerDelegate`, `AVFoundation`, `Vision` queue callbacks, and `NSEvent` global monitors **must** be dispatched to `@MainActor` explicitly before touching shared state
- `nonisolated(unsafe)` is used where a property is accessed only from a single non-main queue (e.g., `visionQueue`) — only replicate this pattern when you can guarantee single-queue access

## Conventions

- All managers are singletons (`static let shared = ...`) initialized lazily; do not add init parameters
- New features belong in `Features/<FeatureName>/` with a `Manager/Detector` + `View` pair
- Settings additions: add `@Published var` to `SettingsStore`, call `persist(\.${property}, key:)` in `init`, add to `Keys` enum, add to `allCloudKeys` if it should sync across Macs
- Do not add third-party dependencies
- Do not add telemetry, analytics, or network calls
- macOS 26 Liquid Glass: gate all `.glassEffect` usage behind `#available(macOS 26, *)` with a graceful SwiftUI fallback
- Bundle ID: `com.pisit.koolplukpol.VigilScreen` / Team ID: `VPTPA7XM79`
- Version bumping: use `/version-bump <x.y.z>` slash command (updates `project.pbxproj`)

## Test Coverage

39 tests in `VigilScreenTests/` — all passing:
- `AppBlocklistTests` — safelist CRUD and persistence
- `SettingsStoreTests` — defaults, clamping, round-trip
- `DiscoveredDeviceTests` — RSSI signal classification
- `LockTriggerTests` — countdown logic, no-op states
- `BluetoothMonitorTests` — scan state, pairing, presence timer
- `PanicModeManagerTests` — state machine (active/inactive, idempotency)

**Not unit-testable** (require real device/hardware): BT scanning, `CGSession` lock, Touch ID/Apple Watch auth, `NSApplication.hide()`, camera capture, AX interactions.
