import SwiftUI

enum TagColor {
    /// 24 visually-tuned hue slots (degrees), with lightness/saturation deltas to compensate
    /// for HSL's perceptual non-uniformity (yellows look brighter than blues).
    private static let palette: [(hue: Int, lBoost: Int, sBoost: Int)] = [
        (0,0,0),(15,0,-2),(30,-3,-3),(45,-5,-5),(60,-8,-8),(75,-5,-5),
        (90,-3,-3),(110,-2,-2),(130,0,0),(150,0,0),(170,0,2),(190,0,4),
        (210,2,4),(225,3,4),(275,4,4),(290,4,3),(305,3,2),(320,2,0),
        (335,0,0),(350,0,0),(200,1,3),(240,4,3),(120,-1,-1),(160,0,0)
    ]

    static func slot(for tag: String) -> (hue: Double, sat: Double, light: Double, fgSat: Double, fgLight: Double) {
        let s = tag.lowercased()
        var h1: UInt32 = 0x811c9dc5
        for byte in s.utf8 {
            h1 ^= UInt32(byte)
            h1 = h1 &* 0x01000193
        }
        var h2: UInt32 = 5381
        for byte in s.utf8.reversed() {
            h2 = (h2 &<< 5) &+ h2 &+ UInt32(byte)
        }
        var mixed = h1 ^ (h2 &* 0x9e3779b1)
        mixed = (mixed ^ (mixed >> 16)) &* 0x85ebca6b
        mixed = (mixed ^ (mixed >> 13)) &* 0xc2b2ae35
        mixed = mixed ^ (mixed >> 16)

        let slot = palette[Int(mixed) % palette.count]
        let hueShift = Int((h2 >> 4) % 11) - 5
        let satJitter = Double(Int((h2 >> 12) % 9) - 4)
        let lightJitter = Double(Int((h2 >> 20) % 7) - 3)
        let hue = Double((slot.hue + hueShift + 360) % 360)

        let bgSat = max(40.0, 72.0 + Double(slot.sBoost) + satJitter)
        let bgLight = min(96.0, 91.0 + Double(slot.lBoost) + lightJitter)
        let fgSat = max(35.0, 60.0 + Double(slot.sBoost) + satJitter)
        let fgLight = max(20.0, 30.0 + Double(slot.lBoost) + lightJitter)
        return (hue: hue / 360.0, sat: bgSat / 100.0, light: bgLight / 100.0,
                fgSat: fgSat / 100.0, fgLight: fgLight / 100.0)
    }

    static func background(for tag: String, dark: Bool = false) -> Color {
        let s = slot(for: tag)
        if dark {
            return Color(hue: s.hue, saturation: max(0.2, s.sat * 0.5), brightness: 0.24)
        }
        return Color(hue: s.hue, saturation: s.sat, brightness: s.light)
    }

    static func foreground(for tag: String, dark: Bool = false) -> Color {
        let s = slot(for: tag)
        if dark {
            return Color(hue: s.hue, saturation: 0.7, brightness: 0.78)
        }
        return Color(hue: s.hue, saturation: s.fgSat, brightness: s.fgLight)
    }
}

/// Convenience: returns a tag pill view that adapts to color scheme.
struct TagPill: View {
    let tag: String
    var active: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Text(tag)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(active ? Color.accentColor : TagColor.background(for: tag, dark: dark))
            .foregroundColor(active ? .white : TagColor.foreground(for: tag, dark: dark))
            .clipShape(Capsule())
    }
}
