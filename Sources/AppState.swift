import Foundation
import Combine
import AppKit
import Darwin

final class AppState: ObservableObject {
    static let allTabName = "全部"

    @Published private(set) var commands: [CommandItem] = []
    @Published private(set) var tabs: [String] = []
    @Published var consoleText: String = ""
    @Published var isRunning: Bool = false
    @Published var lastRunCommandID: UUID?
    @Published private(set) var runningCommands: [RunningCommandRecord] = []
    @Published private(set) var runtimeFingerprints: [String: CommandRuntimeFingerprint] = [:]
    @Published private(set) var isRefreshingRunningCommands: Bool = false
    @Published private(set) var stoppingCommandIDs: Set<UUID> = []
    @Published private(set) var isStoppingAllCommands: Bool = false

    private let runner = CommandRunner()
    private let runningMonitor = RunningCommandMonitor()
    private let runningQueue = DispatchQueue(label: "CommandDash.running-monitor", qos: .userInitiated)
    private let commandsFileURL: URL
    private let tabsFileURL: URL
    private let runtimeFingerprintsFileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaults = UserDefaults.standard
    private let selectedTabKey = "CommandDash.selectedTab"
    private var launchHints: [UUID: RunningLaunchHint] = [:]

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CommandDash", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.commandsFileURL = dir.appendingPathComponent("commands.json")
        self.tabsFileURL = dir.appendingPathComponent("tabs.json")
        self.runtimeFingerprintsFileURL = dir.appendingPathComponent("runtime_fingerprints.json")
        load()
        loadTabs()
        loadRuntimeFingerprints()
        repairTabsFromCommandsIfNeeded()
        refreshRunningCommands()
    }

    func addCommand(_ item: CommandItem) {
        var normalized = item

        if normalized.category == Self.allTabName {
            normalized.category = nil
        }

        if let category = normalized.category, !tabs.contains(category) {
            tabs.append(category)
            saveTabs()
        }

        if normalized.kind == .file {
            let exists = commands.contains { $0.kind == .file && $0.command == normalized.command }
            if exists { return }
        }
        commands.append(normalized)
        saveCommands()
        refreshRunningCommands()
    }

    func removeCommand(commandID: UUID) {
        if let command = commands.first(where: { $0.id == commandID }) {
            let key = normalizedCommandPath(command.command)
            runtimeFingerprints.removeValue(forKey: key)
            saveRuntimeFingerprints()
        }
        launchHints.removeValue(forKey: commandID)
        stoppingCommandIDs.remove(commandID)
        commands.removeAll(where: { $0.id == commandID })
        saveCommands()
        refreshRunningCommands()
    }

    func renameCommand(commandID: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = commands.firstIndex(where: { $0.id == commandID }) else { return }
        commands[index].name = trimmed
        saveCommands()
        refreshRunningCommands()
    }

    func updateCommandIcon(commandID: UUID, emoji: String?, gradientID: String?) {
        guard let index = commands.firstIndex(where: { $0.id == commandID }) else { return }
        commands[index].iconEmoji = normalizedEmoji(emoji)
        commands[index].iconGradientID = gradientID
        saveCommands()
    }

    func clearCommands() {
        commands.removeAll()
        runtimeFingerprints.removeAll()
        launchHints.removeAll()
        stoppingCommandIDs.removeAll()
        isStoppingAllCommands = false
        lastRunCommandID = nil
        saveCommands()
        saveRuntimeFingerprints()
        refreshRunningCommands()
    }

    func addTab(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != Self.allTabName else { return nil }

        if let existing = tabs.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }

        tabs.append(trimmed)
        saveTabs()
        return trimmed
    }

    func removeTab(name: String) {
        guard name != Self.allTabName else { return }
        guard tabs.contains(name) else { return }

        tabs.removeAll { $0 == name }
        let removedCommands = commands.filter { $0.category == name }
        commands.removeAll { $0.category == name }
        for command in removedCommands {
            runtimeFingerprints.removeValue(forKey: normalizedCommandPath(command.command))
            launchHints.removeValue(forKey: command.id)
            stoppingCommandIDs.remove(command.id)
        }

        if defaults.string(forKey: selectedTabKey) == name {
            defaults.removeObject(forKey: selectedTabKey)
        }

        saveTabs()
        saveCommands()
        saveRuntimeFingerprints()
        refreshRunningCommands()
    }

    func preferredTabForLaunch() -> String {
        if let saved = defaults.string(forKey: selectedTabKey), tabs.contains(saved) {
            return saved
        }
        if let first = tabs.first {
            return first
        }
        return Self.allTabName
    }

    func rememberSelectedTab(_ tab: String) {
        if tab == Self.allTabName { return }
        defaults.set(tab, forKey: selectedTabKey)
    }

    func appendConsole(_ text: String) {
        DispatchQueue.main.async {
            self.consoleText.append(text)
        }
    }

    func clearConsole() {
        consoleText = ""
    }

    func refreshRunningCommands(showLoading: Bool = false) {
        if showLoading {
            DispatchQueue.main.async {
                self.isRefreshingRunningCommands = true
            }
        }

        let snapshot = commands
        let fingerprintSnapshot = runtimeFingerprints
        let launchSnapshot = launchHints
        runningQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runningMonitor.scan(
                commands: snapshot,
                fingerprints: fingerprintSnapshot,
                launchHints: launchSnapshot
            )
            DispatchQueue.main.async {
                self.runningCommands = result.records
                self.mergeRuntimeFingerprints(result.learnedFingerprints)
                self.reconcileLaunchHints(with: result.records)
                self.reconcileStoppingState(with: result.records)
                if showLoading {
                    self.isRefreshingRunningCommands = false
                }
            }
        }
    }

    func stopRunningCommand(_ record: RunningCommandRecord) {
        guard !isStoppingAllCommands else { return }
        if stoppingCommandIDs.contains(record.commandID) { return }

        stoppingCommandIDs.insert(record.commandID)

        let snapshot = commands
        let fingerprintSnapshot = runtimeFingerprints
        let launchSnapshot = launchHints
        let recordsSnapshot = runningCommands
        runningQueue.async { [weak self] in
            guard let self else { return }
            let safeRecord = self.safeSingleStopRecord(for: record, allRecords: recordsSnapshot)
            self.runningMonitor.stop(safeRecord)

            var result = self.runningMonitor.scan(
                commands: snapshot,
                fingerprints: fingerprintSnapshot,
                launchHints: launchSnapshot
            )
            var attempts = 0
            while attempts < 18 && result.records.contains(where: { $0.commandID == record.commandID }) {
                usleep(280_000)
                result = self.runningMonitor.scan(
                    commands: snapshot,
                    fingerprints: fingerprintSnapshot,
                    launchHints: launchSnapshot
                )
                attempts += 1
            }

            let stillRunning = result.records.contains(where: { $0.commandID == record.commandID })
            DispatchQueue.main.async {
                self.runningCommands = result.records
                self.mergeRuntimeFingerprints(result.learnedFingerprints)
                self.reconcileLaunchHints(with: result.records)
                if !stillRunning {
                    self.stoppingCommandIDs.remove(record.commandID)
                }
                self.reconcileStoppingState(with: result.records)
            }
        }
    }

    func stopAllRunningCommands() {
        let recordsSnapshot = runningCommands
        guard !recordsSnapshot.isEmpty else { return }
        guard !isStoppingAllCommands else { return }

        isStoppingAllCommands = true
        stoppingCommandIDs.formUnion(recordsSnapshot.map(\.commandID))

        let commandSnapshot = commands
        let fingerprintSnapshot = runtimeFingerprints
        let launchSnapshot = launchHints

        runningQueue.async { [weak self] in
            guard let self else { return }

            for record in recordsSnapshot {
                self.runningMonitor.stop(record)
            }

            var result = self.runningMonitor.scan(
                commands: commandSnapshot,
                fingerprints: fingerprintSnapshot,
                launchHints: launchSnapshot
            )
            var attempts = 0
            while attempts < 26 && !result.records.isEmpty {
                usleep(320_000)
                result = self.runningMonitor.scan(
                    commands: commandSnapshot,
                    fingerprints: fingerprintSnapshot,
                    launchHints: launchSnapshot
                )
                attempts += 1
            }

            DispatchQueue.main.async {
                self.runningCommands = result.records
                self.mergeRuntimeFingerprints(result.learnedFingerprints)
                self.reconcileLaunchHints(with: result.records)
                self.isStoppingAllCommands = false
                self.reconcileStoppingState(with: result.records)
            }
        }
    }

    func run(command: CommandItem) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        appendConsole("\n[\(timestamp)] $ \(command.command)\n")
        isRunning = true
        lastRunCommandID = command.id
        refreshRunningCommands()
        let launchEnvironment = markerEnvironment(for: command)

        if command.kind == .file {
            let isApplication = URL(fileURLWithPath: command.command).pathExtension.lowercased() == "app"
            runner.run(
                executable: isApplication ? "/usr/bin/open" : "/bin/zsh",
                arguments: [command.command],
                environment: launchEnvironment,
                onStart: { [weak self] pid in
                    self?.registerLaunchHint(for: command.id, processID: pid)
                },
                onOutput: { [weak self] output in
                    self?.appendConsole(output)
                },
                onComplete: { [weak self] status in
                let endStamp = ISO8601DateFormatter().string(from: Date())
                self?.appendConsole("[\(endStamp)] exit \(status)\n")
                DispatchQueue.main.async {
                    self?.isRunning = false
                    self?.refreshRunningCommands()
                }
                }
            )
            return
        }

        runner.run(
            command: command.command,
            environment: launchEnvironment,
            onStart: { [weak self] pid in
                self?.registerLaunchHint(for: command.id, processID: pid)
            },
            onOutput: { [weak self] output in
                self?.appendConsole(output)
            },
            onComplete: { [weak self] status in
            let endStamp = ISO8601DateFormatter().string(from: Date())
            self?.appendConsole("[\(endStamp)] exit \(status)\n")
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.refreshRunningCommands()
            }
            }
        )
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: commandsFileURL.path) else {
            commands = []
            saveCommands()
            return
        }
        do {
            let data = try Data(contentsOf: commandsFileURL)
            if let decoded = try? decoder.decode([CommandItem].self, from: data) {
                commands = decoded
                return
            }
            let decodedGroups = try decoder.decode([CommandGroup].self, from: data)
            commands = decodedGroups.flatMap { $0.commands }
            saveCommands()
        } catch {
            commands = []
        }
    }

    private func loadTabs() {
        guard FileManager.default.fileExists(atPath: tabsFileURL.path) else {
            tabs = []
            saveTabs()
            return
        }

        do {
            let data = try Data(contentsOf: tabsFileURL)
            let decoded = try decoder.decode([String].self, from: data)
            tabs = sanitizeTabs(decoded)
        } catch {
            tabs = []
        }
    }

    private func loadRuntimeFingerprints() {
        guard FileManager.default.fileExists(atPath: runtimeFingerprintsFileURL.path) else {
            runtimeFingerprints = [:]
            saveRuntimeFingerprints()
            return
        }

        do {
            let data = try Data(contentsOf: runtimeFingerprintsFileURL)
            runtimeFingerprints = try decoder.decode([String: CommandRuntimeFingerprint].self, from: data)
        } catch {
            runtimeFingerprints = [:]
        }
    }

    private func repairTabsFromCommandsIfNeeded() {
        let categories = commands.compactMap { command -> String? in
            guard let value = command.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value != Self.allTabName else { return nil }
            return value
        }

        var changed = false
        for category in categories where !tabs.contains(category) {
            tabs.append(category)
            changed = true
        }

        if changed {
            saveTabs()
        }
    }

    private func sanitizeTabs(_ values: [String]) -> [String] {
        var result: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != Self.allTabName else { continue }
            guard !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
            result.append(value)
        }
        return result
    }

    private func normalizedEmoji(_ input: String?) -> String? {
        guard let input else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    private func markerEnvironment(for command: CommandItem) -> [String: String] {
        var env: [String: String] = [
            "COMMANDDASH_RUN_ID": UUID().uuidString.lowercased(),
            "COMMANDDASH_COMMAND_ID": command.id.uuidString.lowercased()
        ]

        if command.kind == .file {
            let normalizedPath = normalizedCommandPath(command.command)
            if !normalizedPath.isEmpty {
                let encoded = Data(normalizedPath.utf8).base64EncodedString()
                env["COMMANDDASH_COMMAND_PATH_B64"] = encoded
            }
        }

        return env
    }

    private func registerLaunchHint(for commandID: UUID, processID: Int32) {
        let pgid = getpgid(processID)
        let safeGroupID = pgid > 1 ? pgid : processID
        let hint = RunningLaunchHint(
            pid: processID,
            processGroupID: safeGroupID,
            startedAt: Date()
        )

        DispatchQueue.main.async {
            self.launchHints[commandID] = hint
            self.refreshRunningCommands()
        }
    }

    private func reconcileLaunchHints(with records: [RunningCommandRecord]) {
        let now = Date()
        let runningCommandIDs = Set(records.map(\.commandID))
        launchHints = launchHints.filter { commandID, hint in
            if runningCommandIDs.contains(commandID) {
                return true
            }
            return now.timeIntervalSince(hint.startedAt) < 600
        }
    }

    private func reconcileStoppingState(with records: [RunningCommandRecord]) {
        let runningIDs = Set(records.map(\.commandID))
        stoppingCommandIDs = stoppingCommandIDs.intersection(runningIDs)
    }

    private func safeSingleStopRecord(
        for record: RunningCommandRecord,
        allRecords: [RunningCommandRecord]
    ) -> RunningCommandRecord {
        let otherPIDs = Set(
            allRecords
                .filter { $0.commandID != record.commandID }
                .flatMap(\.processIDs)
        )

        let exclusivePIDs = record.processIDs.filter { !otherPIDs.contains($0) }
        let targetPIDs = exclusivePIDs.isEmpty ? record.processIDs : exclusivePIDs

        return RunningCommandRecord(
            id: record.id,
            commandID: record.commandID,
            commandName: record.commandName,
            sourceTag: record.sourceTag,
            pid: record.pid,
            processGroupID: nil,
            processIDs: targetPIDs,
            ports: record.ports,
            uptime: record.uptime,
            stopStrategy: .pidList
        )
    }

    private func normalizedCommandPath(_ rawPath: String) -> String {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rawPath }
        return URL(fileURLWithPath: rawPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func mergeRuntimeFingerprints(_ incoming: [String: CommandRuntimeFingerprint]) {
        guard !incoming.isEmpty else { return }

        var changed = false

        for (rawPath, value) in incoming {
            let key = normalizedCommandPath(rawPath)
            if var current = runtimeFingerprints[key] {
                let mergedPorts = Array(Set(current.ports).union(value.ports)).sorted()
                let mergedHints = Array(Set(current.pathHints).union(value.pathHints)).sorted { $0.count > $1.count }
                let limitedHints = Array(mergedHints.prefix(24))

                if current.ports != mergedPorts || current.pathHints != limitedHints {
                    current.ports = mergedPorts
                    current.pathHints = limitedHints
                    current.updatedAt = max(current.updatedAt, value.updatedAt)
                    runtimeFingerprints[key] = current
                    changed = true
                }
            } else {
                var normalized = value
                normalized.commandPath = key
                normalized.pathHints = Array(Set(normalized.pathHints)).sorted { $0.count > $1.count }
                normalized.pathHints = Array(normalized.pathHints.prefix(24))
                normalized.ports = Array(Set(normalized.ports)).sorted()
                runtimeFingerprints[key] = normalized
                changed = true
            }
        }

        if changed {
            saveRuntimeFingerprints()
        }
    }

    private func saveCommands() {
        do {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(commands)
            try data.write(to: commandsFileURL)
        } catch {
            // If saving fails, keep in-memory state.
        }
    }

    private func saveTabs() {
        do {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tabs)
            try data.write(to: tabsFileURL)
        } catch {
            // If saving fails, keep in-memory state.
        }
    }

    private func saveRuntimeFingerprints() {
        do {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(runtimeFingerprints)
            try data.write(to: runtimeFingerprintsFileURL)
        } catch {
            // If saving fails, keep in-memory state.
        }
    }
}
