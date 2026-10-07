//
//  LogView.swift
//  Managed Notifications Dialog
//
//  Logs tab: dialog's daily logs as root from /Library/Managed Notifications/logs
//  and as this user from ~/Library/Logs/Managed Notifications, each under its
//  own heading, newest first, with the selected log beside them.
//

import SwiftUI

struct LogView: View {
    @State private var sessions: [LogSession] = []
    @State private var selected: LogSession?
    @State private var logContent: String = ""
    @State private var filterText: String = ""

    private let logDirectory = DialogConstants.sharedLogsDirectory
    private let userLogDirectory = DialogConstants.userLogsDirectory()

    private func directory(for source: LogSource) -> String {
        source == .system ? logDirectory : userLogDirectory
    }

    private func heading(for source: LogSource) -> String {
        source == .system ? source.label : "\(source.label) (\(NSUserName()))"
    }

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 300, maxHeight: .infinity)

            logDetailView
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
    }

    // MARK: - Session List

    @ViewBuilder
    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Logs")
                    .font(.headline)
                Spacer()
                sidebarButton(icon: "arrow.up.forward.square", help: "Open in default app") {
                    openSelectedLog()
                }
                .disabled(selected == nil)
                sidebarButton(icon: "folder", help: "Open the selected log's folder in Finder") {
                    let folder = directory(for: selected?.source ?? .system)
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                }
                sidebarButton(icon: "arrow.clockwise", help: "Refresh log list") {
                    refresh()
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 38)

            Divider()

            List(selection: $selected) {
                ForEach(LogSource.allCases, id: \.self) { source in
                    let group = sessions.filter { $0.source == source }
                    if !group.isEmpty {
                        Section(heading(for: source)) {
                            ForEach(group) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Logs Yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Root runs log to \(logDirectory), and this user's runs to \(userLogDirectory).")
                    }
                }
            }
        }
        .onChange(of: selected) { _, newValue in
            if let session = newValue {
                logContent = (try? String(contentsOfFile: session.path, encoding: .utf8)) ?? "Unable to read log file."
            }
        }
    }

    private func sessionRow(_ session: LogSession) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayDate)
                Text(session.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.displaySize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(session)
    }

    @ViewBuilder
    private func sidebarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - Log Detail

    @ViewBuilder
    private var logDetailView: some View {
        VStack(spacing: 0) {
            if selected != nil {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(.secondary)
                    TextField("Filter log...", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)
                .frame(minHeight: 38)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(LineLevel.classify(line).color)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.black.opacity(0.85))
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "doc.text",
                    description: Text("There are no logs yet. They appear here after the first run.")
                )
            } else {
                ContentUnavailableView(
                    "No Log Selected",
                    systemImage: "doc.text",
                    description: Text("Select a log from the sidebar to view its contents.")
                )
            }
        }
    }

    private var filteredLines: [String] {
        let lines = logContent.components(separatedBy: "\n")
        guard !filterText.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(filterText) }
    }

    // MARK: - Actions

    private func refresh() {
        sessions = LogSessionStore.sessions(system: logDirectory, user: userLogDirectory,
                                            legacyUserLog: DialogConstants.legacyUserLogPath)
        if let current = selected, let match = sessions.first(where: { $0.id == current.id }) {
            selected = match
            logContent = (try? String(contentsOfFile: match.path, encoding: .utf8)) ?? logContent
        } else {
            selected = sessions.first
        }
    }

    private func openSelectedLog() {
        guard let session = selected else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.path))
    }
}
