#!/bin/zsh
# test-stack-facts.sh — pin the invariants of the forest's self-description.
#
# Every one of these was verified BY HAND once and would otherwise rot silently. They are the
# properties the whole thing rests on: one name per branch across every view, a summary that
# survives a restack but not a code change, and a plan that still tells its own history after the
# forest contracts away the branches that made it.
#
# Builds a throwaway repo. Touches nothing real.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

SCRIPTS="${0:A:h}"
pass=0; fail=0
ok()   { print -r -- "  ✓ $1"; pass=$((pass + 1)); }
bad()  { print -r -- "  ✗ $1"; print -r -- "      want: $2"; print -r -- "      got : $3"; fail=$((fail + 1)); }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "contains: $2" "$3"; }
hasnt(){ [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "must NOT contain: $2" "$3"; }

repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
git config user.email t@t.t; git config user.name t
echo one > a.txt; git add -A; git commit -qm "base"

mk() {  # mk <branch> <parent> <subject> <file>
  git checkout -q "$2" && git checkout -qb "$1"
  echo "$1" > "$4"; git add -A; git commit -qm "$3"
  git config "stack-branch.$1.parent" "$2"
  git config "stack-branch.$1.project" proj
  git config --add stack-project.proj.branch "$1"
}
mk one   main "feat(x): the first step"  f1.txt
mk two   one  "feat(y): the second step" f2.txt
mk three two  "feat(z): the third step"  f3.txt

# stack-merge-rank + gh are what stack_facts shells out to. Stub them: no network in a test.
stub="$repo/stub"; mkdir -p "$stub"
cat > "$stub/gh" <<'EOF'
#!/bin/sh
echo '[]'
EOF
cat > "$stub/stack-merge-rank" <<'EOF'
#!/bin/sh
echo '{"order":["one","two","three"]}'
EOF
cat > "$stub/stack-summary" <<EOF
#!/bin/sh
exec "$SCRIPTS/stack-summary" "\$@"
EOF
chmod +x "$stub"/*
# stack_facts resolves its siblings by its OWN directory, so mirror it into the stub dir
cp "$SCRIPTS/stack_facts.py" "$stub/stack_facts.py"
facts() { PATH="$stub:$PATH" python3 "$stub/stack_facts.py" "$@"; }

print -- "
ONE NAME PER BRANCH — every view calls a branch the same thing"
j=$(facts facts two)
job=$(print -r -- "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"])')
bo=$(facts facts three | python3 -c 'import json,sys; print(json.load(sys.stdin)["buildsOn"]["job"])')
is "the job is the subject minus its type(scope): prefix" "the second step" "$job"
is "what builds-on calls it is the same string"           "the second step" "$bo"
has "the plan calls it the same"    "2. the second step"   "$(facts plan three)"
has "the map calls it the same"     "2 · the second step"  "$(facts mermaid three)"

print -- "
THE PLAN — the whole project, this branch marked"
p=$(facts plan two)
has "names every step"        "3. the third step"  "$p"
has "marks this branch"       "<- this branch"     "$p"
has "counts them"             "2 of 3"             "$p"

print -- "
CONTRACTION — a landed step keeps its place and its PR after the branch is dropped"
gd=$(git rev-parse --git-common-dir)
cat > "$gd/stack-project-merges.json" <<'EOF'
{"tip":"x","merges":{"proj":[{"pr":9560,"title":"feat(x): the first step","at":"2026-07-13T00:00:00Z","branch":"one"}]}}
EOF
git config --unset stack-project.proj.branch one      # the contraction: drop the merged node
git config stack-branch.two.parent main               # ... and rewire its child onto main
cat > "$stub/stack-merge-rank" <<'EOF'
#!/bin/sh
echo '{"order":["two","three"]}'
EOF
chmod +x "$stub/stack-merge-rank"
p=$(facts plan three)
has  "the landed step survives the contraction" "1. #9560 (merged) the first step" "$p"
has  "the live steps renumber after it"         "3. the third step"                "$p"
has  "the count still includes what shipped"    "3 of 3"                           "$p"
hasnt "and it is not told twice"                "1. the first step"                "$p"
has  "the map marks it merged"                  "✓"                                "$(facts mermaid three)"

print -- "
SUMMARY — rebase-stable, but not code-stable"
git checkout -q three
git config stack-branch.three.summary "the stored summary"
git config stack-branch.three.summary-patchid \
  "$(git diff two...three | git patch-id --stable | awk '{print $1}')"
is "fresh when stored against this code" "fresh" "$("$SCRIPTS/stack-summary" three --status)"

git checkout -q two && git commit -q --allow-empty -m "reword: two moves, code identical"
old=$(git rev-parse three~1)
git rebase -q --onto two "$old" three >/dev/null 2>&1
is "STILL fresh after a restack (patch-id is rebase-stable)" "fresh" "$("$SCRIPTS/stack-summary" three --status)"

git checkout -q three && echo "different" >> f3.txt && git commit -qam "real code change"
is "STALE once the code actually changes" "stale" "$("$SCRIPTS/stack-summary" three --status)"

print -- "
QUOTING — an apostrophe in a branch's job must not blow up the generator"
git checkout -q main && git checkout -qb quoted
echo q > q.txt; git add -A; git commit -qm "fix(q): don't let a branch's name break it"
git config stack-branch.quoted.parent main
git config stack-branch.quoted.project proj
cat > "$stub/stack-merge-rank" <<'EOF'
#!/bin/sh
echo '{"order":["quoted"]}'
EOF
chmod +x "$stub/stack-merge-rank"
out=$(facts plan quoted 2>&1)
has "renders an apostrophe rather than dying" "don't let a branch's name break it" "$out"

print -- "
$pass passed, $fail failed"
exit $(( fail > 0 ))
