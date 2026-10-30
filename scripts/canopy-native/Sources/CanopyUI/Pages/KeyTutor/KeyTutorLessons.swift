import CanopyCore
import Foundation

/// One step: an instruction, the verbs that finish it (any of them; none means the outcome alone
/// does), where it starts, and the outcome it wants. `{verb}` in the text renders as the key that
/// verb has right now — after keys-native.toml — so a step survives any rebinding.
struct KeyStep {
    var text: String
    var wants: [Verb]
    /// put the practice app where the step starts; false until it's there (a diff still loading)
    var setup: (@MainActor (AppModel) -> Bool)?
    /// the outcome the step wants, checked after the verb fires
    var check: (@MainActor (AppModel) -> Bool)?
    /// what to say after a couple of misses when no verb finishes the step
    var hint: String?

    init(_ text: String, _ wants: [Verb], setup: (@MainActor (AppModel) -> Bool)? = nil,
         check: (@MainActor (AppModel) -> Bool)? = nil, hint: String? = nil) {
        self.text = text; self.wants = wants; self.setup = setup; self.check = check; self.hint = hint
    }
}

/// One lesson: a tier of NAV.md's verb table, done in order, then a recap.
struct KeyLesson {
    var id: String
    var title: String
    var steps: [KeyStep]
    var recap: String

    /// Every verb some step of it finishes on.
    var teaches: [Verb] { steps.flatMap(\.wants) }
}

/// Where steps start and what they check, on the practice app.
@MainActor
enum Practice {
    typealias S = KeyTutorSandbox

    static func pg(_ a: AppModel) -> ReviewPageState { ReviewPageState.of(a) }
    static func onBranch(_ a: AppModel, _ name: String) -> Bool { a.router.route == .review(repo: S.repo, branch: name) }
    static func onForest(_ a: AppModel, _ name: String) -> Bool { a.router.route == .forest(repo: S.repo, project: name) }
    static func here(_ a: AppModel) -> String? { pg(a).here?.key }

    static func forests(cursor: String? = RowKey.project(S.greetings)) -> @MainActor (AppModel) -> Bool {
        { a in
            if a.router.route != .forests { a.go(.forests) }
            if let cursor, a.rows.contains(cursor), a.selected != cursor { a.setCursor(cursor) }
            return a.router.route == .forests
        }
    }

    static func forest(_ name: String = "greetings", cursor: String? = nil) -> @MainActor (AppModel) -> Bool {
        { a in
            if !onForest(a, name) { a.go(.forest(repo: S.repo, project: name)) }
            if let cursor {
                guard a.rows.contains(cursor) else { return false }
                if a.selected != cursor { a.setCursor(cursor) }
            }
            return onForest(a, name)
        }
    }

    /// The review page on `branch`, its diff landed, the cursor on `stop` (a stop key) if given.
    static func review(_ branch: String = S.root, at stop: String? = nil) -> @MainActor (AppModel) -> Bool {
        { a in
            if !onBranch(a, branch) { a.go(.review(repo: S.repo, branch: branch)) }
            let p = pg(a)
            guard onBranch(a, branch), p.payload?.key.hasPrefix("\(S.id(branch))@") == true, !p.stops.isEmpty else { return false }
            if p.tab != "files" { p.tab = "files" }
            if let stop {
                // a fresh look at the diff: what earlier steps marked viewed (and folded) unfolds
                if !p.viewedOverride.isEmpty { p.viewedOverride = [:] }
                if !p.filter.isEmpty { p.filter = "" }
                guard p.stops.contains(where: { $0.key == stop }) else { return false }
                if a.pane?.id != reviewDiffPane { p.focusDiff(a, true) }
                if p.here?.key != stop { p.setCursor(stop) }
            }
            return true
        }
    }

    /// The review page with the comment box open on a line, writing.
    static func composing() -> @MainActor (AppModel) -> Bool {
        { a in
            guard review(S.root, at: "l|greet.ts|R:2")(a) else { return false }
            if ShipState.of(a).composer == nil { a.runner.dispatch("review.comment", via: .palette) }
            else if a.keys.mode != .insert { a.runner.dispatch("review.compose.edit", via: .palette) }
            return ShipState.of(a).composer != nil && a.keys.mode == .insert
        }
    }

