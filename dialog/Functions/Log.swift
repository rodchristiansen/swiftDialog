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
// management-tool logging convention so fleet tooling can collect it. Logs are
// split by context, and nothing either context writes is writable by another
// account:
//
// - A root process writes "/Library/Managed Notifications/logs/<yyyy-MM-dd>/dialog.log".
//   That folder is root's alone: root:wheel 0755, files 0644. It is opened one
//   component at a time without following a symlink, and every folder above
//   "Managed Notifications" must be root-owned and writable by no group or
//   other, or root refuses it and logs in its own home instead. Once per root
//   process, anything an earlier world-writable (1777/0666) layout left inside
//   it is reset to root's, and a symlink or hard link there is removed.
// - Any other process (dialog launched as the signed-in user, which is how the
//   dialog command shows it) writes "~/Library/Logs/Managed Notifications/<yyyy-MM-dd>/dialog.log"
//   in its own home, in the same layout, and never touches the root folder.
//
// Lines are "[yyyy-MM-dd HH:mm:ss] LEVEL  message", with events.jsonl beside
// them; the file rolls at 5 MB with five generations kept. The file is opened
// with O_NOFOLLOW and must be a single-linked regular file. Debug records reach
// the file only in verbose or debug mode, matching what reaches stderr. A write
// that fails is ignored.

private let managedLogQueue = DispatchQueue(label: "au.csiro.dialog.managedlog")
private let managedLogMaxBytes: off_t = 5 * 1024 * 1024
private let managedLogGenerations = 5
let managedLogRootDirectory = "/Library/Managed Notifications/logs"
/// Trailing components of `managedLogRootDirectory` this tool owns and locks:
/// "Managed Notifications" and "logs". Everything above must already be root-only.
let managedLogOwnedComponents = 2
let managedLogUserSubpath = "Library/Logs/Managed Notifications"
/// The day directory is this tool's session: a dialog is shown far too often to
/// justify a directory per invocation, so records land in
/// <log root>/<yyyy-MM-dd>/dialog.log with events.jsonl beside them.
private let managedLogEventsFileName = "events.jsonl"
private let managedLogRetentionDays = 30
private let managedLogInvocation = UUID().uuidString
private var managedLogPruned: Set<String> = [] // only touched on managedLogQueue
let managedLogDirectoryMode: mode_t = 0o755
let managedLogFileMode: mode_t = 0o644

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

// MARK: Locations

/// The per-user log root under `home`: ~/Library/Logs/Managed Notifications.
func managedLogUserDirectory(home: String = NSHomeDirectory()) -> String {
    return (home as NSString).appendingPathComponent(managedLogUserSubpath)
}

/// Where this process logs. Root logs under the root folder once it is locked;
/// every other context, and root when the root folder cannot be trusted, logs
/// under its own home.
func managedLogBaseDirectory(isRoot: Bool, rootReady: Bool, userDirectory: String) -> String {
    return isRoot && rootReady ? managedLogRootDirectory : userDirectory
}

/// True when `path` is the root log folder or inside it.
func managedLogIsInsideRootDirectory(_ path: String, root: String = managedLogRootDirectory) -> Bool {
    return path == root || path.hasPrefix(root + "/")
}

/// The log for `date`, day-nested inside `base`. Resolved per record so a
/// dialog left open across midnight rolls onto the new day directory.
func managedLogPath(base: String, date: Date) -> String {
    return base + "/" + managedLogDayStamp.string(from: date) + "/dialog.log"
}

private func managedLogIsRoot() -> Bool {
    return geteuid() == 0
}

/// Prepared once per root process; never evaluated in another context.
private let managedLogRootReady: Bool = {
    guard managedLogIsRoot() else { return false }
    return prepareManagedLogRoot()
}()

private func managedLogCurrentBase() -> String {
    let isRoot = managedLogIsRoot()
    return managedLogBaseDirectory(isRoot: isRoot, rootReady: isRoot && managedLogRootReady,
                                   userDirectory: managedLogUserDirectory())
}

// MARK: Locking the root folder

/// Root only. Locks the root log folder and resets anything a world-writable
/// layout left inside it, then reports whether root may log there.
@discardableResult
func prepareManagedLogRoot(_ path: String = managedLogRootDirectory,
                           ownedComponents: Int = managedLogOwnedComponents,
                           trustedOwners: Set<uid_t> = [0],
                           owner: uid_t = 0, group: gid_t = 0) -> Bool {
    let descriptor = openLockedManagedLogDirectory(path, ownedComponents: ownedComponents,
                                                   trustedOwners: trustedOwners, owner: owner, group: group)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    lockManagedLogTree(descriptor, depth: 2, owner: owner, group: group)
    return true
}

