import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

// , m reads a declaration: declarations shaped as POST /syntax/units reads loops' own files from
// their syntax tree (each it(…) its own, describe(…) stepped into, a component by its parts).

private func d(_ name: String, _ line: Int, _ end: Int, scope: Int = 1) -> SyntaxUnit {
    SyntaxUnit(line: line, endLine: end, name: name, scope: scope)
}

/// The units of a patch, keyed by block, as the page would hold them.
private func units(_ patch: String, status: FileStatus = .modified, _ decls: [SyntaxUnit]?) -> [Int: ReviewUnit] {
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
    return ReviewUnitRule.units(rows: rows, rowBlock: rowBlock, status: f.status, decls: decls)
}

private let testFile = [
    d("import", 2, 2),
    d(#"it("appends order")"#, 6, 15, scope: 3),
    d(#"it("returns only the team's groups")"#, 19, 28, scope: 4),
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
        let syms = [d("function findCards", 3, 12), d("function findManyWithCards", 14, 25)]
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
        let syms = [d("A", 1, 1), d("B", 3, 3), d("SELECT", 5, 9)]
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

    @Test func aNewFileIsOneUnitEvenWithoutDeclarations() {
        let u = units("""
        @@ -0,0 +1,3 @@
        +export const a = 1;
        +
        +export function f() {}
        """, status: .added, nil)
        #expect(u[0] == ReviewUnit(blocks: [0], name: "the new file"))
    }

    @Test func anImportIsItsOwnAndARemovalJoinsItsFunction() {
        let syms = [d("import", 1, 1), d("function f", 3, 8)]
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
        #expect(u[0] == ReviewUnit(blocks: [0], name: "import"))
        #expect(u[1] == ReviewUnit(blocks: [1], name: "function f"))
    }

    @Test func noDeclarationsLeavesEachChangeItsOwnUnit() {
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

    @Test func oneLinersMergeOnlyWithinTheirScopeAndAGapLineIsItsOwn() {
        let decls = [d("router", 2, 2, scope: 2), d("A", 4, 4), d("function g", 7, 9)]
        let u = units("""
        @@ -1,9 +1,9 @@
         function C() {
        -  const router = useRouter();
        +  const router = useRouter({});
         }
        -export const A = 1;
        +export const A = 2;

        -// note
        +// a note
         function g() {
           return 1;
         }
        """, decls)
        #expect(u[0] == ReviewUnit(blocks: [0], name: "router"), "a hook line and a top-level const sit in different scopes")
        #expect(u[1] == ReviewUnit(blocks: [1], name: "A"))
        #expect(u[2] == ReviewUnit(blocks: [2], name: "a change"), "a line between declarations is its own")
    }
}
