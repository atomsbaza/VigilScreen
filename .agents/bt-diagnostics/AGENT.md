# bt-diagnostics

Diagnose Proximity Lock / Bluetooth issues by reading live system state and cross-checking against the source code configuration. Runs fully automatically. Use when the paired device isn't detected, triggers fire too early/late, or BT state is stuck.

## Diagnostic steps

### 1. Keychain — paired device

```bash
security find-generic-password -a pairedUUID -w 2>&1
security find-generic-password -a pairedName -w 2>&1
```

Report: paired UUID and name, or "no device paired" if not found.

### 2. Bluetooth system state

```bash
system_profiler SPBluetoothDataType 2>&1 | head -40
```

Look for:
- Bluetooth powered on/off
- Whether the paired device (by name) appears in the device list
- Paired device's connection state

### 3. Process check — is VigilScreen running?

```bash
pgrep -l "Vigil Screen" || echo "Not running"
```

If not running, note that RSSI readings and presence timer are inactive.

### 4. Source configuration summary

Read `VigilScreen/Features/ProximityLock/BluetoothMonitor.swift` and report the current hardcoded thresholds:

- `silenceTimeout` — seconds of BLE silence before declaring device absent (currently 8s)
- Presence timer interval (currently 3s)
- Discovery scan duration (currently 15s)
- RSSI filter: RSSI == 127 is ignored (unreadable)

Read `VigilScreen/Features/ProximityLock/LockTrigger.swift` and report:
- Lock trigger threshold (RSSI level or absence duration that fires Panic Mode)
- Hysteresis/debounce settings

### 5. Common failure patterns

Cross-check the live state against known failure modes:

| Symptom | Likely cause | Where to look |
|---|---|---|
| Device never detected | BT off, or device UUID mismatch in Keychain | Step 1 + 2 |
| False triggers (locks too soon) | `silenceTimeout` too short for device's advert interval | `BluetoothMonitor.swift:silenceTimeout` |
| Never triggers even when out of range | Lock threshold RSSI too low, or hysteresis too long | `LockTrigger.swift` |
| BT state stuck `.unknown` | `CBCentralManager` initialized on wrong queue | `BluetoothMonitor.init()` |
| App not scanning after relaunch | Monitoring scan not restarted on `centralManagerDidUpdateState` | `BluetoothMonitor.centralManagerDidUpdateState` |

### 6. Permissions check

```bash
tccutil reset Bluetooth com.pisit.koolplukpol.VigilScreen 2>&1 || true
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service,client,auth_value FROM access WHERE client='com.pisit.koolplukpol.VigilScreen';" 2>/dev/null \
  || echo "TCC DB not readable (expected without root)"
```

Note: TCC DB requires root. If not readable, tell the user to check System Settings → Privacy & Security → Bluetooth manually.

## Output format

```
── BT Diagnostics ────────────────────────────────
  Paired device   {name} ({uuid})  |  Not paired
  BT system       Powered On / Off / Unavailable
  Device visible  Yes (in system_profiler)  |  No
  App running     Yes (PID {n})  |  No

  Config (from source)
    silenceTimeout   8s
    presenceInterval 3s
    discoveryScan    15s

  LockTrigger
    {threshold config}

  Findings
    ✅ / ⚠️ / ❌ {finding}
──────────────────────────────────────────────────
```

End with a plain-English summary of the most likely cause if any issue is found.
