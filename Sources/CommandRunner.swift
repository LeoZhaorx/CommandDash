import Foundation

final class CommandRunner {
    private var process: Process?

    func run(
        command: String,
        environment: [String: String] = [:],
        onStart: ((Int32) -> Void)? = nil,
        onOutput: @escaping (String) -> Void,
        onComplete: @escaping (Int32) -> Void
    ) {
        run(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            environment: environment,
            onStart: onStart,
            onOutput: onOutput,
            onComplete: onComplete
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        onStart: ((Int32) -> Void)? = nil,
        onOutput: @escaping (String) -> Void,
        onComplete: @escaping (Int32) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
                new
            }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8) {
                onOutput(text)
            }
        }

        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            onComplete(proc.terminationStatus)
        }

        do {
            try process.run()
            onStart?(process.processIdentifier)
            self.process = process
        } catch {
            onOutput("Failed to run: \(error.localizedDescription)\n")
            onComplete(-1)
        }
    }
}
