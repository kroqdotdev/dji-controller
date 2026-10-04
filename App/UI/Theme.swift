import SwiftUI

/// The console palette. One accent (red) for the two "hot" states: muted and recording.
/// Meter green and amber are data colours, not accents.
enum Console {
    static let background = Color(hex: 0x1F2428)
    static let panel = Color(hex: 0x2B3136)
    static let well = Color(hex: 0x171B1E)
    static let engraving = Color(hex: 0x9AA4AB)
    static let silk = Color(hex: 0xE6E9EB)
    static let tape = Color(hex: 0xECEAE2)
    static let ink = Color(hex: 0x1D2024)
    static let red = Color(hex: 0xE5484D)
    static let green = Color(hex: 0x4CC38A)
    static let amber = Color(hex: 0xF2B33D)

    /// Every tape label has the same height, whatever its text, so strips line up.
    static let tapeHeight: CGFloat = 36

    /// Radius rule: containers 10, keys 6, tape 2.
    enum Radius {
        static let container: CGFloat = 10
        static let key: CGFloat = 6
        static let tape: CGFloat = 2
    }
}

extension TapeColor {
    var fill: Color {
        switch self {
        case .white: Console.tape
        case .yellow: Color(hex: 0xF2D65E)
        case .orange: Color(hex: 0xF4A964)
        case .pink: Color(hex: 0xF2A0B4)
        case .green: Color(hex: 0x93D6A4)
        case .blue: Color(hex: 0x93BDF4)
        case .violet: Color(hex: 0xBDAAF2)
        }
    }
}

extension Font {
    /// Marker on console tape.
    static let tape = Font.system(size: 22, weight: .heavy).width(.compressed)
    static let stripLabel = Font.system(size: 12, weight: .semibold).width(.condensed)
    static let value = Font.system(size: 15, weight: .semibold).monospacedDigit()
    static let scale = Font.system(size: 9, weight: .medium).monospacedDigit()
    static let timer = Font.system(size: 28, weight: .semibold).monospacedDigit()
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A console key: flat when off, backlit when on.
struct KeyStyle: ButtonStyle {
    var lit = false
    var litColor = Console.silk
    var litText = Console.ink
    /// Small shortcut legend printed in the key's corner.
    var legend: String?
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(lit ? litText : Console.silk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 4 : 10)
            .overlay(alignment: .trailing) {
                if let legend {
                    Text(legend)
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle((lit ? litText : Console.silk).opacity(0.6))
                        .padding(.trailing, 9)
                }
            }
            .background(RoundedRectangle(cornerRadius: Console.Radius.key).fill(lit ? litColor : Console.well))
            .overlay(RoundedRectangle(cornerRadius: Console.Radius.key).strokeBorder(Console.silk.opacity(lit ? 0 : 0.14)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Rectangle())
    }
}
