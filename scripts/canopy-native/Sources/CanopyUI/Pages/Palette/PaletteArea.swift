import CanopyCore
import SwiftUI

/// The shell's overlays brought to v2: the space menu with its finds (Menu.swift), the `?` key
/// sheet (KeySheet.swift), the picker (Picker.swift) and which-key (WhichKey.swift). This area
/// registers the layers' own keys: the menu's (its filter takes every other key) and the sheet's
/// scroll. The picker's keys are the shell's (`picker.*`).
enum PaletteArea: PageArea {
    static let name = "palette"

    static func install(_ app: AppModel) {
        let menu = app.state { MenuState() }
        let sheet = app.state { SheetState() }
        let r = app.registry
        r.register(Command(id: "menu.next", title: "Next in the menu", scope: .global, keys: ["down", "C-n", "C-j", "tab"], modes: [.menu], quiet: true,
                           local: { [weak app] _, _ in if let app { menu.index = min(max(0, menu.rows(app).count - 1), menu.index + 1) } }))
        r.register(Command(id: "menu.prev", title: "Previous in the menu", scope: .global, keys: ["up", "C-p", "C-k"], modes: [.menu], quiet: true,
                           local: { _, _ in menu.index = max(0, menu.index - 1) }))
        r.register(Command(id: "menu.run", title: "Run the highlighted command", scope: .global, keys: ["ret"], modes: [.menu], quiet: true,
                           local: { [weak app] _, _ in if let app { menu.run(app) } }))

        r.register(Command(id: "sheet.down", title: "Scroll the key sheet down", scope: .global, keys: ["j", "down"], modes: [.sheet], quiet: true,
                           local: { [weak app] _, _ in if let app { sheet.move(1, app) } }))
        r.register(Command(id: "sheet.up", title: "Scroll the key sheet up", scope: .global, keys: ["k", "up"], modes: [.sheet], quiet: true,
                           local: { [weak app] _, _ in if let app { sheet.move(-1, app) } }))
        r.register(Command(id: "sheet.halfdown", title: "Scroll the key sheet down a page", scope: .global, keys: ["C-d"], modes: [.sheet], quiet: true,
                           local: { [weak app] _, _ in if let app { sheet.move(12, app) } }))
        r.register(Command(id: "sheet.halfup", title: "Scroll the key sheet up a page", scope: .global, keys: ["C-u"], modes: [.sheet], quiet: true,
                           local: { [weak app] _, _ in if let app { sheet.move(-12, app) } }))
    }
}
