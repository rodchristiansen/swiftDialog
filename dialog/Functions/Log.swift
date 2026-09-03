//
//  Logs.swift
//  Dialog
//
//  Created by Bart E Reardon on 3/8/2023.
//

import Foundation
import OSLog

func writeLog(_ message: String, logLevel: OSLogType = .info, log: OSLog = osLog) {
    let logMessage = "\(message)"
    var standardError = StandardError()

    os_log("%{public}@", log: log, type: logLevel, logMessage)
    let chatty = appvars.debugMode || appArguments.verboseLogging.present
    if logLevel == .error || chatty {
        // print debug and error to sterr
        print("\(logLevel.stringValue.uppercased()): \(message)", to: &standardError)
    }
    if logLevel != .debug || chatty {
        writeManagedLog(logMessage, logLevel: logLevel)
    }
}

func printStdErr(_ errorMessage: String) {
    var standardError = StandardError()
    print(errorMessage, to: &standardError)
}

func checkFileExists(path: String) -> Bool {
    return FileManager.default.fileExists(atPath: path)
}

extension OSLogType {
    var stringValue: String {
        switch self {
        case .default: return "default"
        case .info: return "info"
        case .debug: return "debug"
        case .error: return "error"
        case .fault: return "fault"
        default: return "unknown"
        }
    }
}


// MARK: - Managed log file
//
// Beside the unified log, every record is appended to a file in the
// management-tool logging convention so fleet tooling can collect it:
// "/Library/Managed Notifications/logs/<yyyy-MM-dd>/dialog.log" whenever that shared
// directory is writable by this process. The installer creates it root:wheel
// mode 1777 (world-writable, sticky) so root and user contexts append to the
// same file, and a root-context run creates it that way if it is missing.
// When the directory is absent or not writable, or the file cannot be opened,
// records go to "~/Library/Logs/dialog.log" instead. Lines are
// "[yyyy-MM-dd HH:mm:ss] LEVEL  message"; the file rolls at 5 MB with five
// generations kept, rotated only by the file's owner or root. The file is
// opened with O_NOFOLLOW and must be a single-linked regular file, so a
// planted symlink or hard link in the shared directory is never written
// through; files are created mode 0666. Debug records reach the file only in
// verbose or debug mode, matching what reaches stderr. A write that fails is
// ignored.

private let managedLogQueue = DispatchQueue(label: "au.csiro.dialog.managedlog")
private let managedLogMaxBytes: off_t = 5 * 1024 * 1024
private let managedLogGenerations = 5
private let managedLogSharedDirectory = "/Library/Managed Notifications/logs"
/// The day directory is this tool's session: a dialog is shown far too often to
/// justify a directory per invocation, so records land in
/// <shared>/<yyyy-MM-dd>/dialog.log with events.jsonl beside them.
private let managedLogEventsFileName = "events.jsonl"
private let managedLogRetentionDays = 30
private let managedLogInvocation = UUID().uuidString
private var managedLogPruned = false // only touched on managedLogQueue
private let managedLogUserPath = NSHomeDirectory() + "/Library/Logs/dialog.log"
private let managedLogSharedDirectoryMode: mode_t = 0o1777
private let managedLogFileMode: mode_t = 0o666
private var managedLogFellBack = false // only touched on managedLogQueue

private let managedLogStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private let managedLogDayStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let managedLogEventStamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// The log for `date`, day-nested inside the shared root. Resolved per record so
/// a dialog left open across midnight rolls onto the new day directory.
private func managedLogSharedPath(_ date: Date) -> String {
    return managedLogSharedDirectory + "/" + managedLogDayStamp.string(from: date) + "/dialog.log"
}

/// Creates a day directory inside the shared root world-writable and sticky like
/// the root itself, by whichever context gets there first, so every context can
/// write its own records into it.
private func ensureManagedLogDayDirectory(_ path: String) {
    var info = stat()
    if stat(path, &info) == 0 {
        if (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o7777) != managedLogSharedDirectoryMode,
           info.st_uid == geteuid() {
            chmod(path, managedLogSharedDirectoryMode)
        }
        return
    }
    if mkdir(path, managedLogSharedDirectoryMode) == 0 {
        chmod(path, managedLogSharedDirectoryMode)
        if managedLogIsRoot() { chown(path, 0, 0) }
    }
}

/// Removes day directories past the retention window, once per process.
/// Best-effort: another context's directory is not this process's to remove.
private func pruneManagedLogDays(now: Date = Date()) {
    guard !managedLogPruned else { return }
    managedLogPruned = true
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: managedLogSharedDirectory),
          let cutoff = Calendar.current.date(byAdding: .day, value: -managedLogRetentionDays, to: now) else { return }
    for entry in entries {
        guard let day = managedLogDayStamp.date(from: entry), day < cutoff else { continue }
        let full = managedLogSharedDirectory + "/" + entry
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
        try? fm.removeItem(atPath: full)
    }
}

