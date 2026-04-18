import Foundation
import Combine

enum LockTriggerType: String, Codable {
    case proximity
    case panic
    case intruderCapture
}

struct LockEvent: Identifiable, Codable {
    let id: UUID
    let date: Date
    let trigger: LockTriggerType
    /// Filename (not full path) of the captured photo in the Captures directory.
    /// Non-nil only for `.intruderCapture` events where the camera was available.
    var photoFilename: String?

    init(trigger: LockTriggerType, photoFilename: String? = nil) {
        self.id = UUID()
        self.date = Date()
        self.trigger = trigger
        self.photoFilename = photoFilename
    }
}

class LockHistoryStore: ObservableObject {
    static let shared = LockHistoryStore()

    @Published private(set) var events: [LockEvent] = []

    private let maxEvents = 100
    private let key = "lockHistory"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Directory where captured intruder photos are stored.
    static var capturesDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("DockLock Captures", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: Self.capturesDirectory,
                                                  withIntermediateDirectories: true)
        load()
    }

    func record(_ trigger: LockTriggerType, photoFilename: String? = nil) {
        let event = LockEvent(trigger: trigger, photoFilename: photoFilename)
        events.insert(event, at: 0)
        if events.count > maxEvents {
            // Delete photo files for events that are being trimmed
            events[maxEvents...].forEach { deletePhoto(for: $0) }
            events = Array(events.prefix(maxEvents))
        }
        save()
    }

    func clear() {
        events.forEach { deletePhoto(for: $0) }
        events = []
        UserDefaults.standard.removeObject(forKey: key)
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    // MARK: - Photo helpers

    func photoURL(for event: LockEvent) -> URL? {
        guard let filename = event.photoFilename else { return nil }
        return Self.capturesDirectory.appendingPathComponent(filename)
    }

    private func deletePhoto(for event: LockEvent) {
        guard let url = photoURL(for: event) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - iCloud Sync

    func syncFromCloud(_ store: NSUbiquitousKeyValueStore) {
        guard let data = store.data(forKey: key),
              let cloudEvents = try? decoder.decode([LockEvent].self, from: data),
              !cloudEvents.isEmpty else { return }
        let merged = Dictionary(uniqueKeysWithValues: (events + cloudEvents).map { ($0.id, $0) })
        events = merged.values.sorted { $0.date > $1.date }
        if events.count > maxEvents { events = Array(events.prefix(maxEvents)) }
        save()
    }

    func applyCloudUpdate(_ store: NSUbiquitousKeyValueStore) {
        syncFromCloud(store)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? encoder.encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
        // Exclude intruderCapture events from iCloud — they contain security incident timestamps
        let cloudEvents = events.filter { $0.trigger != .intruderCapture }
        if let cloudData = try? encoder.encode(cloudEvents) {
            NSUbiquitousKeyValueStore.default.set(cloudData, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? decoder.decode([LockEvent].self, from: data) else { return }
        events = saved
    }
}
