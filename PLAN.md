# DockLock — MVP Plan

> macOS security app สำหรับคนที่ทำงานกับข้อมูลสำคัญ
> Open Source | SwiftUI | Privacy-first
> **GitHub:** https://github.com/atomsbaza/DockLock

---

## Overview

DockLock คือ macOS Menu Bar app ที่ช่วยปกป้องข้อมูลสำคัญบนหน้าจอ
ด้วยการผสม Bluetooth Proximity Detection และ Panic Mode เข้าด้วยกัน
เน้น Local-first — ไม่มีข้อมูลออกไปหา Server ภายนอกเลย

**สำหรับใคร:** Developers, security professionals, consultants, anyone handling sensitive data

**Distribution:** Open Source (GitHub) + Direct Download (.dmg)
ไม่ผ่าน App Store เพื่อใช้ entitlements เต็มรูปแบบ

---

## MVP Scope (Phase 1)

สองฟีเจอร์หลักที่ทำได้เร็ว คุ้มค่า และ impress ได้ทันที:

| Feature | ประโยชน์ | ความยาก |
|---|---|---|
| **Panic Mode** | ซ่อนแอปที่มีข้อมูลสำคัญด้วยปุ่มเดียว | ต่ำ |
| **Proximity Lock** | Lock เมื่อเดินออกห่าง Bluetooth | ปานกลาง |

ฟีเจอร์ที่เลื่อนไป Phase 2: Intruder Capture, Shoulder Surfing AI

---

## Tech Stack

```
Language:     Swift 6.0+ (full concurrency support)
UI:           SwiftUI 6 + AppKit (NSStatusItem)
Min Target:   macOS 15 Sequoia (2024+)
Xcode:        Xcode 16+
SPM:          Swift Package Manager 5.9+

Core Frameworks:
  - AppKit      (NSRunningApplication, NSWorkspace, NSStatusItem)
  - SwiftUI     (View, @main, ObservableObject)
  - CoreBluetooth (CBCentralManager, CBPeripheral, RSSI)
  - LocalAuthentication (LAContext, biometric auth)
  - CoreGraphics (CGEvent, CGWindowListCreateImage)
  - Security    (Keychain — store Bluetooth peripheral UUID)
  - ServiceManagement (SMAppService — launch at login)
  - Vision      (Phase 2 — person detection for shoulder surfing)

Dependencies: None (pure Apple frameworks, no third-party)
Build:        Xcode project, notarized .dmg
CI:           GitHub Actions (build + notarize + release)
Distribution: Direct download + Homebrew Cask
```

---

## Architecture

```
DockLock/
├── App/
│   ├── DockLockApp.swift          # @main entry point
│   └── AppDelegate.swift          # NSApplicationDelegate
│
├── MenuBar/
│   ├── MenuBarManager.swift       # NSStatusItem setup
│   └── MenuBarView.swift          # SwiftUI popover UI
│
├── Features/
│   ├── PanicMode/
│   │   ├── PanicModeManager.swift # Logic: hide/blur apps
│   │   ├── AppBlocklist.swift     # รายชื่อแอปที่ต้องซ่อน
│   │   └── PanicModeView.swift    # Settings UI
│   │
│   └── ProximityLock/
│       ├── BluetoothMonitor.swift # CoreBluetooth RSSI tracking
│       ├── LockTrigger.swift      # Hysteresis logic + lock action
│       └── ProximityView.swift    # Settings UI
│
├── Core/
│   ├── LockEngine.swift           # ส่ง CGEvent lock screen
│   ├── SettingsStore.swift        # UserDefaults wrapper
│   └── PermissionManager.swift    # ขอ permission ต่างๆ
│
├── Settings/
│   └── SettingsView.swift         # Main settings window
│
└── Resources/
    ├── Assets.xcassets
    └── DockLock.entitlements
```

---

## Feature Spec: Panic Mode

### วิธีทำงาน

กดปุ่ม (Shortcut หรือ Menu Bar) → แอปทุกตัวใน Blocklist ถูก `.hide()` ทันที
กดซ้ำหรือ unlock ด้วย Touch ID → แอปกลับมาแสดงผล

