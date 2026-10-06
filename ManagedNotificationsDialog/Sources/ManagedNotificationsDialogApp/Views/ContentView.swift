//
//  ContentView.swift
//  Managed Notifications Dialog
//
//  Main window with three tabs: Prefs, Run, and Logs.
//  Uses standard TabView which renders as Liquid Glass on macOS 26+.
//

import SwiftUI

struct ContentView: View {
    @Environment(DialogRunner.self) private var runner
    @State private var selectedTab: ContentTab = .prefs

    enum ContentTab: Hashable {
        case prefs, run, logs
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SettingsView()
                .tabItem { Text("Prefs") }
                .tag(ContentTab.prefs)

            RunView()
                .environment(runner)
                .tabItem { Text("Run") }
                .tag(ContentTab.run)

            LogView()
                .tabItem { Text("Logs") }
                .tag(ContentTab.logs)
        }
    }
}
