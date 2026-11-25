import Foundation

/// The menu's choices, kept in Dictate's user defaults.
enum Settings {
    /// The sounds macOS ships in /System/Library/Sounds, offered for the start and finish chimes.
    static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    private static var store: UserDefaults { .standard }

    static var preview: Bool {
        get { store.object(forKey: "preview") as? Bool ?? true }
        set { store.set(newValue, forKey: "preview") }
    }

    /// The start chime's name, or "" for none.
    static var startSound: String {
        get { store.string(forKey: "sound.start") ?? "Pop" }
        set { store.set(newValue, forKey: "sound.start") }
    }

    /// The finish chime's name, or "" for none.
    static var finishSound: String {
        get { store.string(forKey: "sound.finish") ?? "Bottle" }
        set { store.set(newValue, forKey: "sound.finish") }
    }
}
