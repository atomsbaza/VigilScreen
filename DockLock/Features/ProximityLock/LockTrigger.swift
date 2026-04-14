import Foundation
import Combine

class LockTrigger: ObservableObject {
    static let shared = LockTrigger()

    @Published private(set) var isCountingDown = false
    @Published private(set) var secondsRemaining: Int = 0

    private var countdownTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Separate set so monitoring subscriptions are cleanly replaced on toggle.
    private var monitoringCancellables = Set<AnyCancellable>()

    private let settings = SettingsStore.shared
    private let monitor = BluetoothMonitor.shared

    private init() {
        settings.$proximityLockEnabled
            .sink { [weak self] (enabled: Bool) in
                if enabled { self?.startMonitoring() } else { self?.stopMonitoring() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Cancel any previous monitoring subscriptions before re-subscribing
        monitoringCancellables.removeAll()

        monitor.startMonitoringScan()
        monitor.startPresenceTimer()

        // Combine visibility AND RSSI — countdown starts when either:
        // 1. Device stops advertising (isDeviceVisible = false), or
        // 2. Device is visible but RSSI is below the threshold (too far)
        Publishers.CombineLatest(monitor.$isDeviceVisible, monitor.$currentRSSI)
            .dropFirst() // skip initial emission at subscription time
            .sink { [weak self] (visible, rssi) in
                guard let self, self.settings.proximityLockEnabled,
                      self.monitor.pairedDeviceUUID != nil else { return }
                let threshold = Int(self.settings.proximityRSSIThreshold)
                let inRange = visible && rssi != 0 && rssi >= threshold
                if inRange {
                    self.resetCountdown()
                } else {
                    self.startCountdownIfNeeded()
                }
            }
            .store(in: &monitoringCancellables)
    }

    private func stopMonitoring() {
        monitoringCancellables.removeAll()
        resetCountdown()
        monitor.stopPresenceTimer()
    }

    // MARK: - Countdown

    private func startCountdownIfNeeded() {
        guard !isCountingDown else { return }
        isCountingDown = true
        secondsRemaining = Int(settings.proximityLockDelay)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.secondsRemaining -= 1
            if self.secondsRemaining <= 0 {
                self.resetCountdown()
                LockHistoryStore.shared.record(.proximity)
                // Trigger Panic Mode first so sensitive apps are hidden even if
                // the user wakes the screen without authenticating.
                PanicModeManager.shared.triggerPanic()
                LockEngine.lockScreen()
            }
        }
    }

    private func resetCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountingDown = false
        secondsRemaining = 0
    }
}
