import Foundation

struct LogEntry: Sendable {
    let timestamp: Date
    let message: String
}

final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maxEntries = 2000

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    func log(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        // Continue printing to console for Xcode debugging
        print(message)
    }

    func allEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func formattedLog() -> String {
        let entriesCopy = allEntries()
        return entriesCopy.map { entry in
            let timestamp = dateFormatter.string(from: entry.timestamp)
            return "[\(timestamp)] \(entry.message)"
        }.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

func debugLog(_ message: String) {
    DebugLog.shared.log(message)
}
