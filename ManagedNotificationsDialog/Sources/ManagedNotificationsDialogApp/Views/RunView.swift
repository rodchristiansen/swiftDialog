//
//  RunView.swift
//  Managed Notifications Dialog
//
//  Run tab: choose a preset test dialog, show it, and watch dialog's output.
//

import SwiftUI

struct RunView: View {
    @Environment(DialogRunner.self) private var runner
    @State private var showDebug = false
    @State private var preset: DialogPreset = .info
    @State private var keyState: AuthorisationKeyState = .notSet
    @State private var authorisationKey = ""

    var body: some View {
        VStack(spacing: 0) {
            presetSelector
                .padding([.horizontal, .top])

            if keyState.requiresKeyForRuns {
                keyField
                    .padding([.horizontal, .top])
            }

            runControlBar
                .padding()

            resultBanner

            Divider()

            ConsoleView(outputLines: showDebug ? runner.outputLines : runner.outputLines.filter { $0.level != .debug })
                .padding()
        }
        .onAppear {
            keyState = AuthorisationKeyState.resolve(from: SystemPreferenceSource())
        }
    }

    // MARK: - Preset Selector

    @ViewBuilder
    private var presetSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Test dialog", selection: $preset) {
                ForEach(DialogPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(runner.isRunning)

            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("Authorisation key", text: $authorisationKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .disabled(runner.isRunning)
            Text("This Mac requires the authorisation key. It is passed to this test run only and never saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Run Control Bar

    @ViewBuilder
    private var runControlBar: some View {
        HStack(spacing: 12) {
            if runner.isRunning {
                stopButton
            } else {
                runButton
            }

            if runner.isRunning {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Showing...")
                        .foregroundStyle(.secondary)
                    if let caption = runner.latestProgressLine {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            statusIndicator

            Toggle("Debug", isOn: $showDebug)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show or hide DEBUG lines")

            if !runner.outputLines.isEmpty && !runner.isRunning {
                clearButton
            }
        }
    }

    // MARK: - Buttons

    private func start() {
        runner.run(preset: preset, authorisationKey: keyState.requiresKeyForRuns ? authorisationKey : nil)
    }

    @ViewBuilder
    private var runButton: some View {
        let disabled = !runner.commandInstalled
        if #available(macOS 26, *) {
            Button(action: start) {
                Label("Show Test Dialog", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(disabled)
        } else {
            Button(action: start) {
                Label("Show Test Dialog", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled)
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if #available(macOS 26, *) {
            Button(role: .destructive) {
                runner.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
        } else {
            Button(role: .destructive) {
                runner.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if #available(macOS 26, *) {
            Button("Clear") { clearOutput() }
                .buttonStyle(.glass)
                .controlSize(.small)
        } else {
            Button("Clear") { clearOutput() }
                .controlSize(.small)
        }
    }

    private func clearOutput() {
        runner.outputLines.removeAll()
        runner.lastExitCode = nil
        runner.lastOutcome = nil
    }

    // MARK: - Status

    @ViewBuilder
    private var statusIndicator: some View {
        if let outcome = runner.lastOutcome, !runner.isRunning {
            switch outcome {
            case .shown:
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .stopped:
                Label("Stopped", systemImage: "stop.circle.fill")
                    .foregroundStyle(.orange)
            case .keyRequired:
                Label("Key required", systemImage: "key.fill")
                    .foregroundStyle(.red)
            case .failed(let code):
                Label("Failed (exit \(code))", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }

        if !runner.commandInstalled && !runner.isRunning {
            Label("dialog not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if let outcome = runner.lastOutcome, !runner.isRunning {
            let colour: Color = outcome.isSuccess ? .green : (outcome == .stopped ? .orange : .red)
            HStack(spacing: 8) {
                Image(systemName: outcome.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                Text(outcome.message)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(colour)
            .padding(10)
            .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}