    static func todo() -> @MainActor (AppModel) -> Bool {
        { a in
            if a.router.route != .todo { a.go(.todo) }
            guard a.router.route == .todo, let first = a.rows.first else { return false }
            if a.selected == nil { a.setCursor(first) }
            return true
        }
    }

    /// The Socratic tutor's home, its practice graph read, the first pane (due) focused.
    static func tutorPage() -> @MainActor (AppModel) -> Bool {
        { a in
            if a.router.route != .tutor(session: nil) { a.go(.tutor(session: nil)) }
            let t = TutorArea.state(a)
            if t.learn == nil { t.refresh() }
            guard a.router.route == .tutor(session: nil), a.panes.contains(where: { $0.id == TutorPane.topics }) else { return false }
            if a.pane?.id != TutorPane.due { a.focus(pane: TutorPane.due) }
            return true
        }
    }
}

/// The lessons, in the order NAV.md's tiers teach them. Data: text, the verbs that finish each
/// step, the state each starts in and wants. `KeyTutorTests` fails if a verb in the table goes
/// untaught (beyond `untaught`).
@MainActor
enum KeyLessons {
    typealias S = KeyTutorSandbox
    typealias P = Practice

    /// Verbs no lesson needs to drill, and why.
    static let untaught: [Verb: String] = {
        var out: [Verb: String] = [:]
        for n in 3...9 { out[.slot(n)] = "the same verb as slot-1 and slot-2 with another digit; the practice lane has two forests" }
        for n in 4...9 { out[.nth(n)] = "the same verb as nth-1…nth-3 with another digit; the review page has three tabs" }
        return out
    }()

