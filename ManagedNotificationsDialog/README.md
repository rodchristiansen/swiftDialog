# Managed Notifications Dialog

A Prefs / Run / Logs window for swiftDialog, installed as
`/Applications/Utilities/Managed Notifications Dialog.app`. It ships inside the
SwiftDialog package alongside `Dialog.app`, so every Mac that gets dialog gets
the window, and it leaves `dialog`, `Dialog.app` and their install paths
unchanged.

- **Prefs** shows whether an authorisation key is set for `au.csiro.dialog` and
  whether a configuration profile manages it, plus the installed `dialog` and
  where it logs. The key's value is never shown. dialog has no other machine
  settings, so the tab is read-only.
- **Run** shows one of three preset test dialogs (info, progress, alert) and
  streams what `dialog` prints. When the Mac requires the authorisation key,
  the window asks for it and passes it to that one run through
  `DIALOG_AUTH_KEY`, never on the command line, and does not keep it.
- **Logs** lists dialog's daily logs as root, under
  `/Library/Managed Notifications/logs/<date>/dialog.log`, and as the signed-in
  user, under `~/Library/Logs/Managed Notifications/<date>/dialog.log`, each
  under its own heading.

The window runs `dialog` as the signed-in user, which is how dialog always runs
its windows, so nothing privileged is installed for it.

Build and test:

```
swift test
```

```
make app
```

`make app` leaves the bundle in `build/pkg-root`, where the release workflow
picks it up. Set `SIGNING_IDENTITY_APP` to sign it.
