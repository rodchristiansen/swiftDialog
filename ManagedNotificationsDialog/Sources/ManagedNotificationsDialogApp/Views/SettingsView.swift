//
//  SettingsView.swift
//  Managed Notifications Dialog
//
//  Prefs tab: centred app header, then dialog's machine settings in cards.
//  dialog's only machine setting is the authorisation key, which a
//  configuration profile manages, so this tab is read-only.
//

import SwiftUI

struct SettingsView: View {
    @State private var keyState: AuthorisationKeyState = .notSet
    @State private var installed = InstalledDialog(commandInstalled: false, appVersion: nil)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                appInfoHeader

                Divider()

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        authorisationSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 16) {
                        installSection
                        loggingSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding()
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        keyState = AuthorisationKeyState.resolve(from: SystemPreferenceSource())
        installed = InstalledDialog.current()
    }

    // MARK: - App Info Header

    @ViewBuilder
    private var appInfoHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            Text("Managed Notifications Dialog")
                .font(.largeTitle.bold())

            Text("Shows managed dialogs, notifications and progress windows to the people using this Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Documentation", destination: URL(string: "https://github.com/rodchristiansen/swiftDialog#readme")!)
                    .font(.caption)
                Link("Report Issue", destination: URL(string: "https://github.com/swiftDialog/swiftDialog/issues")!)
                    .font(.caption)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Sections

    @ViewBuilder
    private var authorisationSection: some View {
        card("Authorisation", systemImage: "key") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Authorisation key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch keyState {
                case .managed(let name):
                    Text("Set; dialog shows nothing unless the caller supplies the key.")
                    Label("Managed (\(name))", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .unmanaged(let name):
                    Text("Set outside a configuration profile (\(name)).")
                        .foregroundStyle(.orange)
                case .notSet:
                    Text("Not set; any process can show a dialog.")
                }
            }
            Text("Only a configuration profile for \(DialogConstants.preferenceDomain) should set the key. Its value is never shown here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installSection: some View {
        card("Installed", systemImage: "shippingbox") {
            infoRow("Command", installed.commandInstalled ? DialogConstants.commandPath : "Not installed",
                    warn: !installed.commandInstalled)
            infoRow("Dialog.app version", installed.appVersion ?? "Not installed", warn: installed.appVersion == nil)
        }
    }

    @ViewBuilder
    private var loggingSection: some View {
        card("Logging", systemImage: "doc.text") {
            infoRow("Shared log", DialogConstants.sharedLogsDirectory + "/<date>/dialog.log")
            infoRow("Fallback", "~/Library/Logs/dialog.log")
            Text("Debug lines reach the log only when dialog runs with --verbose or --debug.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(warn ? .orange : .primary)
        }
    }
}