### Implementation

```swift
// PanicModeManager.swift
func triggerPanic() {
    for app in NSWorkspace.shared.runningApplications {
        if blocklist.contains(app.bundleIdentifier ?? "") {
            app.hide()
        }
    }
    isActive = true
}

func releasePanic() {
    // ต้อง verify Touch ID ก่อน
    LocalAuthentication.evaluate(policy: .deviceOwnerAuthenticationWithBiometrics) {
        for app in self.hiddenApps {
            app.unhide()
        }
    }
}
```

### Default Blocklist (แก้ไขได้ใน Settings)

- Terminal, Xcode, VS Code (source code)
- Safari, Chrome (browser tabs)
- Slack, Notion (communication)
- แอปที่ user เพิ่มเองได้

### Keyboard Shortcut

Default: `⌘ + Shift + L`
ตั้งค่าได้เองใน Settings ผ่าน `NSEvent.addGlobalMonitorForEvents`

---

## Feature Spec: Proximity Lock

### วิธีทำงาน

ติดตาม RSSI ของ iPhone/Apple Watch ที่ pair ไว้
ถ้า RSSI ต่ำกว่า threshold ต่อเนื่องนานเกิน N วินาที → Lock screen

### Hysteresis Logic (ป้องกัน false positive)

```
RSSI < -75 dBm  →  เริ่มจับเวลา countdown (default 10 วิ)
RSSI กลับมา    →  reset countdown ทันที
Countdown หมด  →  ส่ง CGSession lock command
```

ทำให้ไม่ lock ตอนก้มหยิบของ หรือสัญญาณกระตุกชั่วคราว

### Bluetooth Pairing Flow

1. User เปิด Settings → Proximity Lock
2. กด "Scan for Devices" → แสดง nearby Bluetooth devices
3. เลือก iPhone หรือ Apple Watch
4. บันทึก Peripheral UUID ใน Keychain

### สิ่งที่ต้องระวัง

- ต้องขอ `NSBluetoothAlwaysUsageDescription` ใน entitlements
- Background scanning ใน macOS ต้องใช้ `CBCentralManagerOptionRestoreIdentifierKey`
- Apple Watch ไม่ expose RSSI โดยตรง ต้องใช้ iPhone เป็น proxy แทน

---

## Settings UI (SwiftUI)

```
Settings Window
├── General
│   ├── Launch at Login (SMAppService)
│   └── Show in Dock / Menu Bar only
│
├── Panic Mode
│   ├── Keyboard Shortcut (custom)
│   ├── App Blocklist (เพิ่ม/ลบแอป)
│   ├── Require Touch ID to release [toggle]
│   └── Preview button
│
└── Proximity Lock
    ├── Enable [toggle]
    ├── Paired Device (scan + select)
    ├── Lock delay: [slider 5-30 วิ]
    ├── Signal threshold: [slider -60 ถึง -90 dBm]
    └── Test mode (แสดง RSSI live)
```

---

## Permissions ที่ต้องขอ

| Permission | ใช้ทำอะไร | เมื่อขอ |
|---|---|---|
| Bluetooth | Proximity Lock | ครั้งแรกที่ enable feature |
| Accessibility | Global keyboard shortcut | ครั้งแรกที่ตั้ง shortcut |
| Face ID/Touch ID | Unlock panic mode | ครั้งแรกที่ใช้งาน |

ไม่ขอ: Camera, Microphone, Location, Network — ทั้งหมดนี้ไม่จำเป็นสำหรับ MVP

---

## Progress

### ✅ Week 1-2: Project setup, Menu Bar skeleton, Settings UI

