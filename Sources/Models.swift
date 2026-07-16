import Foundation

enum CommandKind: String, Codable {
    case shell
    case file
}

struct CommandItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var command: String
    var kind: CommandKind
    var category: String?
    var iconEmoji: String?
    var iconGradientID: String?

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        kind: CommandKind = .shell,
        category: String? = nil,
        iconEmoji: String? = nil,
        iconGradientID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.kind = kind
        self.category = category
        self.iconEmoji = iconEmoji
        self.iconGradientID = iconGradientID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case kind
        case category
        case iconEmoji
        case iconGradientID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        kind = (try? container.decode(CommandKind.self, forKey: .kind)) ?? .shell
        category = try? container.decode(String.self, forKey: .category)
        iconEmoji = try? container.decode(String.self, forKey: .iconEmoji)
        iconGradientID = try? container.decode(String.self, forKey: .iconGradientID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(kind, forKey: .kind)
        try container.encode(category, forKey: .category)
        try container.encode(iconEmoji, forKey: .iconEmoji)
        try container.encode(iconGradientID, forKey: .iconGradientID)
    }
}

struct CommandGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var commands: [CommandItem]

    init(id: UUID = UUID(), name: String, commands: [CommandItem] = []) {
        self.id = id
        self.name = name
        self.commands = commands
    }
}

enum RunningCommandStopStrategy: String, Hashable {
    case processGroup
    case pidList
}

struct RunningCommandRecord: Identifiable, Hashable {
    let id: UUID
    let commandID: UUID
    let commandName: String
    let sourceTag: String
    let pid: Int32
    let processGroupID: Int32?
    let processIDs: [Int32]
    let ports: [Int]
    let uptime: String
    let stopStrategy: RunningCommandStopStrategy
}

struct CommandRuntimeFingerprint: Codable, Hashable {
    var commandPath: String
    var ports: [Int]
    var pathHints: [String]
    var updatedAt: Date
}

struct RunningLaunchHint: Hashable {
    let pid: Int32
    let processGroupID: Int32
    let startedAt: Date
}
