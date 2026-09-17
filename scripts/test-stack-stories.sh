#!/usr/bin/env bash
# test-stack-stories.sh — throwaway-repo harness for scripts/stack-stories.
# Builds main → q → m (a two-branch forest) plus a ledger-less merged step, then asserts:
# blank boxes render with their fallback, a filled line writes BOTH config spellings (the
# post-sweep target one included, so job_of actually reads it back), an empty value clears,
# an omitted line leaves a branch alone, a bad name aborts the whole write, a concurrent
# change is refused rather than stomped, and every change lands in the story journal.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORIES="$SCRIPTS_DIR/stack-stories"
FACTS="$SCRIPTS_DIR/stack_facts.py"
[[ -x "$STORIES" ]] || { echo "missing or not executable: $STORIES" >&2; exit 3; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stack-stories-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
assert_has()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "expected to contain [$2] in [$3]"; }
assert_lacks(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "expected NOT to contain [$2]"; }
job_of() { python3 "$FACTS" steps "$1" | python3 -c '
import json,sys
b=sys.argv[1]
print(next((s["job"] for s in json.load(sys.stdin)["plan"] if s["branch"]==b), ""))' "$2"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
echo base > f; git add f; git commit -qm base
git checkout -qb q
mkdir -p queries; echo "export const byTeam = 1" > queries/thing.ts
echo "test" > queries/thing.test.ts; git add queries; git commit -qm "queries: add the thing lookups"
git checkout -qb m
echo "export const repair = 1" > models.ts; git add models.ts; git commit -qm "models: repair a thing"
git checkout -q q
git config branch.q.stack-parent main
git config branch.m.stack-parent q
git config branch.q.stack-project p
git config branch.m.stack-project p
git config --add stack-project.p.branch q
git config --add stack-project.p.branch m
git config branch.q.description "add the queries the repair needs"
# the post-sweep state for m: its story lives under the TARGET spelling only
git config branch.m.stack-story "an older line about repairing"

# T1: the buffer starts blank where there is no story, and names the fallback
buf="$("$STORIES" --print)"
assert_has "T1 forest named"         "stack-stories · p → main" "$buf"
assert_has "T1 blank box for q"      $'\nq:\n'                   "$buf$(printf '\n')"
assert_has "T1 q fallback line"      "fallback: description · add the queries the repair needs" "$buf"
assert_has "T1 q evidence commit"    "queries: add the thing lookups" "$buf"
assert_has "T1 q evidence files"     "queries/thing.ts"          "$buf"
assert_has "T1 m keeps its story"    "m: an older line about repairing" "$buf"
assert_has "T1 this-branch marked"   "← THIS BRANCH"             "$buf"

# T2: a filled line writes BOTH spellings and job_of reads the new line back
printf 'q: read the thing without trusting the caller\n' > "$ROOT/fill1"
out="$("$STORIES" --apply "$ROOT/fill1" 2>&1)"; rc=$?
assert_eq "T2 exit 0" 0 "$rc"
assert_has "T2 reports the write" "✓ q: read the thing without trusting the caller" "$out"
assert_eq "T2 target spelling written" "read the thing without trusting the caller" "$(git config branch.q.stack-story)"
assert_eq "T2 legacy spelling written" "read the thing without trusting the caller" "$(git config stack-branch.q.story)"
assert_eq "T2 job_of reads it back"    "read the thing without trusting the caller" "$(job_of q q)"
assert_eq "T2 m untouched (omitted)"   "an older line about repairing" "$(job_of q m)"

# T3: rewriting a story that only exists under the TARGET spelling is NOT shadowed
printf 'm: repair a thing without trusting the caller\n' > "$ROOT/fill2"
"$STORIES" --apply "$ROOT/fill2" >/dev/null 2>&1
assert_eq "T3 target updated" "repair a thing without trusting the caller" "$(git config branch.m.stack-story)"
assert_eq "T3 job_of not shadowed" "repair a thing without trusting the caller" "$(job_of q m)"

# T4: an empty value clears the story, both spellings, and the fallback returns
printf 'q:\n' > "$ROOT/fill3"
out="$("$STORIES" --apply "$ROOT/fill3" 2>&1)"
assert_has "T4 reports the clear" "cleared" "$out"
assert_eq "T4 target gone" "" "$(git config branch.q.stack-story)"
assert_eq "T4 legacy gone" "" "$(git config stack-branch.q.story)"
assert_eq "T4 falls back to description" "add the queries the repair needs" "$(job_of q q)"

# T5: an unknown branch name aborts the WHOLE write — the good line does not land either
printf 'q: a line that should not land\nnot-a-branch: whoops\n' > "$ROOT/fill4"
out="$("$STORIES" --apply "$ROOT/fill4" 2>&1)"; rc=$?
assert_eq "T5 exits nonzero" 2 "$rc"
assert_has "T5 names the offender" "not-a-branch" "$out"
assert_eq "T5 nothing written" "" "$(git config branch.q.stack-story)"

# T6: a duplicate branch line is refused rather than last-wins
printf 'q: one\nq: two\n' > "$ROOT/fill5"
out="$("$STORIES" --apply "$ROOT/fill5" 2>&1)"; rc=$?
assert_eq "T6 exits nonzero" 2 "$rc"
assert_has "T6 says twice" "appears twice" "$out"
assert_eq "T6 nothing written" "" "$(git config branch.q.stack-story)"

# T7: a concurrent change is refused, not stomped — and its neighbour still lands.
# The real flow: render the buffer, somebody else moves a story, THEN the buffer is applied.
git config branch.q.stack-story "written in the viewer just now"
git config stack-branch.q.story "written in the viewer just now"
"$STORIES" --print > "$ROOT/buf7"          # buffer rendered from THIS state
git config branch.q.stack-story "someone else moved it after the buffer opened"
sed -e 's|^q: .*$|q: my editor version|' -e 's|^m: .*$|m: my m version|' "$ROOT/buf7" > "$ROOT/fill7"
out="$("$STORIES" --apply "$ROOT/fill7" 2>&1)"; rc=$?
assert_eq "T7 exits 1 on refusal" 1 "$rc"
assert_has "T7 reports the refusal" "changed elsewhere" "$out"
assert_eq "T7 q left alone" "someone else moved it after the buffer opened" "$(git config branch.q.stack-story)"
assert_eq "T7 m still landed" "my m version" "$(git config branch.m.stack-story)"

# T8: a comments-only buffer aborts, an unparseable line aborts
printf '# everything gone\n' > "$ROOT/fill8"
out="$("$STORIES" --apply "$ROOT/fill8" 2>&1)"; rc=$?
assert_eq "T8 empty buffer exits 0" 0 "$rc"
assert_has "T8 says aborted" "nothing written" "$out"
printf 'a story with no branch name at all\n' > "$ROOT/fill9"
out="$("$STORIES" --apply "$ROOT/fill9" 2>&1)"; rc=$?
assert_eq "T8 bad line exits 2" 2 "$rc"
assert_has "T8 shows the shape" "<branch>: text" "$out"

# T9: every change is journalled, so an overwrite stays recoverable
log="$(git rev-parse --path-format=absolute --git-common-dir)/stack-story-log.jsonl"
[[ -f "$log" ]] && ok "T9 journal exists" || bad "T9 journal exists" "no $log"
assert_has "T9 journal has the first q write" "read the thing without trusting the caller" "$(cat "$log")"
assert_has "T9 journal records a before" '"before"' "$(cat "$log")"

# T10: the editor path — $EDITOR sees the buffer, its save is what lands
cat > "$ROOT/ed" <<'ED'
#!/usr/bin/env bash
grep -q '^# stack-stories · p → main$' "$1" || { echo "no header" >&2; exit 9; }
printf 'm: written through the editor\n' > "$1"
ED
chmod +x "$ROOT/ed"
out="$(GIT_EDITOR="$ROOT/ed" "$STORIES" p 2>&1)"; rc=$?
assert_eq "T10 exit 0" 0 "$rc"
assert_eq "T10 editor save landed" "written through the editor" "$(git config branch.m.stack-story)"
out="$(GIT_EDITOR="false" "$STORIES" p 2>&1)"; rc=$?
assert_eq "T10 editor failure aborts" 2 "$rc"
assert_eq "T10 nothing changed on abort" "written through the editor" "$(git config branch.m.stack-story)"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
