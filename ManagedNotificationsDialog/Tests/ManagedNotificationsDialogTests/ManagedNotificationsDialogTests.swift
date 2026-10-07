import Foundation
import Testing
@testable import ManagedNotificationsDialogApp

// MARK: - Line levels, against the lines dialog actually writes

@Suite struct LineLevelTests {
    @Test func logFileLevels() {
        #expect(LineLevel.classify("[2026-10-06 09:14:02] ERROR  Image resource cannot be found") == .error)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] DEBUG  Auth key is required") == .debug)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] INFO   dialog started") == .info)
    }

    @Test func runnerLines() {
        #expect(LineLevel.classify("[+] Dialog shown, closed by button 1 (exit 0)") == .success)
        #expect(LineLevel.classify("ERROR: dialog needs the authorisation key on this Mac (exit 30)") == .error)
        #expect(LineLevel.classify("WARN: Run stopped by user.") == .warning)
        #expect(LineLevel.classify("=== Info test dialog ===") == .header)
    }
}

// MARK: - Presets

@Suite struct DialogPresetTests {
    @Test func everyPresetHasATitleAndStaysOnTop() {
        for preset in DialogPreset.allCases {
            let args = preset.arguments(commandFile: "/tmp/x")
            #expect(args.contains("--title"))
            #expect(args.contains("--ontop"))
        }
    }

    @Test func timedPresetsCloseThemselves() {
        for preset in [DialogPreset.info, .alert] {
            let args = preset.arguments()
            let timer = try? #require(args.firstIndex(of: "--timer"))
            #expect(timer != nil)
        }
    }

    @Test func progressUsesTheCommandFileAndQuits() {
        let args = DialogPreset.progress.arguments(commandFile: "/tmp/cmd")
        #expect(args.contains("--commandfile"))
        #expect(args.last == "/tmp/cmd")
        #expect(args[args.firstIndex(of: "--progress")! + 1] == String(DialogPreset.progressSteps))

        let commands = DialogPreset.progressCommands()
        #expect(commands.last == "quit:")
        #expect(commands.filter { $0.hasPrefix("progress: ") }.count == DialogPreset.progressSteps)
    }

    @Test func argumentsNeverCarryAKey() {
        for preset in DialogPreset.allCases {
            #expect(!preset.arguments(commandFile: "/tmp/x").contains("--authkey"))
        }
    }

    @Test func alertUsesTheAlertStyle() {
        let args = DialogPreset.alert.arguments()
        #expect(args[args.firstIndex(of: "--style")! + 1] == "alert")
    }
}

// MARK: - Exit codes

@Suite struct DialogOutcomeTests {
    @Test func normalClosesAreSuccess() {
        for code: Int32 in [0, 2, 3, 4, 5, 10, 15, 20] {
            #expect(DialogOutcome(exitCode: code).isSuccess, "exit \(code)")
        }
    }

    @Test func keyAndFailures() {
        #expect(DialogOutcome(exitCode: 30) == .keyRequired)
        #expect(DialogOutcome(exitCode: 201) == .failed(201))
        #expect(!DialogOutcome(exitCode: 1).isSuccess)
    }

    @Test func userStopWinsOverTheExitCode() {
        #expect(DialogOutcome(exitCode: 15, stoppedByUser: true) == .stopped)
        #expect(DialogOutcome(exitCode: 40, stoppedByUser: true) == .stopped)
    }
}

// MARK: - Authorisation key state

private struct FakePreferences: PreferenceSource {
    var values: Set<String> = []
    var managed: Set<String> = []
    func hasValue(forKey key: String) -> Bool { values.contains(key) }
    func isManaged(_ key: String) -> Bool { managed.contains(key) }
}

@Suite struct AuthorisationKeyStateTests {
    @Test func notSet() {
        #expect(AuthorisationKeyState.resolve(from: FakePreferences()) == .notSet)
        #expect(!AuthorisationKeyState.notSet.requiresKeyForRuns)
    }

    @Test func managedByProfile() {
        let prefs = FakePreferences(values: ["AuthorisationKey"], managed: ["AuthorisationKey"])
        #expect(AuthorisationKeyState.resolve(from: prefs) == .managed(keyName: "AuthorisationKey"))
    }

    @Test func setOutsideAProfile() {
        let prefs = FakePreferences(values: ["AuthKey"])
        #expect(AuthorisationKeyState.resolve(from: prefs) == .unmanaged(keyName: "AuthKey"))
        #expect(AuthorisationKeyState.resolve(from: prefs).requiresKeyForRuns)
    }

    @Test func firstNameWithAValueWins() {
        // dialog reads AuthorisationKey before AuthKey; the report follows it.
        let prefs = FakePreferences(values: ["AuthorisationKey", "AuthKey"], managed: ["AuthKey"])
        #expect(AuthorisationKeyState.resolve(from: prefs) == .unmanaged(keyName: "AuthorisationKey"))
    }
}

// MARK: - Logs

@Suite struct LogSessionStoreTests {
    @Test func generations() {
        #expect(LogSessionStore.generation(of: "dialog.log.1") == 1)
        #expect(LogSessionStore.generation(of: "dialog.log.5") == 5)
        #expect(LogSessionStore.generation(of: "dialog.log") == nil)
        #expect(LogSessionStore.generation(of: "events.jsonl") == nil)
    }

    @Test func listsDaysNewestFirstThenTheUserLog() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mnd-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }

        func write(_ relative: String) throws {
            let path = (root as NSString).appendingPathComponent(relative)
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write("2026-10-05/dialog.log")
        try write("2026-10-05/events.jsonl")
        try write("2026-10-06/dialog.log")
        try write("2026-10-06/dialog.log.1")
        try write("not-a-day/dialog.log")
        try write("user/2026-10-06/dialog.log")
        try write("user/2026-10-07/dialog.log")
        try write("legacy/dialog.log")

        let legacy = (root as NSString).appendingPathComponent("legacy/dialog.log")
        let sessions = LogSessionStore.sessions(system: root, user: (root as NSString).appendingPathComponent("user"),
                                                legacyUserLog: legacy)
        #expect(sessions.map(\.id) == [
            "user:2026-10-07/dialog.log",
            "system:2026-10-06/dialog.log",
            "system:2026-10-06/dialog.log.1",
            "user:2026-10-06/dialog.log",
            "system:2026-10-05/dialog.log",
            "user:" + legacy
        ])
        #expect(sessions.first?.name == "2026-10-07")
        #expect(sessions.filter { $0.source == .system }.count == 3)
        #expect(sessions.filter { $0.source == .user }.count == 3)
        #expect(LogSource.system.label != LogSource.user.label)
    }

    @Test func userLogsLiveUnderTheUsersLibrary() {
        #expect(DialogConstants.userLogsDirectory(home: "/Users/someone") == "/Users/someone/Library/Logs/Managed Notifications")
        #expect(DialogConstants.sharedLogsDirectory == "/Library/Managed Notifications/logs")
    }

    @Test func missingRootsListNothing() {
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(LogSessionStore.sessions(system: missing, user: missing + "-user").isEmpty)
    }
}
