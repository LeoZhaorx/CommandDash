import SwiftUI

struct CommandIconGradientPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let colors: [Color]

    static let all: [CommandIconGradientPreset] = [
        CommandIconGradientPreset(id: "mist", name: "雾白", colors: [Color(hex: "F8FAFF"), Color(hex: "E3EAF8")]),
        CommandIconGradientPreset(id: "sunset", name: "日落", colors: [Color(hex: "FFB199"), Color(hex: "FF0844")]),
        CommandIconGradientPreset(id: "ocean", name: "海蓝", colors: [Color(hex: "4FACFE"), Color(hex: "00F2FE")]),
        CommandIconGradientPreset(id: "mint", name: "薄荷", colors: [Color(hex: "43E97B"), Color(hex: "38F9D7")]),
        CommandIconGradientPreset(id: "grape", name: "葡萄", colors: [Color(hex: "A18CD1"), Color(hex: "FBC2EB")]),
        CommandIconGradientPreset(id: "sand", name: "沙金", colors: [Color(hex: "F6D365"), Color(hex: "FDA085")]),
        CommandIconGradientPreset(id: "slate", name: "石墨", colors: [Color(hex: "3C3B3F"), Color(hex: "605C3C")]),
        CommandIconGradientPreset(id: "night", name: "夜色", colors: [Color(hex: "141E30"), Color(hex: "243B55")])
    ]

    static var `default`: CommandIconGradientPreset {
        all[0]
    }

    static func byID(_ id: String?) -> CommandIconGradientPreset {
        guard let id, let matched = all.first(where: { $0.id == id }) else {
            return `default`
        }
        return matched
    }

    static func gradient(for id: String?) -> LinearGradient {
        let preset = byID(id)
        return LinearGradient(
            colors: preset.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