- [x] Xcode project created (macOS 15+, Swift 6)
- [x] Directory structure: `App/`, `MenuBar/`, `Features/`, `Core/`, `Settings/`, `Resources/`
- [x] `DockLockApp.swift` — `@main` with `@NSApplicationDelegateAdaptor`, `Settings` scene
- [x] `AppDelegate.swift` — hides Dock icon (`.accessory`), boots MenuBar + PanicMode + PermissionManager
- [x] `MenuBarManager.swift` — `NSStatusItem` + `NSPopover`
- [x] `MenuBarView.swift` — popover with Panic toggle, Settings link, Quit
- [x] `SettingsView.swift` — sidebar navigation (General / Panic Mode / Proximity Lock)
- [x] `SettingsStore.swift` — `UserDefaults` wrapper via Combine sink (Swift 6 compatible)
- [x] `PermissionManager.swift` — Accessibility permission request
- [x] `LockEngine.swift` — `CGSession -suspend` lock screen
- [x] `DockLock.entitlements` — Bluetooth entitlement

### ✅ Week 3-4: Panic Mode

- [x] `AppBlocklist.swift` — persisted `Set<String>`, default list (Terminal, Xcode, VSCode, Safari, Chrome, Slack, Notion)
- [x] `PanicModeManager.swift` — hide/unhide via `NSRunningApplication`, Touch ID + password fallback, live shortcut toggle
- [x] `PanicModeView.swift` — settings UI with blocklist editor, running app picker sheet, test button
- [x] Global shortcut `⌘⇧L` via `NSEvent.addGlobalMonitorForEvents` — registered/unregistered live on toggle

### ✅ Week 5-6: Proximity Lock — Bluetooth scan + RSSI monitoring

- [x] `BluetoothMonitor.swift` — scan with `allowDuplicates: true`, RSSI from discovery callback (no connection needed), presence detection via `lastSeenDate` + 3s timer, Keychain persistence, BT state handling
- [x] `LockTrigger.swift` — Combine-based, reacts to `proximityLockEnabled` toggle and `isDeviceVisible` changes, countdown starts on silence, resets on return
- [x] `ProximityView.swift` — BT-off warning, paired device row (in/out of range), scan list with signal strength, tuning sliders, live RSSI badge, countdown display
- [x] `DiscoveredDevice` struct with `signalDescription` (Excellent/Good/Fair/Weak)
- [x] `LockTrigger.shared` booted in `AppDelegate` alongside `PanicModeManager`
- [x] Test on real device — iPhone connects and RSSI updates live ✅

### ✅ Week 7: Polish

