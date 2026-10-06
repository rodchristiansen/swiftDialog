# Managed Notifications Dialog

A Prefs / Run / Logs window for swiftDialog, installed as
`/Applications/Utilities/Managed Notifications Dialog.app`. It leaves `dialog`,
`Dialog.app` and their install paths unchanged.

- **Prefs** shows whether an authorisation key is set for `au.csiro.dialog` and
  whether a configuration profile manages it, plus the installed `dialog` and
  where it logs. The key's value is never shown. dialog has no other machine
  settings, so the tab is read-only.
- **Run** shows one of three preset test dialogs (info, progress, alert) and
  streams what `dialog` prints. When the Mac requires the authorisation key,
  the window asks for it and passes it to that one run through
  `DIALOG_AUTH_KEY`, never on the command line, and does not keep it.
- **Logs** lists dialog's daily logs under
  `/Library/Managed Notifications/logs/<date>/dialog.log`, and the signed-in
  user's fallback `~/Library/Logs/dialog.log`.

The window runs `dialog` as the signed-in user, which is how dialog always runs
its windows, so the package installs no privileged helper.

Build and test:

```
swift test
```

```
make pkg
```

Set `SIGNING_IDENTITY_APP` and `SIGNING_IDENTITY_PKG` to sign the app and the
package, and `NOTARIZATION_PROFILE` for `make notarize`.
