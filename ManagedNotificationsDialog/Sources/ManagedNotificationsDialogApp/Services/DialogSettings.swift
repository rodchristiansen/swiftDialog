//
//  DialogSettings.swift
//  Managed Notifications Dialog
//
//  What the Prefs tab shows: whether an authorisation key is set and whether a
//  configuration profile manages it, plus the installed dialog. The key's value
//  is never read into the window.
//

import Foundation

protocol PreferenceSource {
    /// True when the key has a value at any level dialog reads.
    func hasValue(forKey key: String) -> Bool
    /// True when a configuration profile manages the key.
    func isManaged(_ key: String) -> Bool
}

struct SystemPreferenceSource: PreferenceSource {
    let domain = DialogConstants.preferenceDomain as CFString

    func hasValue(forKey key: String) -> Bool {
        CFPreferencesCopyAppValue(key as CFString, domain) != nil
    }

    func isManaged(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain)
    }
}

enum AuthorisationKeyState: Equatable, Sendable {
    /// A configuration profile sets the key; dialog needs it on the command line
    /// or in DIALOG_AUTH_KEY.
    case managed(keyName: String)
    /// A key is set, but not by a configuration profile.
    case unmanaged(keyName: String)
    case notSet

    static func resolve(from source: PreferenceSource) -> AuthorisationKeyState {
        // dialog reads the first name that has a value; report that one.
        for name in DialogConstants.authorisationKeyNames where source.hasValue(forKey: name) {
            return source.isManaged(name) ? .managed(keyName: name) : .unmanaged(keyName: name)
        }
        if let name = DialogConstants.authorisationKeyNames.first(where: { source.isManaged($0) }) {
            return .managed(keyName: name)
        }
        return .notSet
    }

    var requiresKeyForRuns: Bool {
        if case .notSet = self { return false }
        return true
    }
}

struct InstalledDialog: Equatable, Sendable {
    let commandInstalled: Bool
    let appVersion: String?

    static func current(fileManager fm: FileManager = .default) -> InstalledDialog {
        let info = NSDictionary(contentsOfFile: DialogConstants.appPath + "/Contents/Info.plist")
        return InstalledDialog(
            commandInstalled: fm.isExecutableFile(atPath: DialogConstants.commandPath),
            appVersion: info?["CFBundleShortVersionString"] as? String
        )
    }
}
