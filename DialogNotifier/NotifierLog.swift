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

private let managedLogQueue = DispatchQueue(label: "au.csiro.dialog.notifier.managedlog")
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

/// True when `path` is a real directory, not a symlink, owned by root or by
/// this process.
func managedLogDirectoryIsTrusted(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    return info.st_uid == 0 || info.st_uid == geteuid()
}

/// Creates a day directory inside the shared root world-writable and sticky like
/// the root itself, by whichever context gets there first, so every context can
/// write its own records into it. An existing entry is never followed or
/// re-moded; it is used only when it is a trusted directory. Root sets aside
/// anything else under the day's name and makes its own, so root records stay
/// in the collected location.
func ensureManagedLogDayDirectory(_ path: String) -> Bool {
    var info = stat()
    if lstat(path, &info) == 0 {
        if managedLogDirectoryIsTrusted(path) { return true }
        guard managedLogIsRoot(), setAsideManagedLogEntry(path) else { return false }
    }
    guard mkdir(path, managedLogSharedDirectoryMode) == 0 else { return false }
    // The sticky root stops other accounts renaming what this process just made.
    chmod(path, managedLogSharedDirectoryMode)
    if managedLogIsRoot() { chown(path, 0, 0) }
    return true
}

/// Renames `path` to a hidden name beside it. rename never follows a link, and
/// root may rename any entry in a root-owned parent. Only done when the parent
/// is a real directory owned by root.
func setAsideManagedLogEntry(_ path: String, now: Date = Date()) -> Bool {
    let parent = (path as NSString).deletingLastPathComponent
    var info = stat()
    guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0 else { return false }
    let name = managedLogUntrustedName(day: (path as NSString).lastPathComponent, pid: getpid(), now: now)
    return rename(path, (parent as NSString).appendingPathComponent(name)) == 0
}

let managedLogUntrustedPrefix = ".untrusted-"

/// The hidden name an entry set aside by `setAsideManagedLogEntry` gets.
func managedLogUntrustedName(day: String, pid: Int32, now: Date) -> String {
    return "\(managedLogUntrustedPrefix)\(day)-\(pid)-\(Int(now.timeIntervalSince1970))"
}

/// When an entry named by `managedLogUntrustedName` was set aside, or nil for any other name.
func managedLogUntrustedDate(_ name: String) -> Date? {
    guard name.hasPrefix(managedLogUntrustedPrefix), let last = name.split(separator: "-").last,
          let epoch = Int(last) else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(epoch))
}

/// Names in the directory open at `fd`, without "." and "..".
func managedLogEntryNames(_ fd: Int32) -> [String] {
    let copy = dup(fd)
    guard copy >= 0 else { return [] }
    guard let dir = fdopendir(copy) else { close(copy); return [] }
    defer { closedir(dir) }
    rewinddir(dir)
    var names: [String] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

private func managedLogEntryIsDirectory(_ name: String, in fd: Int32) -> Bool {
    var info = stat()
    return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
}

/// Removes `name` from the directory open at `parent` without following a
/// link. A link or file is unlinked. A directory is opened with O_NOFOLLOW,
/// its files and links unlinked, and it is removed only once it is empty; a
/// folder nested inside it is left in place.
private func removeManagedLogEntry(_ name: String, in parent: Int32) {
    var info = stat()
    guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { unlinkat(parent, name, 0); return }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { return }
    for child in managedLogEntryNames(fd) where !managedLogEntryIsDirectory(child, in: fd) {
        unlinkat(fd, child, 0)
    }
    close(fd)
    unlinkat(parent, name, AT_REMOVEDIR)
}

/// Removes day directories past the retention window, once per process.
private func pruneManagedLogDays(now: Date = Date()) {
    guard !managedLogPruned else { return }
    managedLogPruned = true
    pruneManagedLogEntries(in: managedLogSharedDirectory, now: now)
}

/// Removes day directories, and entries set aside by root, past the retention
/// window. Best-effort: another context's directory is not this process's to
/// remove.
func pruneManagedLogEntries(in directory: String, now: Date) {
    guard let cutoff = Calendar.current.date(byAdding: .day, value: -managedLogRetentionDays, to: now) else { return }
    let root = open(directory, O_RDONLY | O_DIRECTORY)
    guard root >= 0 else { return }
    defer { close(root) }
    for entry in managedLogEntryNames(root) {
        if let setAsideAt = managedLogUntrustedDate(entry) {
            if setAsideAt < cutoff { removeManagedLogEntry(entry, in: root) }
            continue
        }
        guard let day = managedLogDayStamp.date(from: entry), day < cutoff else { continue }
        guard managedLogDirectoryIsTrusted(directory + "/" + entry) else { continue }
        removeManagedLogEntry(entry, in: root)
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
/// restores that mode if it drifted on a root-owned directory. Root only; a
/// no-op otherwise.
private func ensureManagedLogSharedDirectory() {
    guard managedLogIsRoot() else { return }
    var info = stat()
    if lstat(managedLogSharedDirectory, &info) == 0 {
        if (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0,
           (info.st_mode & 0o7777) != managedLogSharedDirectoryMode {
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
    guard lstat(managedLogSharedDirectory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == 0 else { return false }
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
    // unlink and rename never follow a link, and unlink refuses a directory.
    unlink("\(path).\(managedLogGenerations)")
    for index in stride(from: managedLogGenerations - 1, through: 1, by: -1) {
        rename("\(path).\(index)", "\(path).\(index + 1)")
    }
    rename(path, "\(path).1")
    return true
}

private func appendManagedLog(_ record: String, to path: String) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    if (directory as NSString).deletingLastPathComponent == managedLogSharedDirectory {
        guard ensureManagedLogDayDirectory(directory) else { return false }
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
