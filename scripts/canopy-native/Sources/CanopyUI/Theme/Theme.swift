import AppKit
import CoreText
import SwiftUI

/// The design tokens of viewer-solid/src/v2/tokens.css (the "unlit ledger"), as colors and fonts.
/// `dark` is the web app's palette value-for-value; `light` is its daylight counterpart. Read it
/// in views with `@Environment(\.theme) var theme`.
public struct Theme: Equatable, Sendable {
    public var vellumNight: Color
    public var vellumRaise: Color
    public var vellumEdge: Color
    public var ink: Color
    public var inkDim: Color
    public var inkFaint: Color
    public var goldLeaf: Color
    public var goldDeep: Color
    public var goldWash: Color
    public var ember: Color
    public var emberWash: Color
    public var patina: Color
    public var rule: Color
    public var add: Color
    public var addBg: Color
    public var del: Color
    public var delBg: Color
    public var diffInk: Color
    public var diffBg: Color

    public static let dark = Theme(
        vellumNight: .hex(0x14110A), vellumRaise: .hex(0x1C180F), vellumEdge: .hex(0x221C11),
        ink: .hex(0xE8DCC4), inkDim: .hex(0x9A8E78), inkFaint: .hex(0x847A63),
        goldLeaf: .hex(0xE6B64E), goldDeep: .hex(0x6E521D), goldWash: .hex(0xE6B64E, 0.08),
        ember: .hex(0xD2732A), emberWash: .hex(0xD2732A, 0.12), patina: .hex(0x7FA093), rule: .hex(0x3D3421),
        add: .hex(0x8FAE7A), addBg: .hex(0x8FAE7A, 0.09), del: .hex(0xC87A55), delBg: .hex(0xC87A55, 0.09),
        diffInk: .hex(0xECD35A), diffBg: .hex(0x0A0A0D))

    public static let light = Theme(
        vellumNight: .hex(0xF6F0E2), vellumRaise: .hex(0xFFFAF0), vellumEdge: .hex(0xEAE1CD),
        ink: .hex(0x2A2418), inkDim: .hex(0x625843), inkFaint: .hex(0x7E735C),
        goldLeaf: .hex(0x93680F), goldDeep: .hex(0xD9B56A), goldWash: .hex(0x93680F, 0.08),
        ember: .hex(0xB0521A), emberWash: .hex(0xB0521A, 0.10), patina: .hex(0x4C7062), rule: .hex(0xD6CBB2),
        add: .hex(0x4B7536), addBg: .hex(0x4B7536, 0.09), del: .hex(0xA34E2B), delBg: .hex(0xA34E2B, 0.09),
        diffInk: .hex(0x6E5A00), diffBg: .hex(0xFBF7EC))

    public static func forScheme(_ s: ColorScheme) -> Theme { s == .dark ? .dark : .light }

    // ── type: v2.css body is Plex Mono 13/1.6; the display face is Fraunces italic ──

    public static let bodySize: CGFloat = 13

    /// Each Plex weight is its own family in the subset files, so faces are named by PostScript name.
    public static func mono(_ size: CGFloat = bodySize, weight: Font.Weight = .regular) -> Font {
        let name = weight == .semibold || weight == .bold || weight == .heavy || weight == .black ? "IBMPlexMono-SemiBold"
            : weight == .medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return Fonts.registered ? .custom(name, size: size) : .system(size: size, weight: weight, design: .monospaced)
    }

    /// Fraunces italic (SOFT 50, WONK 1), the display face of the crumbs and page titles.
    public static func display(_ size: CGFloat = 17) -> Font {
        Fonts.registered ? .custom("FrauncesSoftWonky-Italic", size: size) : .system(size: size, design: .serif).italic()
    }

    public static func nsMono(_ size: CGFloat = bodySize, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight >= .semibold ? "IBMPlexMono-SemiBold" : weight >= .medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

public extension Color {
    static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: alpha)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

public extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The bundled faces (OFL: Fraunces, IBM Plex Mono), the web app's latin subsets as woff2 —
/// CoreText registers woff2 directly. Registered for this process at launch.
public enum Fonts {
    nonisolated(unsafe) public private(set) static var registered = false

    public static func register() {
        guard !registered, let dir = directory() else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var ok = 0
        for f in files where f.pathExtension == "woff2" {
            var err: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err) { ok += 1 }
        }
        registered = ok > 0
    }

    /// The resource bundle, wherever it sits: inside the .app's Resources (the launcher copies it
    /// there), beside the executable, or in SwiftPM's build directory.
    static func directory() -> URL? {
        let name = "canopy-native_CanopyUI.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0 }
        for c in candidates {
            let fonts = c.appendingPathComponent("Fonts")
            if FileManager.default.fileExists(atPath: fonts.path) { return fonts }
            let flat = c.appendingPathComponent("Contents/Resources/Fonts")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }
}
