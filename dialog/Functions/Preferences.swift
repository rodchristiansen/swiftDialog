//
//  Preferences.swift
//  Dialog
//
//  Created by Bart E Reardon on 3/8/2023.
//

import Foundation

// MARK: - Dialog Preferences

struct DialogPreferences: Codable {
    var authorisationKey: String = ""
}

/// Preference names accepted for the authorisation key, in order of precedence.
let authorisationKeyNames = ["AuthorisationKey", "AuthorizationKey", "AuthKey", "Key"]

/// Returns the first authorisation key that a configuration profile enforces.
///
/// A key is only honoured when it is managed: a value the user could set in
/// their own preferences is ignored, so it can neither grant nor require
/// authorisation. With no managed key the result is empty and no key is required.
func managedAuthorisationKey(isForced: (String) -> Bool, value: (String) -> String?) -> String {
    for name in authorisationKeyNames where isForced(name) {
        if let key = value(name), !key.isEmpty {
            return key
        }
    }
    return ""
}

func loadPreferences() -> DialogPreferences {
    let domain = (Bundle.main.bundleIdentifier ?? "au.csiro.dialog") as CFString
    var dialogPrefs = DialogPreferences()

    dialogPrefs.authorisationKey = managedAuthorisationKey(
        isForced: { CFPreferencesAppValueIsForced($0 as CFString, domain) },
        value: { CFPreferencesCopyAppValue($0 as CFString, domain) as? String }
    )

    for name in authorisationKeyNames where !CFPreferencesAppValueIsForced(name as CFString, domain) {
        if CFPreferencesCopyAppValue(name as CFString, domain) != nil {
            writeLog("\(name) is set but not managed by a profile; ignoring it", logLevel: .debug)
        }
    }

    return dialogPrefs
}

func dialogAuthorisationKey() -> String {
    return loadPreferences().authorisationKey
}

func authorisationKeyMatches(key: String, storedKey: String) -> Bool {
    return storedKey.isEmpty || key == storedKey
}

func checkAuthorisationKey(key: String) -> Bool {
    let matches = authorisationKeyMatches(key: key, storedKey: dialogAuthorisationKey())
    writeLog("auth key \(matches ? "accepted" : "rejected")", logLevel: .debug)
    return matches
}
