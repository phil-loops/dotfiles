import AppKit
import CanopyCore
import Foundation

/// `--dump`: no window. Hydrate, hold /v2/events for `--dump-wait` seconds, exercise the key
/// engine (`g` → which-key, `g o` / `g f` navigate, j/v/j/j select, esc, `:go dashbord` ret), print the world as JSON on
/// stdout, exit (1 when no `hello` arrived). Nothing is written to the server: telemetry is off,
/// and no command sends a write.
@MainActor
public enum Dump {
    public static func run(_ config: AppConfig) -> Never {
        Log.quiet = true
        Fonts.register()
        guard let port = config.resolvedPort() else {
            print(#"{"error":"no server port: pass --port, or --repo with a running `stack web`"}"#)
            exit(2)
        }
        let app = AppModel(config: config, port: port, telemetry: false)
        var frames: [String: Int] = [:]
        var firstPatch: JSONObject?
        app.stream.onFrame = { f in
            frames[f.event, default: 0] += 1
            if f.event == "patch", firstPatch == nil, var j = f.json {
                j["upserts"] = .object((j["upserts"]?.object ?? [:]).mapValues { .number(Double($0.object?.count ?? 0)) })
                firstPatch = j
            }
        }
        app.start()
        Task { @MainActor in
            let t0 = Date()
            while frames["hello"] == nil, Date().timeIntervalSince(t0) < config.dumpWait + 10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: UInt64(config.dumpWait * 1_000_000_000))
            print(String(decoding: try! report(app, frames: frames, firstPatch: firstPatch), as: UTF8.self))
            exit(frames["hello"] == nil ? 1 : 0)
        }
        RunLoop.main.run()
        exit(0)
    }

    static func report(_ app: AppModel, frames: [String: Int], firstPatch: JSONObject?) throws -> Data {
        let s = app.store
        let startRoute = app.router.route
        let rows = app.rows
        let scopes = app.liveScopes().map(\.rawValue)
        // the key engine, end to end: a prefix opens which-key, a chord navigates
        app.keys.handle("g")
        let whichKey = app.keys.whichKeyRows().map { "\($0.key) \($0.line)" }
        let pendingAfterG = app.keys.pendingKeys
        app.keys.handle("o")
        let afterGO = app.router.route.path
        app.keys.handle("g"); app.keys.handle("f")
        let afterGF = app.router.route.path
        // the modal grammar: j/G move the focused pane, v selects, esc backs out, `:` runs by name
        app.keys.handle("j"); app.keys.handle("v"); app.keys.handle("j"); app.keys.handle("j")
        let modal: JSONObject = [
            "pane": .string(app.pane?.id ?? ""), "cursorAfterJ": .number(Double(app.cursorIdx - 2)),
            "modeAfterV": .string(app.keys.mode.rawValue), "selectedAfterVJJ": .number(Double(app.selection.count)),
        ]
        app.keys.handle("esc")
        let modeAfterEsc = app.keys.mode.rawValue
        app.keys.handle(":")
        app.cmdline = "go dashbord"
        let completion = app.completions.first?.id ?? ""
        app.keys.handle("ret")
        let afterColon = app.router.route.path
        app.router.goBack()
        let focus = s.list(Project.self).filter { $0.state == .focus }.sorted { ($0.rank ?? 0) < ($1.rank ?? 0) }.map(\.name)

        let out: JSONValue = [
            "server": .string(app.transport.base.absoluteString),
            "actor": .string(Transport.actor),
            "conn": .string(s.conn.rawValue),
            "ready": .bool(s.ready),
            "epoch": .string(s.epoch),
            "versions": .object(s.versions.mapValues { .number(Double($0)) }),
            "entities": .object(s.counts.mapValues { .number(Double($0)) }),
            "decodeFailures": .array(s.decodeFailures.map(JSONValue.string)),
            "frames": .object(frames.mapValues { .number(Double($0)) }),
            "streamStats": .object(app.stream.stats.mapValues { .number(Double($0)) }),
            "firstPatch": firstPatch.map(JSONValue.object) ?? .null,
            "bootstrap": ["repos": .array(app.bootstrap.repos.map(JSONValue.string)), "keyOverrides": .number(Double(app.bootstrap.keys.count)),
                          "asset": .string(app.bootstrap.asset)],
            "route": .string(startRoute.path),
            "surface": .string(startRoute.surfaceID),
            "rows": .number(Double(rows.count)),
            "liveScopes": .array(scopes.map(JSONValue.string)),
            "focusForests": .array(focus.prefix(8).map(JSONValue.string)),
            "commands": .number(Double(app.registry.commands.count)),
            "keyProblems": .array(app.registry.keyProblems.map(JSONValue.string)),
            "keyWarnings": .array(app.registry.keyWarnings.map(JSONValue.string)),
            "areas": .array(app.installed.map(JSONValue.string)),
            "surfacesRegistered": .array(app.surfaces.keys.sorted().map(JSONValue.string)),
            "keys": ["pendingAfterG": .string(pendingAfterG), "whichKeyG": .array(whichKey.map(JSONValue.string)),
                     "afterGO": .string(afterGO), "afterGF": .string(afterGF)],
            "modal": .object(modal.merging(["modeAfterEsc": .string(modeAfterEsc), "colonCompletion": .string(completion),
                                            "afterColon": .string(afterColon)]) { $1 }),
            "keyboardRule": .array(KeyboardRule.violations(app).map(JSONValue.string)),
            "fonts": ["registered": .bool(Fonts.registered),
                      "plexMono": .bool(NSFont(name: "IBMPlexMono-Regular", size: 13) != nil && NSFont(name: "IBMPlexMono-SemiBold", size: 13) != nil),
                      "fraunces": .bool(NSFont(name: "FrauncesSoftWonky-Italic", size: 17) != nil)],
        ]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(out)
    }
}