/// One events.jsonl record: the same entry, structured. Several tools share a
/// day directory, so each record names its tool, process and invocation.
private func managedLogEvent(_ message: String, level: String, date: Date) -> String {
    let record: [String: String] = [
        "timestamp": managedLogEventStamp.string(from: date),
        "level": level,
        "event_type": level == "ERROR" ? "error" : "message",
        "tool": "dialog",
        "pid": String(getpid()),
        "invocation_id": managedLogInvocation,
        "message": message
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return "" }
    return line + "\n"
}

private func managedLogIsRoot() -> Bool {
    return geteuid() == 0
}

/// Creates the shared directory root:wheel mode 1777 when missing, and
/// restores that mode if it drifted. Root only; a no-op otherwise.
private func ensureManagedLogSharedDirectory() {
    guard managedLogIsRoot() else { return }
    var info = stat()
    if stat(managedLogSharedDirectory, &info) == 0 {
        if (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o7777) != managedLogSharedDirectoryMode {
            chmod(managedLogSharedDirectory, managedLogSharedDirectoryMode)
        }
        return
    }
    let parent = (managedLogSharedDirectory as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o755])
    if mkdir(managedLogSharedDirectory, managedLogSharedDirectoryMode) == 0 {
        chown(managedLogSharedDirectory, 0, 0)
        chmod(managedLogSharedDirectory, managedLogSharedDirectoryMode)
    }
}

private func managedLogSharedDirectoryIsWritable() -> Bool {
    ensureManagedLogSharedDirectory()
    var info = stat()
    guard stat(managedLogSharedDirectory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    return access(managedLogSharedDirectory, W_OK | X_OK) == 0
}

private func managedLogLevel(_ type: OSLogType) -> String {
    switch type {
    case .error, .fault: return "ERROR"
    case .debug: return "DEBUG"
    default: return "INFO"
    }
}

func writeManagedLog(_ message: String, logLevel: OSLogType) {
    let now = Date()
    let name = managedLogLevel(logLevel)
    let level = name.padding(toLength: 5, withPad: " ", startingAt: 0)
    let record = "[\(managedLogStamp.string(from: now))] \(level) \(message)\n"
    let event = managedLogEvent(message, level: name, date: now)
    managedLogQueue.async { appendManagedLog(record, event: event, date: now) }
}

/// Opens `path` for appending without following a symlink, refuses anything
/// that is not a regular file with one link, and widens a file this process
/// owns to mode 0666 so other contexts can append too.
private func openManagedLog(_ path: String) -> Int32? {
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, managedLogFileMode)
    guard descriptor >= 0 else { return nil }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
        close(descriptor)
        return nil
    }
    if info.st_uid == geteuid(), (info.st_mode & 0o777) != managedLogFileMode {
        fchmod(descriptor, managedLogFileMode)
    }
    return descriptor
}

/// Rolls the generations when the open file has reached the limit and this
/// process may rename it. Returns true when a roll happened.
private func rollManagedLog(_ path: String, _ descriptor: Int32) -> Bool {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_size >= managedLogMaxBytes,
          managedLogIsRoot() || info.st_uid == geteuid() else { return false }
    let fm = FileManager.default
    let oldest = "\(path).\(managedLogGenerations)"
    if fm.fileExists(atPath: oldest) { try? fm.removeItem(atPath: oldest) }
    for index in stride(from: managedLogGenerations - 1, through: 1, by: -1) {
        let from = "\(path).\(index)", to = "\(path).\(index + 1)"
        if fm.fileExists(atPath: from) { try? fm.moveItem(atPath: from, toPath: to) }
    }
    try? fm.moveItem(atPath: path, toPath: "\(path).1")
    return true
}

private func appendManagedLog(_ record: String, to path: String) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    if (directory as NSString).deletingLastPathComponent == managedLogSharedDirectory {
        ensureManagedLogDayDirectory(directory)
        pruneManagedLogDays()
    } else if directory != managedLogSharedDirectory, !FileManager.default.fileExists(atPath: directory) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
    }
    guard var descriptor = openManagedLog(path) else { return false }
    if rollManagedLog(path, descriptor) {
        close(descriptor)
        guard let reopened = openManagedLog(path) else { return false }
        descriptor = reopened
    }
    defer { close(descriptor) }
    guard let data = record.data(using: .utf8) else { return true }
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
    return true
}

private func appendManagedLog(_ record: String, event: String, date: Date) {
    if !managedLogFellBack, managedLogSharedDirectoryIsWritable() {
        let path = managedLogSharedPath(date)
        if appendManagedLog(record, to: path) {
            let events = (path as NSString).deletingLastPathComponent + "/" + managedLogEventsFileName
            if !event.isEmpty { _ = appendManagedLog(event, to: events) }
            return
        }
    }
    managedLogFellBack = true
    _ = appendManagedLog(record, to: managedLogUserPath)
}
