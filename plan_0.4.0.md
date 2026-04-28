# DockLock v0.4.0 Plan — Multiple Paired Bluetooth Devices

## Goal

Allow users to pair both iPhone **and** Apple Watch (or any two BT devices) simultaneously. The Mac stays unlocked as long as **any** paired device is in range. This closes the current gap where pairing a Watch means losing iPhone proximity lock.

---

## Current Architecture (single-device)

| Location | What it does |
|---|---|
| `BluetoothMonitor.swift` | Stores one `pairedDeviceUUID: UUID?` + `pairedDeviceName: String?` in Keychain under keys `"pairedUUID"` / `"pairedName"`. RSSI loop updates `currentRSSI` and `isDeviceVisible` for that single UUID. |
| `LockTrigger.swift` | Subscribes to `CombineLatest(monitor.$isDeviceVisible, monitor.$currentRSSI)`. Countdown starts when visible=false **or** rssi < threshold. |
| `ProximityView.swift` | Shows one paired device row + one Unpair button. |
| `KeychainHelper` | Generic `save/load/delete(key:)` — already supports arbitrary keys. |

---

## Changes Required

### 1. `BluetoothMonitor.swift` — multi-device state

- Replace `pairedDeviceUUID: UUID?` and `pairedDeviceName: String?` with:
  ```swift
  @Published private(set) var pairedDevices: [PairedDevice] = []
  ```
- Add `struct PairedDevice: Identifiable, Codable, Sendable` with `uuid: UUID`, `name: String`.
- Replace `currentRSSI: Int` and `isDeviceVisible: Bool` with a per-device dictionary:
  ```swift
  @Published private(set) var devicePresence: [UUID: DevicePresence] = [:]
  ```
  where `struct DevicePresence { var rssi: Int; var lastSeen: Date }`.
- Update `pair(device:)` to append (cap at 2 devices, replace if already paired).
- Add `unpair(uuid:)` alongside existing `unpair()` (unpairs all).
- `didDiscover` callback: iterate `pairedDevices`, update `devicePresence` for any match.
- `checkPresence()`: derive a single `isAnyDeviceVisible: Bool` published property — true if **any** paired device was seen within `silenceTimeout`.
- Keychain: store as JSON array under a single key `"pairedDevices"` (JSON-encode `[PairedDevice]`).
- `startMonitoringScan()` guard: `!pairedDevices.isEmpty`.

### 2. `LockTrigger.swift` — aggregate presence

- Subscribe to `monitor.$isAnyDeviceVisible` + a new `monitor.$bestRSSI: Int` (max RSSI across visible paired devices).
- Replace the `CombineLatest(isDeviceVisible, currentRSSI)` pipeline with `CombineLatest(isAnyDeviceVisible, bestRSSI)` — countdown/reset logic is otherwise identical.

### 3. `ProximityView.swift` — multi-device UI

- Replace the single paired-device row with a `ForEach(monitor.pairedDevices)` list showing each device's name, live RSSI, and an individual Unpair button.
- Show "Add device" / "Scan" button when fewer than 2 devices are paired.
- Display per-device signal strength badge (Excellent / Good / Fair / Weak).
- Disable "Add device" when 2 devices are already paired (show "Max 2 devices" hint).

### 4. `SettingsStore.swift` — no changes needed

Presence logic stays in `BluetoothMonitor`; `SettingsStore` thresholds/delays are device-agnostic.

### 5. `MenuBarManager.swift` / Live Stats — minor update

`currentRSSI` reference → `monitor.bestRSSI` (show strongest signal in menu bar).

### 6. Tests — `BluetoothMonitorTests.swift`

- Update pairing tests for multi-device: pair two devices, unpair one, verify the other persists.
- Add presence tests: one device absent + one present → `isAnyDeviceVisible = true`.
- Add cap test: pairing a third device replaces the second (or oldest).

---

## Sequence / Order of Work

1. `BluetoothMonitor` — data model + Keychain persistence
2. `BluetoothMonitor` — `didDiscover` + `checkPresence` for multi-device
3. `LockTrigger` — switch to `isAnyDeviceVisible` + `bestRSSI`
4. `ProximityView` — multi-device list UI
5. `MenuBarManager` — `bestRSSI` for live stats
6. Tests

---

## Out of Scope for v0.4.0

- More than 2 paired devices (UX complexity, diminishing returns)
- Per-device RSSI thresholds (single global threshold is sufficient)
- Custom App Modes (deferred to v0.5.0)
