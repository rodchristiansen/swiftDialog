//
//  LogSessionStore.swift
//  Managed Notifications Dialog
//
//  Lists dialog's logs. dialog writes one log per day, shared by every user and
//  root, at /Library/Managed Notifications/logs/YYYY-MM-DD/dialog.log, rolled
//  at 5 MB into dialog.log.1 … dialog.log.5 beside it with events.jsonl. When
//  that folder is unavailable it writes ~/Library/Logs/dialog.log instead, which
//  is listed too.
//

import Foundation

struct LogSession: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let date: Date?
    let size: Int64

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

    /// Every log under `root`, newest first, then `userLog` if it exists.
    static func sessions(in root: String, userLog: String? = nil, fileManager fm: FileManager = .default) -> [LogSession] {
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
                        id: "\(day)/\(log)",
                        name: log == logFileName ? day : "\(day) (\(log))",
                        path: path,
                        date: date,
                        size: fileSize(path, fm)
                    ))
                }
            }
        }
        found.sort {
            let lhs = $0.date ?? .distantPast
            let rhs = $1.date ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }

        if let userLog, fm.fileExists(atPath: userLog) {
            let modified = (try? fm.attributesOfItem(atPath: userLog))?[.modificationDate] as? Date
            found.append(LogSession(id: userLog, name: "Your log (~/Library/Logs)", path: userLog,
                                    date: modified, size: fileSize(userLog, fm)))
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