- [x] **LockEngine** — fallback to screensaver if CGSession binary missing; uses `isExecutableFile` check
- [x] **PanicModeManager** — hides apps launched *while* panic is active (`didLaunchApplicationNotification`); clears state on screen sleep/wake without unhiding (screen lock makes it irrelevant)
- [x] **BluetoothMonitor** — split `startDiscoveryScan()` (UI, 15 s, resets list) from `startMonitoringScan()` (background, continuous, no list reset); `checkPresence()` skips countdown if device was never seen (startup grace period)
- [x] **LockTrigger** — separate `monitoringCancellables` set prevents subscription leak on toggle; `.dropFirst()` prevents instant countdown on subscribe; `CombineLatest(isDeviceVisible, currentRSSI)` so countdown triggers on weak signal (red RSSI), not just full disappearance
- [x] **PermissionManager** — now `ObservableObject` with `@Published hasAccessibilityPermission`; polls every 1 s after prompt until granted
- [x] **MenuBarManager** — observes `PanicModeManager.$isActive`; icon switches to `lock.shield.fill` during panic; `isTemplate = true` prevents icon disappearing in dark menu bar
- [x] **Panic Mode** — handles full-screen apps via `AXUIElement` (`AXFullScreen = false` before hide); `kCFBooleanFalse` + `CFGetTypeID` type-safe CF casting prevents crash
- [x] **Settings window** — manual `NSWindow` + `NSHostingController` (bypasses `Settings` scene which doesn't activate in `.accessory` mode); `AppDelegate.shared` static ref bypasses `NSApp.delegate` cast failure
- [x] **Accessibility permission** — opens System Settings directly (`x-apple.systempreferences:`) instead of `AXIsProcessTrustedWithOptions`; only prompts on first launch
- [x] **Bluetooth** — removed `CBCentralManagerOptionRestoreIdentifierKey` (iOS-only, caused `.unsupported` on macOS); `NSBluetoothAlwaysUsageDescription` + `CODE_SIGN_ENTITLEMENTS` added to pbxproj
- [x] **Sandbox** — `ENABLE_APP_SANDBOX = NO` (sandbox blocked `Process()` in `LockEngine`, caused exit code 6)
- [x] **Import/Export blocklist** — `NSSavePanel`/`NSOpenPanel` with JSON format; `ENABLE_USER_SELECTED_FILES = readwrite` in pbxproj
- [x] **App version** — `MARKETING_VERSION = 0.1.0`
- [x] **MenuBarView** — proximity status row: shows device name, in/out-of-range, live RSSI, countdown timer in orange
- [x] **SettingsView** — uses `@ObservedObject` for `PermissionManager` so permission badge updates live
- [x] **Panic Mode — full-screen app handling** — black overlay window (`.screenSaver` level, `canJoinAllSpaces + fullScreenAuxiliary`) shown whenever a blocklisted app is frontmost; `hide()` still runs for windowed apps, overlay catches full-screen apps where `hide()` silently fails; monitors `didActivateApplicationNotification` (userInfo app, reliable) + `activeSpaceDidChangeNotification` (0.15s delay fallback)
- [x] **Panic Mode — auth overlay** — overlay shown immediately on `releasePanic()` before Touch ID prompt so blocklisted apps stay hidden during authentication; `isAuthenticating` flag prevents notification handlers from hiding overlay mid-auth; overlay correctly restored or removed after auth success/cancel
- [x] **Proximity Lock — auto Panic Mode** — `LockTrigger` calls `PanicModeManager.shared.triggerPanic()` before `LockEngine.lockScreen()`; apps are hidden before the screen locks so they stay hidden even if user wakes screen without authenticating; Touch ID required to release Panic Mode
- [x] **MenuBarView — UI polish** — extracted body into `header`/`panicButton`/`proximityRow`/`footer` computed vars; tinted button background (`.opacity(0.15)`) instead of `.borderedProminent`; unified padding; footer buttons share modifier stack

### ✅ Tests

Test target `DockLockTests` added — 39 tests, 0 failures.

- [x] `AppBlocklist` — add, remove, dedup, persist to UserDefaults, load defaults (13 tests)
- [x] `SettingsStore` — default value ranges, persistence round-trip (7 tests)
- [x] `DiscoveredDevice` — `signalDescription` thresholds + boundary values, unique `id` per instance (10 tests)
- [x] `LockTrigger` — not counting down initially, no countdown without paired device, disable stops countdown (5 tests)
- [x] `BluetoothMonitor` — initial state, `unpair()` resets all fields, presence timer, no-op scan without paired device (9 tests)

Not unit-testable (requires real device/hardware): BT scanning, `CGSession` lock, Touch ID, `NSRunningApplication.hide()`

### 🔄 Code Optimization (Pre-Release)

Issues found from codebase audit — fix before v0.1.0:

**High Priority**
- [x] `PermissionManager.swift:24-37` — Accessibility permission timer polls every 1s with no timeout; add a max poll count (e.g. 60 attempts) or stop after permission is confirmed
- [x] `BluetoothMonitor.swift:206-228` — Keychain `SecItemAdd`/`SecItemDelete` errors silently ignored; add error logging
- [x] `PermissionManager.swift:18` — Force unwrap `URL(string:)!`; replace with `guard let` + fallback

**Medium Priority**
- [x] `PanicModeManager.swift:10-11` — `hiddenApps` array and `isAuthenticating` mutated without thread synchronization; add `@MainActor` to the class
- [x] `AppDelegate.swift:59` — Settings `NSWindow` never freed after close (`isReleasedWhenClosed = false` + strong ref); nil out `settingsWindow` in `windowWillClose` or set `isReleasedWhenClosed = true`
- [x] `LockEngine.swift:6-10` — Screensaver fallback fires async with no confirmation screen was actually locked
- [x] `BluetoothMonitor.swift:77-84` — `pair()` calls `startMonitoringScan()` without stopping the discovery scan first; call `stopDiscoveryScan()` inside `pair()` before starting monitor scan

**Low Priority**
- [x] `PanicModeManager.swift:21` — `NSScreen.screens[0]` crashes if no screens at blur window lazy init; use `.first` with a safe fallback
- [x] `AppDelegate.swift` — Settings window unresponsive for ~10s on first open; `.accessory` apps never become key by default — fix by switching to `.setActivationPolicy(.regular)` before showing the window and back to `.accessory` on close

---

### 🔄 Apple Quality Standards (Pre-Release)

Issues found from Apple platform audit — fix before v0.1.0:

**P0 — Blocker**
- [x] No `PrivacyInfo.xcprivacy` — required for notarization on macOS 15+ when using Bluetooth + Keychain APIs; add file declaring `NSPrivacyAccessedAPICategoryBluetooth` and `NSPrivacyAccessedAPICategoryKeychain`

**P1 — High**
- [x] `project.pbxproj` — `SWIFT_VERSION = 5.0` but codebase uses Swift 6 features (`@MainActor`, strict concurrency); change to `SWIFT_VERSION = 6.0`
- [x] No privacy policy linked in app or Settings; add a simple privacy policy page and link it in `SettingsView`
- [x] No first-run onboarding; new users see a blank menu bar icon with no guidance — add a one-time welcome/setup flow in `MenuBarView`

**P2 — Medium**
- [x] `project.pbxproj` — `NSHumanReadableCopyright` is empty; set to `© 2026 Pisit Koolplukpol`
- [x] `project.pbxproj` — `MACOSX_DEPLOYMENT_TARGET = 26.3` (pre-release); lowered to `15.0` for broad compatibility
- [x] `AppDelegate.swift:17-19` — Accessibility permission opens System Settings on every launch until granted; gate to first-launch only with a `UserDefaults` flag

**P3 — Low**
- [x] No support/contact URL in app Settings

---

### ✅ UI Polish & Design

- [x] **Popover height** — dynamic height: 220px for welcome view, 130px for main view; auto-resizes when welcome is dismissed via `UserDefaults.didChangeNotification`
- [x] **First-run welcome screen** — `WelcomeView.swift` with 3 live-status setup steps (Accessibility, Bluetooth pair, Blocklist); shows once via `@AppStorage("hasShownWelcome")`
- [x] **Liquid Glass (macOS 26+)** — panic button uses `.glassEffect(.regular.tint(red/green).interactive())` on macOS 26; welcome "Open Settings" uses `.buttonStyle(.glassProminent)`; macOS 15 fallback unchanged; gated with `#available(macOS 26, *)`

---

### 🔄 Week 8-10: Release

**v0.1.0 — Free GitHub Release (no Apple Developer account required)**
- [x] App icon — 1024×1024 PNG added to `Assets.xcassets` AppIcon slot
- [x] `.dmg` packaging — `DockLock-v0.1.0.dmg` created via `hdiutil`
- [x] GitHub repo init (`git init`, `main` branch, `.gitignore`)
- [x] README.md — features, install, architecture, privacy
- [x] README.md — Gatekeeper disclaimer + `xattr -cr` instructions
- [x] MIT License
- [x] Re-archive with icon + focus fix → new `.dmg`
- [ ] Demo GIF (Screen Recording + Gifski)
- [x] v0.1.0 Public Release on GitHub Releases — https://github.com/atomsbaza/DockLock/releases/tag/v0.1.0
- [ ] Post on r/macapps, Hacker News (Show HN)

#### Step-by-step: Export .dmg without paid Apple Developer account

**Step 1 — Sign in with free Apple ID in Xcode**
1. Xcode → Settings (⌘+,) → Accounts tab
2. Click **+** → Apple ID → sign in with your Apple ID (free, no $99 needed)

**Step 2 — Set signing in the project**
1. Click **DockLock** (blue icon) in the left sidebar
2. Under TARGETS → select **DockLock**
3. Click **Signing & Capabilities** tab
4. **Team** dropdown → select your personal Apple ID team
5. Xcode will auto-generate a local signing certificate

**Step 3 — Archive**
1. Top bar: set destination to **Any Mac** (next to the ▶ play button)
2. Menu bar → **Product → Archive**
3. Wait for build to finish — **Organizer** window opens automatically

**Step 4 — Export as .app**
1. In Organizer, select the archive
2. Click **Distribute App**
3. Choose **Custom** → **Copy App** → **Next → Export**
4. Pick a folder → Xcode saves `DockLock.app`

**Step 5 — Package as .dmg**
```bash
hdiutil create -volname "DockLock" \
  -srcfolder /path/to/DockLock.app \
  -ov -format UDZO \
  DockLock-v0.1.0.dmg
```
Replace `/path/to/DockLock.app` with the actual export path from Step 4.

**Step 6 — Create GitHub Release**
1. Go to https://github.com/atomsbaza/DockLock/releases → **Draft a new release**
2. Tag: `v0.1.0` | Title: `DockLock v0.1.0`
3. Upload `DockLock-v0.1.0.dmg`
4. Add release notes (copy from REDDIT_POST.md What It Does section)
5. Click **Publish release**

---

**v0.2.0 — Notarized Release (requires $99/yr Apple Developer Program)**
- [ ] Code signing + notarization
- [ ] Staple notarization ticket to `.dmg`
- [ ] CI with GitHub Actions (build + notarize + release)
- [ ] Homebrew Cask formula (`brew install --cask docklock`)

---

## Timeline (Solo Developer)

```
Week 1-2:  Project setup, Menu Bar skeleton, Settings UI  ✅
Week 3-4:  Panic Mode — hide/unhide + Touch ID release    ✅
Week 5-6:  Proximity Lock — Bluetooth scan + RSSI monitoring    ✅
Week 7:    Hysteresis tuning, edge case fixes, UX polish         ✅
Week 8:    Code signing, notarization, .dmg packaging
Week 9:    GitHub repo cleanup, README ✅ demo GIF
Week 10:   v0.1.0 Public Release
```

**เป้าหมาย:** v0.1.0 ภายใน 2-3 เดือน

---

## Open Source Strategy

### License

**MIT License** — เหมาะสุดสำหรับ security tool ที่อยากให้ community audit โค้ดได้
ไม่ใช้ GPL เพราะอาจจำกัด contributor ในองค์กร

### GitHub Repository Structure

```
github.com/atomsbaza/DockLock/
├── README.md          # Demo GIF + install instructions
├── CONTRIBUTING.md    # How to contribute
├── SECURITY.md        # Responsible disclosure policy
├── LICENSE            # MIT
├── .github/
│   ├── workflows/     # CI: build + test on push
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── PULL_REQUEST_TEMPLATE.md
└── DockLock.xcodeproj
```

### SECURITY.md (สำคัญมากสำหรับ security tool)

ต้องระบุ Responsible Disclosure process ชัดเจน
เช่น email ส่วนตัวสำหรับรายงาน vulnerability แบบ private
ก่อนที่จะ public ทาง GitHub Issues

### Launch Checklist

- [x] App icon designed and added to Xcode
- [x] Re-archive → new `.dmg` (includes icon + settings focus fix)
- [ ] Demo GIF ใน README (ใช้ Screen Recording + Gifski)
- [ ] Homebrew Cask formula (`brew install --cask docklock`)
- [ ] Post บน r/macapps, Hacker News (Show HN)
- [ ] Product Hunt launch
- [ ] macOS dev / security community: Twitter/X, indie.hackers

---

## Phase 2 Preview (หลัง v0.1.0)

### ✅ Done
- **Lock History Log** — records Proximity Lock and Panic Mode events with timestamp
- **Menubar Live Stats** — shows RSSI and countdown next to menu bar icon (toggle in General settings)

### 🔄 To Do

- ✅ **Multi-screen full-screen overlay bug** — fixed. Replaced single `blurOverlayWindow` with `overlayWindows: [CGDirectDisplayID: NSWindow]`. One overlay per screen, covering all displays simultaneously.

- **Intruder Capture** — take a photo when wrong password entered, saved locally
- **Shoulder Surfing Detection** — Core ML + Vision framework
- **iCloud Sync** — sync settings across multiple Macs
- **Notarized release** — code signing + notarization, Homebrew Cask (`brew install --cask docklock`)

---

*Plan version 1.0 — April 2026*