/// Opens `path` one component at a time from "/", never following a symlink.
/// Folders above the last `ownedComponents` must be owned by a trusted owner and
/// writable by no group or other. The owned folders are created when missing
/// and set to `owner`:`group` mode 0755. Returns the final folder's descriptor,
/// or -1 when any component is a symlink, not a folder, or not trusted.
func openLockedManagedLogDirectory(_ path: String, ownedComponents: Int,
                                   trustedOwners: Set<uid_t> = [0],
                                   owner: uid_t = 0, group: gid_t = 0) -> Int32 {
    guard path.hasPrefix("/") else { return -1 }
    let components = path.split(separator: "/").map(String.init)
    guard !components.contains(".."), !components.contains("."), ownedComponents <= components.count else { return -1 }
    var current = open("/", O_RDONLY | O_DIRECTORY)
    guard current >= 0 else { return -1 }

    func isLocked(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && trustedOwners.contains(info.st_uid) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    guard isLocked(current) else { close(current); return -1 }
    for (index, component) in components.enumerated() {
        let owned = index >= components.count - ownedComponents
        if owned {
            _ = mkdirat(current, component, managedLogDirectoryMode)
        }
        // O_NOFOLLOW makes a symlink fail here rather than be walked through.
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        close(current)
        guard next >= 0 else { return -1 }
        current = next
        if owned {
            guard fchown(current, owner, group) == 0, fchmod(current, managedLogDirectoryMode) == 0 else {
                close(current)
                return -1
            }
        }
        guard isLocked(current) else { close(current); return -1 }
    }
    return current
}

/// Resets everything under the folder open at `directory` to root's: folders
/// `owner`:`group` 0755, files 0644. A folder is locked before its entries are
/// read, so no other account can add or swap an entry while the walk runs. A
/// symlink, a hard-linked file (which could share its inode with a file
/// elsewhere), or anything that is neither file nor folder is unlinked, never
/// followed or re-moded. Folders deeper than `depth` are left as they are.
func lockManagedLogTree(_ directory: Int32, depth: Int, owner: uid_t = 0, group: gid_t = 0) {
    for name in managedLogEntryNames(directory) {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard depth > 0 else { continue }
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { continue }
            if fchown(child, owner, group) == 0, fchmod(child, managedLogDirectoryMode) == 0 {
                lockManagedLogTree(child, depth: depth - 1, owner: owner, group: group)
            }
            close(child)
        case S_IFREG:
            let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { continue }
            var opened = stat()
            if fstat(file, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_nlink == 1 {
                _ = fchown(file, owner, group)
                _ = fchmod(file, managedLogFileMode)
                close(file)
            } else {
                close(file)
                unlinkat(directory, name, 0)
            }
        default:
            unlinkat(directory, name, 0)
        }
    }
}

// MARK: Day directories and retention

/// True when `path` is a real directory, not a symlink, owned by root or by
/// this process.
func managedLogDirectoryIsTrusted(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    return info.st_uid == 0 || info.st_uid == geteuid()
}

/// Creates a day directory, mode 0755, inside a log root. An existing entry is
/// never followed or re-moded; it is used only when it is a trusted directory.
/// Root sets aside anything else under the day's name and makes its own, so
/// root records stay in the collected location.
func ensureManagedLogDayDirectory(_ path: String) -> Bool {
    var info = stat()
    if lstat(path, &info) == 0 {
        if managedLogDirectoryIsTrusted(path) { return true }
        guard managedLogIsRoot(), setAsideManagedLogEntry(path) else { return false }
    }
    guard mkdir(path, managedLogDirectoryMode) == 0 else { return false }
    chmod(path, managedLogDirectoryMode)
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

/// Removes day directories under `base` past the retention window, once per
/// process and log root.
private func pruneManagedLogDays(in base: String, now: Date = Date()) {
    guard !managedLogPruned.contains(base) else { return }
    managedLogPruned.insert(base)
    pruneManagedLogEntries(in: base, now: now)
}

/// Removes day directories, and entries set aside by root, past the retention
/// window. Best-effort: a directory this process does not own is left alone.
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

// MARK: Writing

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
/// that is not a regular file with one link, and sets a file this process owns
/// to mode 0644.
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

/// Appends `record` to `path`, a file in a day directory under a log root. The
/// root log folder is written only by root, and only once it is locked.
private func appendManagedLog(_ record: String, to path: String) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    let base = (directory as NSString).deletingLastPathComponent
    if managedLogIsInsideRootDirectory(base) {
        guard managedLogIsRoot(), managedLogRootReady, base == managedLogRootDirectory else { return false }
    } else if !FileManager.default.fileExists(atPath: base) {
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: managedLogDirectoryMode])
    }
    guard ensureManagedLogDayDirectory(directory) else { return false }
    pruneManagedLogDays(in: base)
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
    var bases = [managedLogCurrentBase()]
    let own = managedLogUserDirectory()
    if bases[0] != own { bases.append(own) }
    for base in bases {
        let path = managedLogPath(base: base, date: date)
        if appendManagedLog(record, to: path) {
            let events = (path as NSString).deletingLastPathComponent + "/" + managedLogEventsFileName
            if !event.isEmpty { _ = appendManagedLog(event, to: events) }
            return
        }
    }
}
