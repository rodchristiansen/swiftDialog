//
//  ManagedNotificationsDialogApp.swift
//  Managed Notifications Dialog
//
//  SwiftUI window for swiftDialog: its managed settings, preset test dialogs
//  with live output, and the dialog log.
//

import SwiftUI

@main
struct ManagedNotificationsDialogApp: App {
    @State private var runner = DialogRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(runner)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 850, height: 748)
    }
}
