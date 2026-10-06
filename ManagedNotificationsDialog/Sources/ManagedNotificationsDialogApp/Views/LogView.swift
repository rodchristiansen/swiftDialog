//
//  LogView.swift
//  Managed Notifications Dialog
//
//  Logs tab: dialog's daily logs from /Library/Managed Notifications/logs,
//  newest first, and your own fallback log, with the selected log beside them.
//

import SwiftUI

struct LogView: View {
    @State private var sessions: [LogSession] = []
    @State private var selected: LogSession?
    @State private var logContent: String = ""
    @State private var filterText: String = ""

    private let logDirectory = DialogConstants.sharedLogsDirectory

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)

            logDetailView
        }
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
                sidebarButton(icon: "folder", help: "Open log folder in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: logDirectory))
                }
                sidebarButton(icon: "arrow.clockwise", help: "Refresh log list") {
                    refresh()
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 38)

            Divider()

            List(sessions, selection: $selected) { session in
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
            .listStyle(.sidebar)
        }
        .onChange(of: selected) { _, newValue in
            if let session = newValue {
                logContent = (try? String(contentsOfFile: session.path, encoding: .utf8)) ?? "Unable to read log file."
            }
        }
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
        sessions = LogSessionStore.sessions(in: logDirectory, userLog: DialogConstants.userLogPath)
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
