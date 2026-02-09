import SwiftUI

extension Color {
    // Sempara Brand Colors
    static let semparaPrimary = Color(hex: "1976D2")
    static let semparaPrimaryDark = Color(hex: "1565C0")
    static let semparaPrimaryLight = Color(hex: "42A5F5")

    static let semparaSecondary = Color(hex: "FF9800")
    static let semparaSecondaryDark = Color(hex: "F57C00")

    // Status Colors
    static let statusConnected = Color(hex: "4CAF50")
    static let statusConnecting = Color(hex: "FFC107")
    static let statusDisconnected = Color(hex: "F44336")
    static let statusMuted = Color(hex: "9E9E9E")

    // PTT Button Colors
    static let pttInactive = Color(hex: "1976D2")
    static let pttActive = Color(hex: "B71C1C")
    static let pttActiveRipple = Color(hex: "D32F2F")

    // Dispatcher Colors
    static let dispatcherOrange = Color(hex: "F57C00")

    // Alarm Colors
    static let alarmRed = Color(hex: "D32F2F")
    static let alarmRedDark = Color(hex: "B71C1C")

    // Helper initializer for hex colors
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
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
