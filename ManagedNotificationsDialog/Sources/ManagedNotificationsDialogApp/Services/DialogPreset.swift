//
//  DialogPreset.swift
//  Managed Notifications Dialog
//
//  The fixed test dialogs the Run tab can show, and what dialog's exit codes
//  mean. Arguments are built here only; the window never passes free text to
//  dialog.
//

import Foundation

enum DialogConstants {
    static let preferenceDomain = "au.csiro.dialog"
    /// Key names dialog accepts for the authorisation key, in the order it reads them.
    static let authorisationKeyNames = ["AuthorisationKey", "AuthorizationKey", "AuthKey", "Key"]
    static let commandPath = "/usr/local/bin/dialog"
    static let appPath = "/Library/Application Support/Dialog/Dialog.app"
    static let sharedLogsDirectory = "/Library/Managed Notifications/logs"
    static var userLogPath: String { NSHomeDirectory() + "/Library/Logs/dialog.log" }
}

enum DialogPreset: String, CaseIterable, Identifiable, Sendable {
    case info, progress, alert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .progress: "Progress"
        case .alert: "Alert"
        }
    }

    var summary: String {
        switch self {
        case .info: "A standard dialog with one button. It closes itself after 30 seconds."
        case .progress: "A dialog with a progress bar that this window advances through five steps, then closes."
        case .alert: "A compact alert-style dialog with OK and Cancel. It closes itself after 30 seconds."
        }
    }

    /// Steps the progress preset walks through, one a second.
    static let progressSteps = 5

    /// Arguments for `dialog`. `commandFile` is required for `.progress`.
    func arguments(commandFile: String? = nil) -> [String] {
        let title = "Managed Notifications Dialog test"
        switch self {
        case .info:
            return ["--title", title,
                    "--message", "If you can read this, dialog works on this Mac.",
                    "--icon", "SF=bell.badge.fill",
                    "--button1text", "OK",
                    "--timer", "30",
                    "--ontop"]
        case .progress:
            var args = ["--title", title,
                        "--message", "Showing a progress bar driven through dialog's command file.",
                        "--icon", "SF=gauge.with.dots.needle.67percent",
                        "--progress", String(Self.progressSteps),
                        "--progresstext", "Starting",
                        "--button1disabled",
                        "--ontop"]
            if let commandFile {
                args += ["--commandfile", commandFile]
            }
            return args
        case .alert:
            return ["--title", title,
                    "--message", "This is the alert style.",
                    "--style", "alert",
                    "--button1text", "OK",
                    "--button2text", "Cancel",
                    "--timer", "30",
                    "--ontop"]
        }
    }

    /// The command-file lines that advance the progress preset, in order.
    static func progressCommands() -> [String] {
        var lines: [String] = []
        for step in 1...progressSteps {
            lines.append("progress: \(step)")
            lines.append("progresstext: Step \(step) of \(progressSteps)")
        }
        lines.append("progresstext: Done")
        lines.append("quit:")
        return lines
    }
}

/// What dialog's exit status says about a test run.
enum DialogOutcome: Equatable, Sendable {
    /// The dialog was shown and closed in one of the normal ways.
    case shown(String)
    /// dialog refused to start without the authorisation key.
    case keyRequired
    case stopped
    case failed(Int32)

    init(exitCode: Int32, stoppedByUser: Bool = false) {
        if stoppedByUser {
            self = .stopped
            return
        }
        switch exitCode {
        case 0: self = .shown("button 1")
        case 2: self = .shown("button 2")
        case 3: self = .shown("the info button")
        case 4: self = .shown("its timer")
        case 5: self = .shown("its command file")
        case 10: self = .shown("the quit key")
        case 15: self = .shown("the close button")
        case 20: self = .shown("its timeout")
        case 30: self = .keyRequired
        default: self = .failed(exitCode)
        }
    }

    var isSuccess: Bool {
        if case .shown = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .shown(let how): "Dialog shown, closed by \(how)"
        case .keyRequired: "dialog needs the authorisation key on this Mac"
        case .stopped: "Stopped"
        case .failed(let code): "dialog failed with exit code \(code)"
        }
    }
}
