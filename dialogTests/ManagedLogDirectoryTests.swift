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
        XCTAssertFalse(ensureManagedLogDayDirectory(day))
        XCTAssertFalse(managedLogDirectoryIsTrusted(day))
        XCTAssertEqual(mode(target), 0o700)
    }

    func testPlainFileUnderTheDayNameIsRefused() throws {
        let day = root.appendingPathComponent("2026-10-06").path
        XCTAssertTrue(FileManager.default.createFile(atPath: day, contents: Data()))
        XCTAssertFalse(ensureManagedLogDayDirectory(day))
    }
}
