import Foundation
import Darwin

struct RunningCommandScanResult {
    let records: [RunningCommandRecord]
    let learnedFingerprints: [String: CommandRuntimeFingerprint]
}

final class RunningCommandMonitor {
    private struct ProcessRow {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        let etime: String
        let command: String
    }

    private struct ScriptHints {
        var pathHints: [String]
        var ports: [Int]
    }

    func scan(
        commands: [CommandItem],
        fingerprints: [String: CommandRuntimeFingerprint],
        launchHints: [UUID: RunningLaunchHint]
    ) -> RunningCommandScanResult {
        let processRows = fetchProcessRows()
        let listeningPorts = fetchListeningPortsByPID()
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let byPID = Dictionary(uniqueKeysWithValues: processRows.map { ($0.pid, $0) })

        var records: [RunningCommandRecord] = []
        var learned: [String: CommandRuntimeFingerprint] = [:]

        for command in commands where isTrackableCommand(command) {
            let commandPath = normalizePath(command.command)
            let fingerprint = fingerprints[commandPath] ?? fingerprints[command.command]
            let hints = buildHints(for: command, fingerprint: fingerprint)
            let directRows = processRows.filter { $0.command.contains(command.command) && $0.pid != selfPID }

            var matched = Set<Int32>()
            var sourceTag = ""
            var strategy: RunningCommandStopStrategy = .pidList
            var groupID: Int32?
            var representative: ProcessRow?

            let launchMatches = launchHints[command.id].map { hint in
                matchByLaunchHint(hint, in: processRows)
            } ?? []

            if !launchMatches.isEmpty {
                matched = launchMatches
                sourceTag = "启动会话"
                strategy = .processGroup
                representative = pickRepresentative(from: matched, byPID: byPID)
                groupID = representative?.pgid
            } else if !directRows.isEmpty {
                let groups = Set(directRows.map(\.pgid))
                for row in processRows where groups.contains(row.pgid) {
                    matched.insert(row.pid)
                }
                sourceTag = "脚本进程组"
                strategy = .processGroup
                groupID = directRows.sorted(by: { $0.pid < $1.pid }).first?.pgid
                representative = directRows.sorted(by: { $0.pid < $1.pid }).first
            } else {
                let pathMatches = matchByPaths(hints.pathHints, in: processRows)
                let portMatches = matchByPorts(hints.ports, listeningPorts: listeningPorts)
                if !pathMatches.isEmpty && !portMatches.isEmpty {
                    let intersection = pathMatches.intersection(portMatches)
                    if !intersection.isEmpty {
                        matched = intersection
                        sourceTag = "路径+端口"
                    } else if pathMatches.count <= portMatches.count {
                        matched = pathMatches
                        sourceTag = "路径归因"
                    } else {
                        matched = portMatches
                        sourceTag = "端口归因"
                    }
                } else if !pathMatches.isEmpty {
                    matched = pathMatches
                    sourceTag = "路径归因"
                } else if !portMatches.isEmpty {
                    matched = portMatches
                    sourceTag = "端口归因"
                } else {
                    continue
                }

                if let rep = pickRepresentative(from: matched, byPID: byPID) {
                    representative = rep
                    groupID = rep.pgid
                }
            }

            matched.remove(selfPID)
            if matched.isEmpty { continue }

            if let pgid = groupID, pgid > 1 {
                let groupMembers = processRows.filter { $0.pgid == pgid }.map(\.pid)
                if groupMembers.count <= 36 {
                    matched.formUnion(groupMembers)
                }
            }

            matched.remove(selfPID)
            if matched.isEmpty { continue }

            let resolvedRepresentative = representative ?? pickRepresentative(from: matched, byPID: byPID)
            guard let rep = resolvedRepresentative else { continue }

            let ports = matched
                .compactMap { listeningPorts[$0] }
                .reduce(into: Set<Int>()) { partialResult, set in
                    partialResult.formUnion(set)
                }
                .sorted()

            let entry = RunningCommandRecord(
                id: command.id,
                commandID: command.id,
                commandName: command.name,
                sourceTag: sourceTag,
                pid: rep.pid,
                processGroupID: strategy == .processGroup ? groupID : nil,
                processIDs: matched.sorted(),
                ports: ports,
                uptime: rep.etime,
                stopStrategy: strategy
            )
            records.append(entry)

            let matchedRows = matched.compactMap { byPID[$0] }
            let learnedHints = learnedPathHints(commandPath: commandPath, baseHints: hints.pathHints, matchedRows: matchedRows)
            let learnedPorts = Array(Set(hints.ports).union(ports)).sorted()

            if !learnedHints.isEmpty || !learnedPorts.isEmpty {
                learned[commandPath] = CommandRuntimeFingerprint(
                    commandPath: commandPath,
                    ports: learnedPorts,
                    pathHints: learnedHints,
                    updatedAt: Date()
                )
            }
        }

        let resolvedRecords = resolvePIDConflicts(
            records: records,
            byPID: byPID,
            listeningPorts: listeningPorts
        )

        let sortedRecords = resolvedRecords.sorted { lhs, rhs in
            lhs.commandName.localizedCaseInsensitiveCompare(rhs.commandName) == .orderedAscending
        }

        return RunningCommandScanResult(records: sortedRecords, learnedFingerprints: learned)
    }

