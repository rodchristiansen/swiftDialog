//
//  ManagedLogDirectoryTests.swift
//  dialogTests
//
//  Day directories in the managed log root are created once and never
//  followed or re-moded afterwards.
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

    func testNewDayDirectoryIsCreatedStickyAndWritable() {
        let day = root.appendingPathComponent("2026-10-06").path
        XCTAssertTrue(ensureManagedLogDayDirectory(day))
        XCTAssertEqual(mode(day), 0o1777)
    }

    func testExistingDayDirectoryKeepsItsMode() throws {
        let day = root.appendingPathComponent("2026-10-06").path
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(ensureManagedLogDayDirectory(day))
        XCTAssertEqual(mode(day), 0o755)
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
        XCTAssertEqual(mode(day), 0o1777)
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
}
