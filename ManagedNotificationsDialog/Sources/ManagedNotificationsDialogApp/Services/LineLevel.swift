//
//  LineLevel.swift
//  Managed Notifications Dialog
//
//  Classifies a line of dialog output for colouring, in the two forms dialog
//  writes: the log file's "[yyyy-MM-dd HH:mm:ss] LEVEL message" and the
//  console's "LEVEL: message".
//

import SwiftUI

enum LineLevel: Equatable, Sendable {
    case info, debug, warning, error, success, header

    static func classify(_ line: String) -> LineLevel {
        if line.contains("[X]") || line.contains("[x]") || line.contains("✗") { return .error }
        if line.contains("[!]") || line.contains("⚠") { return .warning }
        if line.contains("[+]") || line.contains("✓") { return .success }

        let message: Substring
        let level: Substring
        if line.hasPrefix("["), let close = line.range(of: "] ") {
            // Log file: the level is the unbracketed token after the timestamp.
            let rest = line[close.upperBound...]
            let token = rest.prefix { !$0.isWhitespace }
            level = token
            message = rest.dropFirst(token.count).drop { $0.isWhitespace }
        } else if let colon = line.firstIndex(of: ":"), line[..<colon].allSatisfy({ $0.isUppercase }) {
            // Console: "INFO: message", "ERROR: message".
            level = line[..<colon]
            message = line[line.index(after: colon)...].drop { $0.isWhitespace }
        } else {
            return plainLevel(line[...])
        }

        switch level {
        case "ERROR", "FAULT": return .error
        case "WARN", "WARNING": return .warning
        case "DEBUG": return .debug
        default: return plainLevel(message)
        }
    }

    private static func plainLevel(_ message: Substring) -> LineLevel {
        message.hasPrefix("===") ? .header : .info
    }

    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .success: .green
        case .debug: .gray
        case .header: .cyan
        case .info: .white
        }
    }
}
