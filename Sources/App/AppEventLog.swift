import Foundation

/// Keeps one lightweight, user-readable log for the current app run.
/// The next cold launch replaces it so diagnostics never accumulate indefinitely.
enum AppEventLog {
    private static let filename = "LowPolyCam-Session.log"
    private static let queue = DispatchQueue(label: "com.swazi.lowpolycam.eventLog", qos: .utility)
    private static let timestampFormatter = ISO8601DateFormatter()
    private static var handle: FileHandle?
    private static var hasStartedSession = false

    static func beginNewSession() {
        // File I/O must never delay the first camera frame. The serial queue also preserves
        // event order: the reset always finishes before the first appended event.
        queue.async {
            beginNewSessionLocked()
        }
    }

    static func event(_ message: String) {
        queue.async {
            beginNewSessionLocked()
            appendLocked(message)
        }
    }

    static func flush() {
        queue.async {
            beginNewSessionLocked()
            try? handle?.synchronize()
        }
    }

    private static func beginNewSessionLocked() {
        guard !hasStartedSession else { return }
        hasStartedSession = true

        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent(filename)

        try? handle?.close()
        handle = nil
        try? manager.removeItem(at: url)
        guard manager.createFile(atPath: url.path, contents: nil) else {
            NSLog("LowPolyCam could not create its session log.")
            return
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            NSLog("LowPolyCam could not open its session log: %@", error.localizedDescription)
        }
        appendLocked("LowPolyCam session started")
    }

    private static func appendLocked(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle?.write(data)
    }
}
