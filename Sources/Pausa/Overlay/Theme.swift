import SwiftUI

/// Single app-wide accent. Use this, never a literal color.
enum Theme {
    static let accent = Color(red: 0x7F / 255, green: 0xC8 / 255, blue: 0xA9 / 255) // #7FC8A9
    static let accentNS = NSColor(red: 0x7F / 255, green: 0xC8 / 255, blue: 0xA9 / 255, alpha: 1)
}
