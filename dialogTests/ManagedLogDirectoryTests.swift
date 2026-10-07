//
//  ManagedLogDirectoryTests.swift
//  dialogTests
//
//  Day directories in a log root are created once and never followed or
//  re-moded afterwards; the root log folder is root's alone and is locked
//  without following a symlink; user-context logs go to the user's home.
//

import XCTest
@testable import Dialog

final class ManagedLogDirectoryTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedLogDirectoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o7777
    }

    func testNewDayDirectoryIsCreated0755() {
        let day = root.appendingPathComponent("2026-10-06").path
        XCTAssertTrue(ensureManagedLogDayDirectory(day))
        XCTAssertEqual(mode(day), 0o755)
    }

    func testExistingDayDirectoryKeepsItsMode() throws {
        let day = root.appendingPathComponent("2026-10-06").path
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o750])
        XCTAssertTrue(ensureManagedLogDayDirectory(day))
        XCTAssertEqual(mode(day), 0o750)
    }

    func testSymlinkUnderTheDayNameIsNotFollowedOrChanged() throws {
        let target = root.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let day = root.appendingPathComponent("2026-10-06").path
        try FileManager.default.createSymbolicLink(atPath: day, withDestinationPath: target)
        // Root sets the entry aside and makes its own day; any other account stays off it.
        XCTAssertEqual(ensureManagedLogDayDirectory(day), geteuid() == 0)
        XCTAssertEqual(managedLogDirectoryIsTrusted(day), geteuid() == 0)
        XCTAssertEqual(mode(target), 0o700)
    }

    func testPlainFileUnderTheDayNameIsRefused() throws {
        let day = root.appendingPathComponent("2026-10-06").path
        XCTAssertTrue(FileManager.default.createFile(atPath: day, contents: Data()))
        XCTAssertEqual(ensureManagedLogDayDirectory(day), geteuid() == 0)
    }

    func testSetAsideNameCarriesTheTimeItWasSetAside() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let name = managedLogUntrustedName(day: "2026-10-06", pid: 42, now: now)
        XCTAssertEqual(name, ".untrusted-2026-10-06-42-1790000000")
        XCTAssertEqual(managedLogUntrustedDate(name), now)
        XCTAssertNil(managedLogUntrustedDate("2026-10-06"))
        XCTAssertNil(managedLogUntrustedDate(".untrusted-junk"))
    }

    func testRootSetsAsideADayDirectoryItDoesNotOwn() throws {
        try XCTSkipUnless(geteuid() == 0, "needs root")
        let day = root.appendingPathComponent("2026-10-06").path
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: false)
        chown(day, 4_294_967_294, 4_294_967_294)

        XCTAssertTrue(ensureManagedLogDayDirectory(day))
        var info = stat()
        XCTAssertEqual(lstat(day, &info), 0)
        XCTAssertEqual(info.st_uid, 0)
        XCTAssertEqual(mode(day), 0o755)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries.filter { $0.hasPrefix(managedLogUntrustedPrefix) }.count, 1)
    }

    func testRetentionRemovesSetAsideEntriesWithoutFollowingThem() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let target = root.appendingPathComponent("target").path
        try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
        fm.createFile(atPath: target + "/keep", contents: Data("x".utf8))
        let link = root.appendingPathComponent(managedLogUntrustedName(day: "2026-07-01", pid: 1, now: old)).path
        let dir = root.appendingPathComponent(managedLogUntrustedName(day: "2026-07-02", pid: 2, now: old)).path
        let recent = managedLogUntrustedName(day: "2026-09-21", pid: 3, now: now)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: false)
        fm.createFile(atPath: dir + "/dialog.log", contents: Data("x".utf8))
        try fm.createDirectory(atPath: root.appendingPathComponent(recent).path, withIntermediateDirectories: false)

        pruneManagedLogEntries(in: root.path, now: now)

        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: root.path)), ["target", recent])
        XCTAssertTrue(fm.fileExists(atPath: target + "/keep"))
    }

    func testRetentionUnlinksALinkInsideAnExpiredDayAndItsTargetSurvives() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let target = root.appendingPathComponent("target").path
        try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
        fm.createFile(atPath: target + "/keep", contents: Data("x".utf8))
        let day = root.appendingPathComponent("2026-07-01").path
        try fm.createDirectory(atPath: day, withIntermediateDirectories: false)
        fm.createFile(atPath: day + "/dialog.log", contents: Data("x".utf8))
        try fm.createSymbolicLink(atPath: day + "/link", withDestinationPath: target)

        pruneManagedLogEntries(in: root.path, now: now)

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["target"])
        XCTAssertTrue(fm.fileExists(atPath: target + "/keep"))
    }

    func testRetentionLeavesAFolderNestedInsideAnExpiredDay() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day = root.appendingPathComponent("2026-07-01").path
        try fm.createDirectory(atPath: day + "/nested", withIntermediateDirectories: true)
        fm.createFile(atPath: day + "/dialog.log", contents: Data("x".utf8))

        pruneManagedLogEntries(in: root.path, now: now)

        XCTAssertTrue(fm.fileExists(atPath: day + "/nested"))
        XCTAssertFalse(fm.fileExists(atPath: day + "/dialog.log"))
    }

    // MARK: - Locations

    func testUserContextLogsUnderTheUsersLibrary() {
        XCTAssertEqual(managedLogUserDirectory(home: "/Users/someone"),
                       "/Users/someone/Library/Logs/Managed Notifications")
    }

    func testOnlyRootWithALockedFolderLogsThere() {
        let user = "/Users/someone/Library/Logs/Managed Notifications"
        XCTAssertEqual(managedLogBaseDirectory(isRoot: true, rootReady: true, userDirectory: user), managedLogRootDirectory)
        XCTAssertEqual(managedLogBaseDirectory(isRoot: true, rootReady: false, userDirectory: user), user)
        XCTAssertEqual(managedLogBaseDirectory(isRoot: false, rootReady: true, userDirectory: user), user)
        XCTAssertEqual(managedLogBaseDirectory(isRoot: false, rootReady: false, userDirectory: user), user)
    }

    func testLogPathIsDayNested() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let path = managedLogPath(base: "/base", date: date)
        XCTAssertTrue(path.hasPrefix("/base/20"))
        XCTAssertTrue(path.hasSuffix("/dialog.log"))
        XCTAssertEqual(path.split(separator: "/").count, 3)
    }

    func testRecognisesTheRootFolderAndNothingElse() {
        XCTAssertTrue(managedLogIsInsideRootDirectory(managedLogRootDirectory))
        XCTAssertTrue(managedLogIsInsideRootDirectory(managedLogRootDirectory + "/2026-10-06"))
        XCTAssertFalse(managedLogIsInsideRootDirectory(managedLogRootDirectory + "-x/2026-10-06"))
        XCTAssertFalse(managedLogIsInsideRootDirectory(managedLogUserDirectory(home: "/Users/someone")))
    }

    func testRootFolderModes() {
        XCTAssertEqual(managedLogDirectoryMode, 0o755)
        XCTAssertEqual(managedLogFileMode, 0o644)
    }

    // MARK: - Locking the root folder

    /// `root` resolved with realpath: the temporary directory sits under /var, a symlink.
    private var realRoot: String {
        guard let pointer = realpath(root.path, nil) else { return root.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private var trusted: Set<uid_t> { [0, geteuid()] }

    func testLockCreatesOwnedFolders0755() {
        chmod(root.path, 0o755)
        let logs = realRoot + "/Managed Notifications/logs"
        let fd = openLockedManagedLogDirectory(logs, ownedComponents: 2, trustedOwners: trusted,
                                               owner: geteuid(), group: getegid())
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { close(fd) }
        XCTAssertEqual(mode(realRoot + "/Managed Notifications"), 0o755)
        XCTAssertEqual(mode(logs), 0o755)
    }

    func testLockRefusesASymlinkedOwnedFolder() throws {
        chmod(root.path, 0o755)
        let target = realRoot + "/elsewhere"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: realRoot + "/Managed Notifications", withDestinationPath: target)
        let fd = openLockedManagedLogDirectory(realRoot + "/Managed Notifications/logs", ownedComponents: 2,
                                               trustedOwners: trusted, owner: geteuid(), group: getegid())
        XCTAssertEqual(fd, -1)
        XCTAssertEqual(mode(target), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target), [])
    }

    func testLockRefusesASymlinkAboveTheFolder() {
        // root.path is reached through /var, which is a symlink to /private/var.
        XCTAssertTrue(root.path.hasPrefix("/var/") || root.path != realRoot)
        let fd = openLockedManagedLogDirectory(root.path + "/Managed Notifications/logs", ownedComponents: 2,
                                               trustedOwners: trusted, owner: geteuid(), group: getegid())
        XCTAssertEqual(fd, -1)
    }

    func testLockRefusesAWritableFolderAbove() {
        chmod(root.path, 0o777)
        let fd = openLockedManagedLogDirectory(realRoot + "/Managed Notifications/logs", ownedComponents: 2,
                                               trustedOwners: trusted, owner: geteuid(), group: getegid())
        XCTAssertEqual(fd, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realRoot + "/Managed Notifications"))
    }

    func testLockResetsAWorldWritableLayoutAndDropsLinks() throws {
        let fm = FileManager.default
        chmod(root.path, 0o755)
        let logs = realRoot + "/Managed Notifications/logs"
        let outside = realRoot + "/outside"
        try fm.createDirectory(atPath: logs + "/2026-10-06", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: false)
        chmod(logs, 0o1777)
        chmod(logs + "/2026-10-06", 0o1777)
        fm.createFile(atPath: logs + "/2026-10-06/dialog.log", contents: Data("x".utf8))
        chmod(logs + "/2026-10-06/dialog.log", 0o666)
        fm.createFile(atPath: outside + "/secret", contents: Data("s".utf8))
        chmod(outside + "/secret", 0o600)
        try fm.createSymbolicLink(atPath: logs + "/2026-10-06/link", withDestinationPath: outside + "/secret")
        XCTAssertEqual(link(outside + "/secret", logs + "/2026-10-06/events.jsonl"), 0)

        XCTAssertTrue(prepareManagedLogRoot(logs, ownedComponents: 2, trustedOwners: trusted,
                                            owner: geteuid(), group: getegid()))

        XCTAssertEqual(mode(logs), 0o755)
        XCTAssertEqual(mode(logs + "/2026-10-06"), 0o755)
        XCTAssertEqual(mode(logs + "/2026-10-06/dialog.log"), 0o644)
        XCTAssertFalse(fm.fileExists(atPath: logs + "/2026-10-06/events.jsonl"))
        var info = stat()
        XCTAssertNotEqual(lstat(logs + "/2026-10-06/link", &info), 0)
        XCTAssertEqual(mode(outside + "/secret"), 0o600)
        XCTAssertEqual(try String(contentsOfFile: outside + "/secret", encoding: .utf8), "s")
    }
}
