//
//  LogSessionStore.swift
//  Managed Notifications Dialog
//
//  Lists dialog's logs from two roots. dialog writes one log per day: as root
//  at /Library/Managed Notifications/logs/YYYY-MM-DD/dialog.log, and as a user
//  at ~/Library/Logs/Managed Notifications/YYYY-MM-DD/dialog.log, each rolled at
//  5 MB into dialog.log.1 … dialog.log.5 beside it with events.jsonl. The flat
//  ~/Library/Logs/dialog.log earlier builds wrote is listed too while it exists.
//

import Foundation

/// Which root a log came from.
enum LogSource: String, CaseIterable, Sendable {
    case system
    case user

    var label: String {
        switch self {
        case .system: "System (root)"
        case .user: "This user"
        }
    }
}

struct LogSession: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let date: Date?
    let size: Int64
    var source: LogSource = .system

    var displayDate: String {
        guard let date else { return name }
        return LogSessionStore.displayDateFormatter.string(from: date)
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum LogSessionStore {
    static let logFileName = "dialog.log"

    static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseDay(_ stamp: String) -> Date? {
        dayFormatter.date(from: stamp)
    }

    /// Root's logs from `system` and this user's from `user`, each labelled with
    /// its source, newest first, then the flat `legacyUserLog` if it exists.
    static func sessions(system: String, user: String, legacyUserLog: String? = nil,
                         fileManager fm: FileManager = .default) -> [LogSession] {
        var found = sessions(in: system, source: .system, fileManager: fm)
            + sessions(in: user, source: .user, fileManager: fm)
        found.sort {
            let lhs = $0.date ?? .distantPast
            let rhs = $1.date ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        if let legacyUserLog, fm.fileExists(atPath: legacyUserLog) {
            let modified = (try? fm.attributesOfItem(atPath: legacyUserLog))?[.modificationDate] as? Date
            found.append(LogSession(id: "user:" + legacyUserLog, name: "dialog.log (earlier builds)",
                                    path: legacyUserLog, date: modified, size: fileSize(legacyUserLog, fm),
                                    source: .user))
        }
        return found
    }

    /// Every log under `root`, newest first.
    static func sessions(in root: String, source: LogSource = .system,
                         fileManager fm: FileManager = .default) -> [LogSession] {
        var found: [LogSession] = []
        if let entries = try? fm.contentsOfDirectory(atPath: root) {
            for day in entries {
                guard let date = parseDay(day) else { continue }
                let dayPath = (root as NSString).appendingPathComponent(day)
                guard let files = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
                // dialog.log first, then its rolled generations, oldest last.
                let logs = files
                    .filter { $0 == logFileName || generation(of: $0) != nil }
                    .sorted { (generation(of: $0) ?? 0) < (generation(of: $1) ?? 0) }
                for log in logs {
                    let path = (dayPath as NSString).appendingPathComponent(log)
                    found.append(LogSession(
                        id: "\(source.rawValue):\(day)/\(log)",
                        name: log == logFileName ? day : "\(day) (\(log))",
                        path: path,
                        date: date,
                        size: fileSize(path, fm),
                        source: source
                    ))
                }
            }
        }
        found.sort {
            let lhs = $0.date ?? .distantPast
            let rhs = $1.date ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        return found
    }

    /// 1 … 5 for dialog.log.1 … dialog.log.5, nil for anything else.
    static func generation(of name: String) -> Int? {
        guard name.hasPrefix(logFileName + ".") else { return nil }
        return Int(name.dropFirst(logFileName.count + 1))
    }

    private static func fileSize(_ path: String, _ fm: FileManager) -> Int64 {
        ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
