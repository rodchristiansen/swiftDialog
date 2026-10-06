//
//  DialogRunner.swift
//  Managed Notifications Dialog
//
//  Runs one preset test dialog as the signed-in user and streams what dialog
//  prints. dialog is a per-user GUI process, so nothing here needs root.
//

import Foundation

@Observable
@MainActor
final class DialogRunner {
    var outputLines: [OutputLine] = []
    var isRunning = false
    var lastExitCode: Int32?
    var lastOutcome: DialogOutcome?

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let level: LineLevel
    }

    private var process: Process?
    private var progressTask: Task<Void, Never>?
    private var stoppedByUser = false
    private var workDirectory: URL?

    var errorCount: Int {
        outputLines.filter { $0.level == .error }.count
    }

    /// The newest line worth showing as the run's progress caption.
    var latestProgressLine: String? {
        outputLines.last { $0.level == .info || $0.level == .header }?.text
    }

    var commandInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: DialogConstants.commandPath)
    }

    /// Shows `preset`. `authorisationKey` is passed to dialog through its
    /// environment, never on the command line, and is not kept.
    func run(preset: DialogPreset, authorisationKey: String? = nil) {
        guard !isRunning else { return }
        outputLines.removeAll()
        lastExitCode = nil
        lastOutcome = nil
        stoppedByUser = false

        guard commandInstalled else {
            append("ERROR: \(DialogConstants.commandPath) is not installed")
            lastExitCode = 127
            lastOutcome = .failed(127)
            return
        }

        var commandFile: URL?
        if preset == .progress {
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ManagedNotificationsDialog-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("commands.log")
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                workDirectory = directory
                commandFile = file
            } catch {
                append("ERROR: Could not create the command file: \(error.localizedDescription)")
                lastExitCode = 1
                lastOutcome = .failed(1)
                return
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: DialogConstants.commandPath)
        task.arguments = preset.arguments(commandFile: commandFile?.path)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DIALOG_AUTH_KEY")
        if let authorisationKey, !authorisationKey.isEmpty {
            environment["DIALOG_AUTH_KEY"] = authorisationKey
        }
        task.environment = environment

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendChunk(text)
            }
        }

        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                if let text = String(data: rest, encoding: .utf8), !text.isEmpty {
                    self?.appendChunk(text)
                }
                self?.finish(status: status)
            }
        }

        append("=== \(preset.title) test dialog ===")
        do {
            try task.run()
        } catch {
            append("ERROR: Could not start dialog: \(error.localizedDescription)")
            lastExitCode = 1
            lastOutcome = .failed(1)
            cleanUp()
            return
        }
        process = task
        isRunning = true

        if let commandFile {
            progressTask = Task { [weak self] in
                await self?.driveProgress(commandFile: commandFile)
            }
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        stoppedByUser = true
        append("WARN: Run stopped by user.")
        process.terminate()
    }

    // MARK: - Private

    private func driveProgress(commandFile: URL) async {
        // Give the window a moment to appear before the first update.
        try? await Task.sleep(for: .seconds(1.5))
        for line in DialogPreset.progressCommands() {
            guard !Task.isCancelled, isRunning else { return }
            if let handle = try? FileHandle(forWritingTo: commandFile) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
            append("INFO: Sent \"\(line)\"")
            if line.hasPrefix("progress:") {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finish(status: Int32) {
        progressTask?.cancel()
        progressTask = nil
        process = nil
        isRunning = false
        lastExitCode = status
        let outcome = DialogOutcome(exitCode: status, stoppedByUser: stoppedByUser)
        lastOutcome = outcome
        switch outcome {
        case .shown: append("[+] \(outcome.message) (exit \(status))")
        case .keyRequired: append("ERROR: \(outcome.message) (exit 30)")
        case .stopped: append("WARN: \(outcome.message) (exit \(status))")
        case .failed: append("ERROR: \(outcome.message)")
        }
        cleanUp()
    }

    private func cleanUp() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
    }

    private func appendChunk(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            append(String(line))
        }
    }

    private func append(_ text: String) {
        outputLines.append(OutputLine(text: text, level: LineLevel.classify(text)))
    }
}
