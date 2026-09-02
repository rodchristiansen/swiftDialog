//
//  NotifierLog.swift
//  DialogNotifier
//
//  Minimal logging for the notifier helper — no dependency on appvars or appArguments.
//

import Foundation
import OSLog

let notifierLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "au.csiro.dialog.notifier",
    category: "main"
)

var notifierDebugMode = false

struct StandardError: TextOutputStream {
    func write(_ string: String) {
        fputs(string, stderr)
    }
}

func writeLog(_ message: String, logLevel: OSLogType = .info, log: OSLog = notifierLog) {
    os_log("%{public}@", log: log, type: logLevel, message)
    if logLevel == .error || notifierDebugMode {
        var standardError = StandardError()
        print("\(logLevel.stringValue.uppercased()): \(message)", to: &standardError)
    }
    if logLevel != .debug || notifierDebugMode {
        writeManagedLog(message, logLevel: logLevel)
    }
}

extension OSLogType {
    var stringValue: String {
        switch self {
        case .default: return "default"
        case .info:    return "info"
        case .debug:   return "debug"
        case .error:   return "error"
        case .fault:   return "fault"
        default:       return "unknown"
        }
    }
}

// MARK: - Managed log file
//
// Beside the unified log, every record is appended to a file in the
// management-tool logging convention so fleet tooling can collect it:
// "/Library/Managed Notifications/logs/dialog.log" when running with
// administrative rights, "~/Library/Logs/dialog.log" otherwise. Lines are
// "[yyyy-MM-dd HH:mm:ss] LEVEL  message"; the file rolls at 5 MB with five
// generations kept. Debug records reach the file only in verbose or debug
// mode, matching what reaches stderr. A write that fails is ignored.

private let managedLogQueue = DispatchQueue(label: "au.csiro.dialog.notifier.managedlog")
private let managedLogMaxBytes: UInt64 = 5 * 1024 * 1024
private let managedLogGenerations = 5

private let managedLogStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private func managedLogPath() -> String {
    if geteuid() == 0 {
        return "/Library/Managed Notifications/logs/dialog.log"
    }
    return NSHomeDirectory() + "/Library/Logs/dialog.log"
}

private func managedLogLevel(_ type: OSLogType) -> String {
    switch type {
    case .error, .fault: return "ERROR"
    case .debug: return "DEBUG"
    default: return "INFO"
    }
}

func writeManagedLog(_ message: String, logLevel: OSLogType) {
    let level = managedLogLevel(logLevel).padding(toLength: 5, withPad: " ", startingAt: 0)
    let record = "[\(managedLogStamp.string(from: Date()))] \(level) \(message)\n"
    managedLogQueue.async { appendManagedLog(record) }
}

private func rollManagedLog(_ path: String) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let size = attrs[.size] as? UInt64, size >= managedLogMaxBytes else { return }
    let oldest = "\(path).\(managedLogGenerations)"
    if fm.fileExists(atPath: oldest) { try? fm.removeItem(atPath: oldest) }
    for index in stride(from: managedLogGenerations - 1, through: 1, by: -1) {
        let from = "\(path).\(index)", to = "\(path).\(index + 1)"
        if fm.fileExists(atPath: from) { try? fm.moveItem(atPath: from, toPath: to) }
    }
    try? fm.moveItem(atPath: path, toPath: "\(path).1")
}

private func appendManagedLog(_ record: String) {
    let fm = FileManager.default
    let path = managedLogPath()
    let directory = (path as NSString).deletingLastPathComponent
    if !fm.fileExists(atPath: directory) {
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
    }
    rollManagedLog(path)
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    guard let handle = FileHandle(forWritingAtPath: path),
          let data = record.data(using: .utf8) else { return }
    defer { handle.closeFile() }
    handle.seekToEndOfFile()
    handle.write(data)
}