    static let all: [KeyLesson] = [
        KeyLesson(id: "modes", title: "Modes and esc", steps: [
            KeyStep("This is canopy on practice data — nothing you do here reaches git, the server or GitHub. A step finishes when you do it, whatever your keys are. Press {command} to open the command line: command mode.",
                    [.command], setup: P.forests(), check: { $0.keys.mode == .command }),
            KeyStep("{cancel} backs out one level: the line closes and you're in normal mode. esc only ever cancels — it never changes page.",
                    [.cancel], check: { $0.keys.mode == .normal }),
            KeyStep("Press the first key of {go-forests} and stop: a chord waits for its next key, as long as it takes, and which-key lists what can follow.",
                    [], check: { !$0.keys.pendingKeys.isEmpty }, hint: "press just the first key of a chord, like the g of g f"),
            KeyStep("{cancel} drops the half-typed chord.", [.cancel], check: { $0.keys.pendingKeys.isEmpty }),
        ], recap: "{command} opens the command line. {cancel} backs out exactly one level — a chord, a layer, a mode — and never changes page."),

        KeyLesson(id: "moving", title: "Moving", steps: [
            KeyStep("A diff to move through. {next} goes down a line.", [.next], setup: P.review()),
            KeyStep("{previous} goes up.", [.previous]),
            KeyStep("{last} jumps to the last line.", [.last], check: { P.here($0) == P.pg($0).stops.last?.key }),
            KeyStep("{first} jumps back to the first.", [.first], check: { P.here($0) == P.pg($0).stops.first?.key }),
            KeyStep("{half-down} goes down half a page.", [.halfDown]),
            KeyStep("{half-up} comes back up half a page.", [.halfUp]),
        ], recap: "{next} / {previous} a line, {first} / {last} the ends (jumps: the jumplist remembers), {half-down} / {half-up} half a page."),

        KeyLesson(id: "ladder", title: "The zoom ladder", steps: [
            KeyStep("One axis, in and out: forests → forest → branch → file → line. On the greetings forest, {in} goes one level in — its branches open in place.",
                    [.into], setup: P.forests()),
            KeyStep("{main} does the thing's main action: on a forest, open its page.", [.main],
                    setup: P.forests(), check: { P.onForest($0, "greetings") }),
            KeyStep("On a branch, {in} opens it for review.", [.into],
                    setup: P.forest(cursor: RowKey.branch(S.id(S.root))), check: { P.onBranch($0, S.root) }),
            KeyStep("{out} climbs back to the forest, the branch still under the cursor.", [.out], check: { P.onForest($0, "greetings") }),
            KeyStep("{out} once more: Forests.", [.out], check: { $0.router.route == .forests }),
        ], recap: "{in} and {out} walk the ladder; {main} is the main action of whatever's under the cursor."),

        KeyLesson(id: "labels", title: "Labels", steps: [
            KeyStep("To go to something you can see, don't step to it: {labels} labels everything on screen.",
                    [.labels], setup: P.forest(), check: { $0.labeling != nil }),
            KeyStep("Type the label beside use-greeting-in-footer: you land there, as if you'd moved and pressed {main}.",
                    [], check: { P.onBranch($0, S.footer) || $0.selected == RowKey.branch(S.id(S.footer)) },
                    hint: "type the gold tag at the start of the use-greeting-in-footer row; {labels} brings them back"),
        ], recap: "{labels} then a label: any row, tab or button you can see, in two or three keys."),

        KeyLesson(id: "stack", title: "Walking the stack", steps: [
            KeyStep("Reviewing add-greeting. {next-sibling} goes to the next branch in merge order, staying on review.",
                    [.nextSibling], setup: P.review(), check: { P.onBranch($0, S.header) }),
            KeyStep("{child}: this branch's child.", [.child], check: { P.onBranch($0, S.banner) }),
            KeyStep("{parent}: back to its parent.", [.parent], check: { P.onBranch($0, S.header) }),
            KeyStep("{tip}: the tip of the stack.", [.tip], check: { P.onBranch($0, S.banner) }),
            KeyStep("{previous-sibling}: the branch before it in merge order.", [.previousSibling], check: { P.onBranch($0, S.footer) }),
            KeyStep("{root}: the root of the stack.", [.root], check: { P.onBranch($0, S.root) }),
        ], recap: "{next-sibling} / {previous-sibling} walk merge order; {parent}, {child}, {root}, {tip} walk the tree (at a fork, {child} labels the children). All are jumps."),

        KeyLesson(id: "jumps", title: "Pickers and the jumplist", steps: [
            KeyStep("{branches} finds any branch, the ones you visit most first.", [.branches],
                    setup: P.review(), check: { $0.nav.picker != nil }),
            KeyStep("Type foot, then {send} opens it.", [.send], check: { P.onBranch($0, S.footer) },
                    hint: "type part of use-greeting-in-footer, then {send}"),
            KeyStep("{jump-back} jumps back to where you were.", [.jumpBack], check: { P.onBranch($0, S.root) }),
            KeyStep("{jump-forward} goes forward again.", [.jumpForward], check: { P.onBranch($0, S.footer) }),
            KeyStep("{alternate}: the alternate place — where the last jump left from.", [.alternate]),
            KeyStep("{save-jump} saves this spot to the jumplist.", [.saveJump]),
            KeyStep("{jumps} lists the jumplist.", [.jumps], check: { $0.nav.picker != nil }),
            KeyStep("{cancel} closes it.", [.cancel], check: { $0.nav.picker == nil }),
            KeyStep("{last-picker} reopens the last picker, query and all.", [.lastPicker], check: { $0.nav.picker != nil }),
            KeyStep("{cancel} again.", [.cancel], check: { $0.nav.picker == nil }),
            KeyStep("{slot-1} goes to focus forest 1, at the branch you last had open there.", [.slot1],
                    check: { a in a.router.route.branchID.flatMap { a.store.view(Branch.self, $0)?.project } == S.greetings || P.onForest(a, "greetings") }),
            KeyStep("{slot-2}: focus forest 2. (The digits go on to 9.)", [.slot2],
                    check: { P.onForest($0, "farewells") || P.onBranch($0, S.farewell) }),
        ], recap: "{branches} / {jumps} / {last-picker} pick; {jump-back} / {jump-forward} walk the jumplist, {save-jump} adds to it, {alternate} flips; {slot-1}… the focus lane."),

        KeyLesson(id: "pages", title: "Pages and panes", steps: [
            KeyStep("{go-tutor}: the Socratic tutor's page (empty here) — a page of stacked panes.", [.goTutor],
                    setup: P.forests(), check: { $0.router.route == .tutor(session: nil) }),
            KeyStep("{pane-down} focuses the pane below.", [.paneDown], setup: P.tutorPage(), check: { $0.pane?.id == TutorPane.topics }),
            KeyStep("{pane-up} the pane above.", [.paneUp], check: { $0.pane?.id == TutorPane.due }),
            KeyStep("{pane-right} the pane to the right.", [.paneRight], check: { $0.pane?.id != TutorPane.due }),
            KeyStep("{pane-left} back to the left.", [.paneLeft], check: { $0.pane?.id == TutorPane.due }),
            KeyStep("{pane-next} cycles through them.", [.paneNext]),
            KeyStep("{go-dashboard}: the dashboard.", [.goDashboard], check: { $0.router.route == .dashboard }),
            KeyStep("{go-machine}: the machine.", [.goMachine], check: { $0.router.route == .machine }),
            KeyStep("{go-wiki}: the wiki.", [.goWiki], check: { $0.router.route.surfaceID == "wiki" }),
            KeyStep("{go-todo}: the tracker.", [.goTodo], check: { $0.router.route == .todo }),
            KeyStep("{go-forests}: home.", [.goForests], check: { $0.router.route == .forests }),
            KeyStep("On a forest's page, {face} flips its face: the branches ⇄ the story.", [.face],
                    setup: P.forest(), check: { $0.forestModel.face == .story }),
            KeyStep("{face} again, back to the branches.", [.face], check: { $0.forestModel.face == .branches }),
        ], recap: "The g keys go to a page; {pane-left} {pane-down} {pane-up} {pane-right} / {pane-next} move between panes; {face} is a page's other face."),

        KeyLesson(id: "review", title: "Reviewing a diff", steps: [
            KeyStep("{next-file} jumps to the next file.", [.nextFile], setup: P.review(at: "l|greet.ts|R:1"),
                    check: { P.here($0) == "f|header.ts" }),
            KeyStep("{previous-file} back.", [.previousFile], check: { P.here($0) == "f|greet.ts" }),
            KeyStep("{next-hunk}: the next hunk.", [.nextHunk]),
            KeyStep("{previous-hunk}: the one before.", [.previousHunk]),
            KeyStep("{next-thread}: the next conversation, open ones first.", [.nextThread], check: { P.here($0)?.hasPrefix("t|") == true }),
            KeyStep("{previous-thread}: the one before.", [.previousThread], check: { P.here($0)?.hasPrefix("t|") == true }),
            KeyStep("{mark} marks the hunk viewed and goes on to the next unviewed one.", [.mark],
                    setup: P.review(at: "l|greet.ts|R:1"), check: { a in Self.hunk0(a).allSatisfy(P.pg(a).isSeen) }),
            KeyStep("{previous-hunk} back to it…", [.previousHunk]),
            KeyStep("…and {unmark} takes the mark off.", [.unmark], check: { a in !Self.hunk0(a).allSatisfy(P.pg(a).isSeen) }),
            KeyStep("{select} starts a range at the cursor: select mode.", [.select], check: { $0.keys.mode == .select }),
            KeyStep("{next-hunk} stretches it a hunk.", [.nextHunk], check: { $0.keys.mode == .select }),
            KeyStep("{mark} marks the whole range viewed, and select mode ends.", [.mark], check: { $0.keys.mode == .normal }),
            KeyStep("On a line, {extend} selects it.", [.extend], setup: P.review(at: "l|greet.ts|R:2"), check: { P.pg($0).range != nil }),
            KeyStep("{extend} again stretches it a line.", [.extend]),
            KeyStep("{comment} comments on the range — three verbs in a row, not a chord.", [.comment],
                    check: { ShipState.of($0).composer != nil }),
        ], recap: "{next-file} {previous-file} · {next-hunk} {previous-hunk} · {next-thread} {previous-thread}; {mark} marks viewed and moves on, {unmark} unmarks; {select} ranges, {extend} lines, {comment} comments."),

        KeyLesson(id: "code", title: "Finding things and reading code", steps: [
            KeyStep("{find} finds a file on this page by name.", [.find], setup: P.review(at: "l|greet.ts|R:2"), check: { $0.keys.mode == .insert }),
            KeyStep("Type head, then {send}.", [.send], check: { P.pg($0).here?.path == "header.ts" }, hint: "type head into the filter, then {send}"),
            KeyStep("{search} searches the page's text.", [.search], check: { $0.nav.picker != nil }),
            KeyStep("Type wave, then {send}.", [.send], check: { $0.nav.picker == nil }, hint: "type a word you can see, then {send}"),
            KeyStep("{map}: the map of the stack around you.", [.map], check: { $0.keys.layer == .map }),
            KeyStep("{cancel} closes it.", [.cancel], check: { $0.keys.layer == nil }),
            KeyStep("{type}: the type under the cursor.", [.type], setup: P.review(at: "l|greet.ts|R:2")),
            KeyStep("{definition}: go to the definition.", [.definition]),
            KeyStep("{type-definition}: the definition of its type.", [.typeDefinition]),
            KeyStep("{implementations}: its implementations.", [.implementations]),
            KeyStep("{references}: everything that refers to it.", [.references], check: { $0.nav.picker != nil }),
            KeyStep("{cancel} closes whatever's open.", [.cancel], check: { $0.nav.picker == nil }),
            KeyStep("{symbols}: the file's symbols.", [.symbols], check: { $0.nav.picker != nil }),
            KeyStep("{cancel}.", [.cancel], check: { $0.nav.picker == nil }),
            KeyStep("{github} opens it on GitHub — practice, so nothing opens.", [.github], setup: P.review()),
            KeyStep("{preview} previews it on a side port — practice, so nothing starts.", [.preview]),
        ], recap: "{find} by name, {search} by text, {map} the stack; {type} {definition} {type-definition} {implementations} {references} {symbols} read code; {github} and {preview} leave the app."),

        KeyLesson(id: "writing", title: "Writing", steps: [
            KeyStep("You're writing a comment (insert mode). Type a line, then ↵: in a many-line box like this, ↵ is a new line, like {newline}. Sending is always deliberate.",
                    [.newline], setup: P.composing(), check: { $0.keys.mode == .insert }),
            KeyStep("{cancel} stops writing; the words stay.", [.cancel],
                    check: { $0.keys.mode == .normal && ShipState.of($0).composer != nil }),
            KeyStep("{write} goes back to writing.", [.write], check: { $0.keys.mode == .insert }),
            KeyStep("{send} sends it — in a many-line box, only {send} does.", [.send], check: { ShipState.of($0).composer == nil }),
            KeyStep("A one-line field: on a branch, {write} writes its description.", [.write],
                    setup: P.forest(cursor: RowKey.branch(S.id(S.header))), check: { $0.keys.mode == .insert && $0.keys.fieldLines == .single }),
            KeyStep("In a one-line field ↵ finishes ({send} does too).", [.send], check: { $0.keys.mode == .normal }),
        ], recap: "{write} starts writing, {cancel} stops. {send} always sends; ↵ finishes a one-line field and is a new line in a many-line box ({newline} is one everywhere)."),

        KeyLesson(id: "shared", title: "Shared verbs", steps: [
            KeyStep("On rowan's suggestion, {apply} applies the suggested fix — a local commit (practice: nothing is committed).", [.apply],
                    setup: P.review(at: "t|\(S.thread1)")),
            KeyStep("{undo} undoes the last change.", [.undo]),
            KeyStep("On rowan's question, {reply} replies.", [.reply], setup: P.review(at: "t|\(S.thread2)"),
                    check: { ShipState.of($0).composer != nil }),
            KeyStep("{cancel} twice: stop writing, then close the box.", [.cancel],
                    check: { $0.keys.mode == .normal && ShipState.of($0).composer == nil }),
            KeyStep("Digits pick the Nth thing shown: {nth-1}, the conversation tab.", [.nth1], check: { P.pg($0).tab == "conversation" }),
            KeyStep("{nth-2}: the commits tab.", [.nth2], check: { P.pg($0).tab == "commits" }),
            KeyStep("{nth-3}: the files again.", [.nth3], check: { P.pg($0).tab == "files" }),
            KeyStep("{face} steps through the tabs too.", [.face]),
            KeyStep("{words}: what's written about it — the PR's title and why, the commits.", [.words], setup: P.review(),
                    check: { $0.pane?.id == ShipSeam.wordsPane }),
            KeyStep("On the title row ({next} to it), {copy} copies it — practice: your clipboard is left alone.", [.copy],
                    check: { KeyTutorStub.notes($0.config.port ?? 0).contains { $0.hasPrefix("copy ") } }),
            KeyStep("{sync} syncs the branch: fold dirt, rebase onto its parent, shape the commits.", [.sync], setup: P.review()),
            KeyStep("{push} sends it out: push to origin, send the draft.", [.push]),
            KeyStep("{editor} opens it in Helix (practice: nothing opens).", [.editor], setup: P.review(at: "l|greet.ts|R:2")),
            KeyStep("The tracker. {move-down} moves the item down its hand-ordered list.", [.moveDown], setup: P.todo()),
            KeyStep("{move-up} moves it back up.", [.moveUp]),
            KeyStep("{main}: the item's main action — its notes.", [.main]),
            KeyStep("{mark} marks it done and goes on.", [.mark]),
            KeyStep("{put-away} puts it away: drop, archive, delete, kill — whatever away means here.", [.putAway]),
            KeyStep("{undo} puts it back.", [.undo]),
        ], recap: "A shared verb means one thing on every page that has it: {apply} {undo} {reply} {words} {copy} {sync} {push} {editor} {move-up} {move-down} {mark} {put-away}; digits pick the Nth."),

        KeyLesson(id: "leader", title: "The page's own keys", steps: [
            KeyStep("What no verb names is the page's own, under the leader: {leader}. Which-key lists this page's keys.",
                    [.leader], setup: P.review(), check: { $0.keys.pendingIsLeader }),
            KeyStep("Press o: on review that shows the outdated conversations.", [], check: { P.pg($0).showOutdated },
                    hint: "{leader} then o"),
            KeyStep("{leader} o again hides them.", [], check: { !P.pg($0).showOutdated }, hint: "{leader} then o"),
        ], recap: "{leader} then a letter: the page's own keys, listed by which-key. They can't collide with another page's."),

        KeyLesson(id: "help", title: "The command line and ?", steps: [
            KeyStep("{command} opens the command line: anything runs by name.", [.command], setup: P.forests(), check: { $0.keys.mode == .command }),
            KeyStep("Type go todo — fuzzy is fine — then {send}.", [.send], check: { $0.router.route == .todo }, hint: "type go todo, then {send}"),
            KeyStep("{menu}: the command menu.", [.menu], check: { $0.menuOpen }),
            KeyStep("{cancel}.", [.cancel], check: { !$0.menuOpen }),
            KeyStep("{keys}: every key, here and now — yours underlined.", [.keys], check: { $0.sheetOpen }),
            KeyStep("{cancel} closes it.", [.cancel], check: { !$0.sheetOpen }),
        ], recap: "{command} runs anything by name, {menu} lists every command, {keys} shows every key. :keytutor brings you back here; :keytutor <lesson> jumps to one."),
    ]

    static func hunk0(_ a: AppModel) -> [String] {
        Practice.pg(a).fileOf("greet.ts")?.blocks.filter { $0.hunk == 0 }.map(\.key) ?? ["?"]
    }

    /// The lesson a typed name means, fuzzily ("rev" → review).
    static func match(_ want: String) -> Int? {
        let w = want.trimmingCharacters(in: .whitespaces).lowercased()
        if let i = all.firstIndex(where: { $0.id == w }) { return i }
        guard let best = ranked(Array(all.indices), w, { "\(all[$0].id) \(all[$0].title)" }).first,
              pickScore("\(all[best].id) \(all[best].title)".lowercased(), w) != nil else { return nil }
        return best
    }
}
