import SwiftUI

struct Theme {
    static let black = Color(hex: "000000")
    static let nearBlack = Color(hex: "1D1D1F")
    static let lightGray = Color(hex: "F5F5F7")
    static let white = Color(hex: "FFFFFF")
    static let appleBlue = Color(hex: "0071E3")
    static let linkBlue = Color(hex: "0066CC")
    static let brightBlue = Color(hex: "2997FF")
    static let darkSurface = Color(hex: "272729")
    static let darkSurfaceElevated = Color(hex: "1F2023")
    static let glassStroke = Color.white.opacity(0.45)
    static let glassShadow = Color.black.opacity(0.16)
    static let panelTint = Color.white.opacity(0.36)

    static let background = Color.clear
    static let panel = Color.white.opacity(0.18)
    static let card = white
    static let secondaryText = Color.black.opacity(0.8)
    static let tertiaryText = Color.black.opacity(0.48)
    static let quaternaryText = Color.black.opacity(0.34)

    static let headingFont = Font.system(size: 21, weight: .semibold, design: .default)
    static let bodyFont = Font.system(size: 17, weight: .regular, design: .default)
    static let captionFont = Font.system(size: 14, weight: .regular, design: .default)
    static let microFont = Font.system(size: 12, weight: .regular, design: .default)
    static let monoFont = Font.system(size: 12, weight: .regular, design: .monospaced)

    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 11
    static let radiusLarge: CGFloat = 12
    static let radiusPill: CGFloat = 980

    static let cardShadow = Color.black.opacity(0.22)
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: value).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch value.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
