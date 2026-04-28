import Foundation

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var events: [LogEvent] = []

    private let maxEvents: Int

    init(maxEvents: Int = 20_000) {
        self.maxEvents = maxEvents
    }

    func append(_ event: LogEvent) {
        events.append(event)
        trimIfNeeded()
    }

    func append(source: LogSource, level: LogLevel? = nil, _ message: String) {
        append(LogEvent(source: source, level: level, message: message))
    }

    func clear() {
        events.removeAll(keepingCapacity: true)
    }

    private func trimIfNeeded() {
        guard events.count > maxEvents else { return }
        events.removeFirst(events.count - maxEvents)
    }
}
