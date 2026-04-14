import Foundation
import Combine

enum LockTriggerType: String, Codable {
    case proximity
    case panic
}

struct LockEvent: Identifiable, Codable {
    let id: UUID
    let date: Date
    let trigger: LockTriggerType

    init(trigger: LockTriggerType) {
        self.id = UUID()
        self.date = Date()
        self.trigger = trigger
    }
}

class LockHistoryStore: ObservableObject {
    static let shared = LockHistoryStore()

    @Published private(set) var events: [LockEvent] = []

    private let maxEvents = 100
    private let key = "lockHistory"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        load()
    }

    func record(_ trigger: LockTriggerType) {
        let event = LockEvent(trigger: trigger)
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        save()
    }

    func clear() {
        events = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? encoder.encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? decoder.decode([LockEvent].self, from: data) else { return }
        events = saved
    }
}