    func stop(_ record: RunningCommandRecord) {
        switch record.stopStrategy {
        case .processGroup:
            if let pgid = record.processGroupID, pgid > 1, pgid != getpgrp() {
                terminateProcessGroup(pgid: pgid, fallbackPIDs: record.processIDs)
            } else {
                terminatePIDs(record.processIDs)
            }
        case .pidList:
            terminatePIDs(record.processIDs)
        }
    }

    private func fetchProcessRows() -> [ProcessRow] {
        let output = runCapture(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,pgid=,etime=,command="]
        )

        return output
            .split(separator: "\n")
            .compactMap { rawLine in
                let line = String(rawLine)
                let parts = line.split(
                    maxSplits: 4,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0 == " " || $0 == "\t" }
                )
                guard parts.count == 5,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]),
                      let pgid = Int32(parts[2]) else { return nil }

                let etime = String(parts[3])
                let command = String(parts[4])
                if command.contains("/bin/ps -axo") || command.contains("lsof -nP -iTCP -sTCP:LISTEN") {
                    return nil
                }
                return ProcessRow(pid: pid, ppid: ppid, pgid: pgid, etime: etime, command: command)
            }
    }

    private func fetchListeningPortsByPID() -> [Int32: Set<Int>] {
        let output = runCapture(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        )

        var map: [Int32: Set<Int>] = [:]
        var currentPID: Int32?

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard let first = line.first else { continue }

            if first == "p" {
                currentPID = Int32(line.dropFirst())
                continue
            }

            if first == "n", let pid = currentPID {
                if let port = extractPort(fromLsofNameField: String(line.dropFirst())) {
                    map[pid, default: []].insert(port)
                }
            }
        }

        return map
    }

    private func extractPort(fromLsofNameField field: String) -> Int? {
        let ns = field as NSString
        let pattern = #":([0-9]{2,5})(?:->|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let match = regex.firstMatch(in: field, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let portString = ns.substring(with: match.range(at: 1))
        return Int(portString)
    }

    private func buildHints(for command: CommandItem, fingerprint: CommandRuntimeFingerprint?) -> ScriptHints {
        var pathHints = Set<String>()
        var ports = Set<Int>()

        let normalizedCommandPath = normalizePath(command.command)
        pathHints.insert(normalizedCommandPath)
        let commandDir = URL(fileURLWithPath: normalizedCommandPath).deletingLastPathComponent().path
        if commandDir.count > 1 {
            pathHints.insert(commandDir)
        }

        if let fingerprint {
            fingerprint.pathHints.forEach { pathHints.insert(normalizePath($0)) }
            fingerprint.ports.forEach { ports.insert($0) }
        }

        if FileManager.default.fileExists(atPath: command.command),
           let script = try? String(contentsOfFile: command.command, encoding: .utf8) {
            ports.formUnion(extractIntegers(pattern: #"(?i)\bPORT\s*=\s*['"]?([0-9]{2,5})"#, from: script))
            ports.formUnion(extractIntegers(pattern: #"(?i)\b[A-Z0-9_]*PORT[A-Z0-9_]*\s*=\s*['"]?([0-9]{2,5})"#, from: script))
            ports.formUnion(extractIntegers(pattern: #"(?i)--port\s+['"]?([0-9]{2,5})"#, from: script))
            ports.formUnion(extractIntegers(pattern: #"(?i)localhost[:/]+([0-9]{2,5})"#, from: script))
            ports.formUnion(extractIntegers(pattern: #"(?i)(?:127\.0\.0\.1|0\.0\.0\.0):([0-9]{2,5})"#, from: script))
            ports.formUnion(extractIntegers(pattern: #"(?i)tcp:([0-9]{2,5})"#, from: script))

            let quotedPaths = extractStrings(pattern: #"['"](/[^'"\n]+)['"]"#, from: script)
            quotedPaths.forEach { pathHints.insert(normalizePath($0)) }

            let assignedPaths = extractStrings(
                pattern: #"(?i)\b(?:ROOT|PROJECT_DIR|APP_DIR|WORK_DIR)\s*=\s*([/][^\s#]+)"#,
                from: script
            )
            assignedPaths.forEach { pathHints.insert(normalizePath($0)) }

            let cdPaths = extractStrings(
                pattern: #"(?i)\bcd\s+['"]([^'"]+)['"]"#,
                from: script
            )
            cdPaths.filter { $0.hasPrefix("/") }.forEach { pathHints.insert(normalizePath($0)) }
        }

        let normalized = pathHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isUsefulPathHint($0) }
            .sorted { $0.count > $1.count }

        return ScriptHints(
            pathHints: Array(normalized.prefix(30)),
            ports: ports.sorted()
        )
    }

    private func learnedPathHints(commandPath: String, baseHints: [String], matchedRows: [ProcessRow]) -> [String] {
        var hints = Set(baseHints.map(normalizePath))
        hints.insert(commandPath)
        hints.insert(URL(fileURLWithPath: commandPath).deletingLastPathComponent().path)

        for row in matchedRows {
            for path in extractPathHints(fromCommandLine: row.command) {
                let normalized = normalizePath(path)
                if isUsefulPathHint(normalized) {
                    hints.insert(normalized)
                }
            }
        }

        let ordered = hints
            .filter { isUsefulPathHint($0) }
            .sorted { $0.count > $1.count }

        return Array(ordered.prefix(24))
    }

    private func extractPathHints(fromCommandLine line: String) -> [String] {
        var paths = Set<String>()

        let singleQuoted = extractStrings(pattern: #"'(/[^']+)'"#, from: line)
        singleQuoted.forEach { paths.insert($0) }

        let doubleQuoted = extractStrings(pattern: #"\"(/[^\"]+)\""#, from: line)
        doubleQuoted.forEach { paths.insert($0) }

        let bare = extractStrings(pattern: #"(?<![A-Za-z0-9_])(/[^\s'\";|]+)"#, from: line)
        bare.forEach { paths.insert($0) }

        return paths
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",;")) }
            .filter { !$0.isEmpty }
    }

    private func isUsefulPathHint(_ path: String) -> Bool {
        if path.isEmpty || path == "/" { return false }

        let lower = path.lowercased()
        let blockedPrefixes = [
            "/bin", "/usr/bin", "/usr/sbin", "/usr/lib", "/system",
            "/library", "/private/var", "/var/folders", "/opt/homebrew/cellar"
        ]

        for prefix in blockedPrefixes where lower == prefix || lower.hasPrefix(prefix + "/") {
            return false
        }

        let broadPaths = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path,
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ].compactMap { $0 }
        for broad in broadPaths where path == broad {
            return false
        }

        let components = URL(fileURLWithPath: path).pathComponents
        if components.count <= 3, components.starts(with: ["/", "Volumes"]) {
            return false
        }

        return path.count >= 8
    }

    private func isTrackableCommand(_ command: CommandItem) -> Bool {
        if command.kind == .file {
            return true
        }

        let path = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["command", "sh", "app"].contains(ext) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func resolvePIDConflicts(
        records: [RunningCommandRecord],
        byPID: [Int32: ProcessRow],
        listeningPorts: [Int32: Set<Int>]
    ) -> [RunningCommandRecord] {
        guard records.count > 1 else { return records }

        var owners: [Int32: Int] = [:]
        for index in records.indices {
            for pid in records[index].processIDs {
                guard pid > 1 else { continue }
                if let currentOwner = owners[pid] {
                    let winner = chooseOwnerPID(
                        existingOwner: currentOwner,
                        challenger: index,
                        records: records
                    )
                    owners[pid] = winner
                } else {
                    owners[pid] = index
                }
            }
        }

        var output: [RunningCommandRecord] = []
        output.reserveCapacity(records.count)

        for index in records.indices {
            let record = records[index]
            let keptPIDs = record.processIDs.filter { owners[$0] == index }
            if keptPIDs.isEmpty { continue }

            let keptSet = Set(keptPIDs)
            guard let rep = pickRepresentative(from: keptSet, byPID: byPID) ?? keptSet.compactMap({ byPID[$0] }).sorted(by: { $0.pid < $1.pid }).first else {
                continue
            }

            let ports = keptPIDs
                .compactMap { listeningPorts[$0] }
                .reduce(into: Set<Int>()) { partialResult, set in
                    partialResult.formUnion(set)
                }
                .sorted()

            let processGroupID: Int32? = {
                guard record.stopStrategy == .processGroup else { return nil }
                let pgids = Set(keptPIDs.compactMap { byPID[$0]?.pgid })
                if pgids.count == 1 {
                    return pgids.first
                }
                return nil
            }()

            output.append(
                RunningCommandRecord(
                    id: record.id,
                    commandID: record.commandID,
                    commandName: record.commandName,
                    sourceTag: record.sourceTag,
                    pid: rep.pid,
                    processGroupID: processGroupID,
                    processIDs: keptPIDs.sorted(),
                    ports: ports,
                    uptime: rep.etime,
                    stopStrategy: record.stopStrategy
                )
            )
        }

        return output
    }

    private func chooseOwnerPID(
        existingOwner: Int,
        challenger: Int,
        records: [RunningCommandRecord]
    ) -> Int {
        let existing = records[existingOwner]
        let other = records[challenger]

        let existingScore = sourcePriority(existing.sourceTag)
        let challengerScore = sourcePriority(other.sourceTag)

        if challengerScore > existingScore {
            return challenger
        }
        if existingScore > challengerScore {
            return existingOwner
        }

        if other.processIDs.count < existing.processIDs.count {
            return challenger
        }
        if existing.processIDs.count < other.processIDs.count {
            return existingOwner
        }

        if other.commandName.count < existing.commandName.count {
            return challenger
        }
        return existingOwner
    }

    private func sourcePriority(_ source: String) -> Int {
        switch source {
        case "启动会话":
            return 100
        case "脚本进程组":
            return 90
        case "路径+端口":
            return 82
        case "路径归因":
            return 74
        case "端口归因":
            return 66
        default:
            return 50
        }
    }

    private func matchByLaunchHint(_ hint: RunningLaunchHint, in rows: [ProcessRow]) -> Set<Int32> {
        guard hint.processGroupID > 1 else { return [] }

        var result = Set<Int32>()
        for row in rows where row.pgid == hint.processGroupID || row.pid == hint.pid || row.ppid == hint.pid {
            result.insert(row.pid)
        }
        return result
    }

    private func matchByPaths(_ paths: [String], in rows: [ProcessRow]) -> Set<Int32> {
        var result = Set<Int32>()
        guard !paths.isEmpty else { return result }

        for row in rows {
            for path in paths where row.command.contains(path) {
                result.insert(row.pid)
                break
            }
        }
        return result
    }

    private func matchByPorts(_ ports: [Int], listeningPorts: [Int32: Set<Int>]) -> Set<Int32> {
        guard !ports.isEmpty else { return [] }

        let target = Set(ports)
        var result = Set<Int32>()
        for (pid, listening) in listeningPorts {
            if !target.intersection(listening).isEmpty {
                result.insert(pid)
            }
        }
        return result
    }

    private func pickRepresentative(
        from matched: Set<Int32>,
        byPID: [Int32: ProcessRow]
    ) -> ProcessRow? {
        let rows = matched.compactMap { byPID[$0] }
        guard !rows.isEmpty else { return nil }

        if let root = rows
            .filter({ !matched.contains($0.ppid) })
            .sorted(by: { $0.pid < $1.pid })
            .first {
            return root
        }

        return rows.sorted(by: { $0.pid < $1.pid }).first
    }

    private func terminateProcessGroup(pgid: Int32, fallbackPIDs: [Int32]) {
        let target = -pgid
        _ = kill(target, SIGTERM)
        usleep(550_000)

        let stillAlive = fallbackPIDs.filter { isAlive(pid: $0) }
        if !stillAlive.isEmpty {
            _ = kill(target, SIGKILL)
        }
    }

    private func terminatePIDs(_ pids: [Int32]) {
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let targets = pids.filter { $0 > 1 && $0 != selfPID }
        guard !targets.isEmpty else { return }

        for pid in targets {
            _ = kill(pid, SIGTERM)
        }

        usleep(550_000)

        for pid in targets where isAlive(pid: pid) {
            _ = kill(pid, SIGKILL)
        }
    }

    private func isAlive(pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func extractIntegers(pattern: String, from text: String) -> [Int] {
        let values = extractStrings(pattern: pattern, from: text)
        return values.compactMap { Int($0) }
    }

    private func extractStrings(pattern: String, from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString

        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    private func normalizePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawPath }
        return URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func runCapture(executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
