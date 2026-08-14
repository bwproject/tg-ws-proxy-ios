import Foundation
import Combine

// Central in-app logger. Every runtime message is kept here so the Logs tab
// does not depend on Xcode Console / os.log availability.
enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
    let timestamp: Date
    var count: Int = 1
    var isEssential: Bool = false
}

final class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published private(set) var logs: [LogEntry] = []

    private init() {}

    func addLog(_ message: String, level: LogLevel = .info) {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let entry = LogEntry(
            message: cleaned,
            level: level,
            timestamp: Date(),
            isEssential: level == .error || level == .warn
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Do not hide/rewrite messages: the in-app log must contain the
            // complete runtime output, including repeated statistics lines.
            self.logs.append(entry)
            if self.logs.count > 500 {
                self.logs.removeFirst(self.logs.count - 500)
            }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll()
        }
    }
}
