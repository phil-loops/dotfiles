import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

// , m reads a declaration: symbol lists shaped as tsgo answers /lsp/symbols for loops' own files
// (test callbacks named `describe("…") callback`, locals and properties nested under them).

private func sym(_ name: String, _ kind: String, _ line: Int, _ end: Int, _ depth: Int) -> LSPSymbols.Symbol {
    let json: [String: Any] = ["name": name, "kind": kind, "line": line, "endLine": end, "depth": depth]
    return try! JSONDecoder().decode(LSPSymbols.Symbol.self, from: JSONSerialization.data(withJSONObject: json))
}

/// The units of a patch, keyed by block, as the page would hold them.
private func units(_ patch: String, status: FileStatus = .modified, _ syms: [LSPSymbols.Symbol]?) -> [Int: ReviewUnit] {
    // a blank context line is one space in a real patch; the fixtures leave it empty
    var f = parsePatch("x.test.ts", "@@ " + patch.dropFirst(3).replacingOccurrences(of: "\n\n", with: "\n \n"))
    f.status = status
    let rows = unifiedRows(f)
    let anchors = blockAnchors(f)
    var rowBlock: [String: Int] = [:]
    for r in rows {
        guard let l = [r.left, r.right].compactMap({ $0 }).first(where: { $0.kind != .ctx }), let b = anchors[anchorOf(l)] else { continue }
        rowBlock[r.key] = b
    }
    return ReviewUnitRule.units(rows: rows, rowBlock: rowBlock, status: f.status, symbols: syms)
}

private let testFile = [
    sym("describe", "variable", 2, 2, 0),
    sym(#"describe("campaign-group") callback"#, "function", 4, 30, 0),
    sym(#"describe("create") callback"#, "function", 5, 16, 1),
    sym(#"it("appends order") callback"#, "function", 6, 15, 2),
    sym("team", "variable", 7, 7, 3),
    sym("created", "variable", 9, 12, 3),
    sym("teamId", "property", 10, 10, 4),
    sym(#"describe("findManyByTeam") callback"#, "function", 18, 29, 1),
    sym(#"it("returns only the team's groups") callback"#, "function", 19, 28, 2),
    sym("groups", "variable", 21, 21, 3),
    sym("groups.map() callback", "function", 24, 24, 3),
]

@MainActor @Suite struct ReviewUnitsTests {
    @Test func twoEditsInOneTestAreOneUnitAndAnotherTestIsItsOwn() {
        let u = units("""
        @@ -7,9 +7,9 @@
        -    const team = await createTeam();
        +    const team = await createTeam({ name: "a" });
             const otherTeam = 1;
        -    const created = await create({
        +    const created = await CampaignGroup.create({
               teamId: team.id,
               name: "x",
               description: "",
             });
             assert.ok(created);
        @@ -21,4 +21,4 @@
        -    const groups = await findManyByTeam(team.id);
        +    const groups = await CampaignGroup.findManyByTeam(team.id);
             assert.equal(groups.length, 2);
             assert.deepEqual(
               groups.map((group) => group.id),
        """, testFile)
        #expect(u[0] == ReviewUnit(blocks: [0, 1], name: #"it("appends order")"#), "both edits sit in one it: one , m reads the test")
        #expect(u[1] == u[0])
        #expect(u[2] == ReviewUnit(blocks: [2], name: #"it("returns only the team's groups")"#), "a describe is stepped into, not read whole")
    }

    @Test func aFunctionEditedInTwoPlacesIsOneUnitAndItsNeighbourIsNot() {
        let syms = [
            sym("findCards", "function", 3, 12, 0),
            sym("findManyWithCards", "function", 14, 25, 0),
        ]
        let u = units("""
        @@ -3,10 +3,10 @@
         export async function findCards(
        -  { teamId }: { teamId: string },
        +  { teamId, order }: { teamId: string; order: "manual" | "recent" },
           deps = {
             findCardsInManualOrder: CampaignQueries.findCardsInManualOrder,
           }
         ) {
        -  return await deps.findCardsInManualOrder(teamId);
        +  return order === "manual"
        +    ? await deps.findCardsInManualOrder(teamId)
        +    : await deps.findCardsMostRecentFirst(teamId);
         }
        @@ -16,3 +18,3 @@
           const [groups, cards] = await Promise.all([
        -    deps.findGroups(teamId),
        +    deps.findGroups({ teamId }),
             deps.findCards({ teamId, order: "manual" }),
        """, syms)
        #expect(u[0] == ReviewUnit(blocks: [0, 1], name: "function findCards"))
        #expect(u[2] == ReviewUnit(blocks: [2], name: "function findManyWithCards"), "each function is its own unit")
    }

    @Test func neighbouringOneLineConstantsReadAsOneButAMultiLineOneStandsAlone() {
        let syms = [
            sym("A", "constant", 1, 1, 0),
            sym("B", "constant", 3, 3, 0),
            sym("SELECT", "constant", 5, 9, 0),
        ]
        let u = units("""
        @@ -1,9 +1,9 @@
        -export const A = 1;
        +export const A = 2;

        -export const B = 1;
        +export const B = 2;

         export const SELECT = {
        -  id: true,
        +  id: false,
           name: true,
         };
        """, syms)
        #expect(u[0] == ReviewUnit(blocks: [0, 1], name: "2 declarations"))
        #expect(u[2] == ReviewUnit(blocks: [2], name: "SELECT"))
    }

    @Test func aNewFileIsOneUnitEvenWithoutSymbols() {
        let u = units("""
        @@ -0,0 +1,3 @@
        +export const a = 1;
        +
        +export function f() {}
        """, status: .added, nil)
        #expect(u[0] == ReviewUnit(blocks: [0], name: "the new file"))
    }

    @Test func aChangeOutsideEveryDeclarationIsItsOwnAndARemovalJoinsItsFunction() {
        let syms = [sym("f", "function", 3, 8, 0)]
        let u = units("""
        @@ -1,9 +1,8 @@
        -import { x } from "./x";
        +import { x, y } from "./x";

         export function f() {
           const a = 1;
        -  const b = 2;
           return a;
         }
        """, syms)
        #expect(u[0] == ReviewUnit(blocks: [0], name: "a change"))
        #expect(u[1] == ReviewUnit(blocks: [1], name: "function f"))
    }

    @Test func noSymbolsLeavesEachChangeItsOwnUnit() {
        let u = units("""
        @@ -1,3 +1,3 @@
        -a
        +b
         c
        -d
        +e
        """, nil)
        #expect(u[0]?.blocks == [0] && u[1]?.blocks == [1])
    }
}
