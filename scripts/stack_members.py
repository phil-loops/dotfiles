"""A forest's members, from the one place membership lives: each branch's own
`branch.<b>.stack-project` tag. Git deletes and renames that key with its branch, so it can't
dangle; the `stack-project.<p>.branch` registry is only an order (and a seed list for
stack-forest), and a reader that took it for membership lost a branch when an entry vanished
(2026-11-18: cite-what-ses-saw fell out of disable-evidence's registry while its tag still named
the forest, and the merge-order check replayed its child straight onto main).

  order(project, tags, registry, exists)  members in registry order, then the unlisted by name; a
                                          listed branch with no tag at all (pre-tag) still counts —
                                          dropping a member silently is the failure this prevents
  load(cwd)                               (tags, registries, heads) from one config + ref read
  mismatches(tags, registries, heads)     [(branch, project, why)] where the two disagree

`stack-members <project>` prints the list; `stack-registry` is the one writer of the registry."""
import subprocess


def order(project, tags, registry, exists):
    listed = [b for b in dict.fromkeys(registry) if (tags.get(b) or project) == project and exists(b)]
    rest = sorted(b for b, p in tags.items() if p == project and b not in listed and exists(b))
    return listed + rest


def load(cwd=None):
    def git(*a):
        return subprocess.run(["git", *a], capture_output=True, text=True, cwd=cwd).stdout
    tags, registries = {}, {}
    for ln in git("config", "--get-regexp", r"^(branch\..*\.stack-project|stack-project\..*\.branch)$").splitlines():
        key, _, value = ln.partition(" ")
        value = value.strip()
        if key.startswith("branch.") and key.endswith(".stack-project"):
            tags[key[len("branch."):-len(".stack-project")]] = value
        elif key.startswith("stack-project.") and key.endswith(".branch") and value:
            registries.setdefault(key[len("stack-project."):-len(".branch")], []).append(value)
    heads = set(git("for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads").split())
    return tags, registries, heads


def members(project, cwd=None):
    tags, registries, heads = load(cwd)
    return order(project, tags, registries.get(project, []), heads.__contains__)


def mismatches(tags, registries, heads):
    out = []
    for project, listed in registries.items():
        for b in dict.fromkeys(listed):
            if b in heads and not tags.get(b):
                out.append((b, project, f"listed in {project}'s registry but untagged"))
            elif b in heads and tags.get(b) != project:
                out.append((b, project, f"listed in {project}'s registry but tagged {tags.get(b)}"))
    listed_in = {(b, p) for p, bs in registries.items() for b in bs}
    for b, p in sorted(tags.items()):
        if b in heads and p and (b, p) not in listed_in:
            out.append((b, p, f"tagged {p} but missing from its registry"))
    return out
