#!/usr/bin/env python3
"""srv/syntax.py against Helix's real grammars and textobject queries (skips when Helix isn't installed)."""
import os
import sys
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import syntax  # noqa: E402

HAVE = os.path.exists(syntax.RUNTIME) and os.path.exists(os.path.join(syntax.HELIX, "grammars", "typescript.dylib"))


def read(src, ext=".ts"):
    us, fns = syntax.units_of(textwrap.dedent(src).lstrip("\n").encode(), ext)
    return [(u["line"], u["endLine"], u["name"], u["scope"]) for u in us], fns


@unittest.skipUnless(HAVE, "needs Homebrew's libtree-sitter and Helix's grammars")
class Units(unittest.TestCase):
    def test_a_test_file_reads_one_unit_per_it_inside_its_describes(self):
        us, fns = read('''
            import { describe, it } from "node:test";

            describe("campaign-group", () => {
              describe("create", () => {
                it("appends order", async () => {
                  const team = await createTeam();
                  assert.ok(team);
                });
              });
              const group = (id: string) => ({
                id,
              });
              it.skip("is pending", () => {});
            });
            ''')
        self.assertEqual(us, [(1, 1, "import", 1),
                              (5, 8, 'it("appends order")', 3),
                              (10, 12, "function group", 2),
                              (13, 13, 'it.skip("is pending")', 2)])
        self.assertIn(5, fns, "Helix's ]f stops at the it callback")

    def test_functions_types_and_constants_are_each_a_unit(self):
        us, _ = read('''
            export const A = 1;
            export const B = 2;

            export type Shape = { id: string };

            export async function findCards(teamId: string) {
              return teamId;
            }

            export const findMany = async (teamId: string) => {
              return [teamId];
            };
            ''')
        self.assertEqual([u[2] for u in us], ["A", "B", "type Shape", "function findCards", "function findMany"])
        self.assertEqual(us[3][:2], (6, 8))

    def test_a_class_is_read_by_its_members(self):
        us, _ = read('''
            export class Queue {
              size = 0;

              push(x: number) {
                this.size += x;
              }
            }
            ''')
        self.assertEqual(us, [(2, 2, "size", 2), (4, 6, "method push", 2)])

    def test_a_react_component_is_read_by_its_hooks_handlers_and_jsx(self):
        us, _ = read('''
            export default function CampaignMenu({ id }: { id: string }) {
              const router = useRouter();
              function handleClick() {
                void router.push(id);
              }
              return <button onClick={handleClick}>go</button>;
            }

            function formatDate(d: Date) {
              const s = d.toISOString();
              return s;
            }
            ''', ".tsx")
        self.assertEqual([u[2] for u in us], ["router", "function handleClick", "return", "function formatDate"],
                         "a PascalCase component is stepped into; a plain function is read whole")

    def test_a_language_without_a_grammar_here_is_none(self):
        self.assertIsNone(syntax.units_of(b"x = 1\n", ".py"))

    def test_helix_inherits_are_folded_into_one_query(self):
        q = syntax.query_text("typescript")
        self.assertIn("arrow_function", q, "ecma's function.around comes in through typescript's inherits line")
        self.assertNotIn("; inherits:", q)


if __name__ == "__main__":
    unittest.main()
