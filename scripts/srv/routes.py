# srv/routes.py — every POST the server answers, with what it touches and who may send it.
#
# Authority is declared here, not in comments or in each handler: the dispatcher checks a route's
# declaration before the handler runs, so a handler can't forget its guard and a new route can't
# exist without saying what it does. A route's effects:
#
#   repo     writes this repo's local state (git config, ledgers, logs) — reversible, nothing moves
#   history  moves or rewrites a branch (a commit, a rebase, a reworded message)
#   machine  acts on what the whole machine shares: dev servers, the queue, windows, sessions —
#            refused in the sandbox, which has none of its own
#   outward  changes what other people see (origin, GitHub) — always Phil's click
#
# No effects: a read (it may compute, cache or run a scratch job, but changes nothing anyone sees).
# saw="<field>": the body field naming the identity the press acted on (the tip on screen, a lease, a
# commit) — the dispatcher refuses a body without it, before the handler (CLAUDE.md principle 2). A
# route that moves history or reaches outward declares one, or stands in UNPINNED saying why not.
# phil=True: only Phil's click in Show may send it, whatever it touches. A refusal that depends on
# the request's arguments (a gate skip, a run moved next) stays in its handler.
import json
from collections import namedtuple

from . import evidence   # own line: the big import below is contested across sessions
from . import pushintent   # own line: the big import below is contested across sessions
from . import asks   # own line: the big import below is contested across sessions
from . import callers   # own line: the big import below is contested across sessions
from . import catchup, ctx, edits, forestlock, forestowner
from . import (actor, chat, chats, integrate, lsp, outbox, outline, packet, picker, preview, push, queue, restack,
               review, reviewdesk, reviews, sync, syntax, todo, tutor, usage, verdicts, viewed)

EFFECTS = ("repo", "history", "machine", "outward")
Route = namedtuple("Route", "handler effects phil saw", defaults=(None,))


def _r(handler, *effects, phil=False, saw=None):
    return Route(handler, frozenset(effects), phil, saw)


def _heartbeat(req, raw):
    req._send(200, '{"ok":true}')


POST = {
    # ── reads ──
    "/heartbeat": _r(_heartbeat),
    "/pr-forest": _r(reviews.pr_forest),                 # the extension: forest membership for a PR
    "/chat": _r(chat.start),                             # a read-only chat turn, streamed
    "/tutor": _r(tutor.start),                           # a Socratic turn, read-only claude
    "/tutor-stop": _r(tutor.stop),
    "/lsp/hover": _r(lsp.hover),
    "/lsp/definition": _r(lsp.definition),
    "/lsp/type-definition": _r(lsp.type_definition),
    "/lsp/implementation": _r(lsp.implementation),
    "/lsp/references": _r(lsp.references),
    "/lsp/symbols": _r(lsp.symbols),
    "/lsp/workspace-symbols": _r(lsp.workspace_symbols),
    "/lsp/prepare": _r(lsp.prepare),                     # moves the type trees (its own scratch checkouts)
    "/syntax/units": _r(syntax.units),
    "/callers": _r(callers.answer),                      # which production entry points reach a branch's changes (kept per tip)
    "/integrate": _r(integrate.check),                   # does the whole forest land on main (scratch worktree)
    "/edit-session": _r(edits.prepare, "machine"),
    "/edit-release": _r(edits.release, "machine"),
    "/edit-warm": _r(edits.prime, "machine"),
    "/edit-workspaces": _r(edits.workspaces, "machine"),

    # ── this repo's state ──
    "/open-url": _r(reviews.open_url, "repo"),           # a GitHub URL → its page (imports a PR as review/pr-N)
    "/track": _r(usage.track, "repo"),                   # one usage event into the log
    "/project-describe": _r(review.project_describe, "repo"),
    "/project-rename": _r(review.project_rename, "repo"),
    "/project-state": _r(review.project_state, "repo"),  # focus / workbench / archive
    "/focus": _r(review.focus_set, "repo"),
    "/viewed": _r(viewed.post, "repo"),
    "/todo-item": _r(todo.post, "repo"),
    "/chat-bind": _r(chats.bind, "repo", phil=True),     # Phil binds a chat to a branch's work
    "/chat-dismiss": _r(chats.dismiss, "repo", phil=True),  # Phil: this chat isn't on that branch
    "/outbox-hold": _r(outbox.hold, "repo"),
    "/fix-upstream": _r(sync.fix_upstream, "repo"),      # unset a footgun tracking ref
    "/diverged-additive": _r(sync.diverged_additive, "repo"),   # drafts a push-vehicle branch; never pushes
    "/gates": _r(push.gates, "repo"),                    # a gates run; its verdict is recorded
    "/review": _r(verdicts.review, "repo"),              # a review run; its flags are recorded
    "/delta-tests": _r(push.delta_tests, "repo"),
    "/packet-guide": _r(packet.guide, "repo"),
    "/review-draft": _r(reviewdesk.draft, "repo"),       # the review ledger
    "/learning-evidence": _r(tutor.learning_evidence, "repo"),
    "/learning-question": _r(tutor.learning_question, "repo"),
    "/gates-waive": _r(verdicts.waive, "repo", phil=True, saw="expectTip"),     # ships this tree without gates
    "/evidence-run": _r(evidence.run, "repo"),           # renders before/after evidence (a run)
    "/evidence-judge": _r(evidence.judge, "repo", phil=True),  # Phil's verdict on the manifest he saw

    # ── branches move ──
    "/reseat-children": _r(reviews.reseat, "history"),
    "/sync": _r(sync.post_sync, "history"),
    "/catch-up": _r(catchup.post, "history"),             # the chain onto its moved ancestors (srv/catchup.py)
    "/prep-push": _r(push.prep_push, "history"),
    "/outline": _r(outline.save, "history"),             # rewords unpushed messages
    "/outline-undo": _r(outline.undo, "history"),
    "/dirty-resolve": _r(push.dirty_resolve, "history"),
    "/reconcile": _r(sync.post_reconcile, "history"),
    "/revert-commit": _r(review.revert_commit, "history", saw="sha"),
    "/squash": _r(review.squash, "history"),
    "/prep": _r(review.prep, "history"),
    "/restack": _r(restack.restack, "history"),
    "/lsp/rename": _r(lsp.rename, "history"),            # one commit at the branch tip
    "/review-apply": _r(reviewdesk.apply, "history"),    # a suggestion as a local commit
    "/review-address": _r(reviewdesk.address, "history"),
    "/review-helix": _r(reviewdesk.helix, "history", "machine"),   # opens Helix, then lands its edits
    "/edit-commit": _r(edits.commit, "history", "machine", saw="expectedTip"),
    "/edit-recover": _r(edits.recover, "history", "machine", saw="expectedTip"),

    # ── the machine ──
    "/open": _r(picker.open_file, "machine"),            # a file in the warm review-nvim
    "/review-note": _r(reviewdesk.note, "machine"),      # a note handed to a fresh Claude pane
    "/ask": _r(asks.ask, "repo", "machine", phil=True),  # ask Claude about a branch or one of its lines, in its chat
    "/preview": _r(preview.start, "machine"),
    "/preview-integration": _r(preview.start_integration, "machine"),
    "/preview-main": _r(preview.start_main, "machine"),
    "/preview-restart": _r(preview.restart, "machine"),
    "/stack-up": _r(preview.stack_up, "machine"),
    # these end processes another session may be using
    "/preview-kill": _r(preview.kill, "machine", phil=True),
    "/preview-swap": _r(preview.swap, "machine", phil=True),
    "/preview-reap": _r(preview.reap, "machine", phil=True),
    "/queue-kill": _r(queue.kill, "machine", phil=True),

    # ── what other people see ──
    "/push-origin": _r(push.push_origin, "outward", phil=True, saw="expectTip"),
    "/push-when-green": _r(pushintent.post, "outward", phil=True),   # Phil's press, sent when the gates go green
    "/force-origin": _r(push.force_origin, "outward", phil=True, saw="lease"),
}

# History and outward routes that don't name what they acted on yet — each says why. This list only
# shrinks: test-routes.py pins it, so a new route can't join it without that decision written down.
UNPINNED = {
    "/outline": "pinned per edit: each names its commit's sha, and a sha no longer on the branch is refused (outline.save)",
    "/review-address": "pinned per edit, through outline.save",
    "/outline-undo": "reverses the branch's latest journal entry — pin-outline-undo-to-the-journal-entry-it-promises-to-reverse",
    "/lsp/rename": "keep-rename-previews-and-commits-on-their-reviewed-source",
    "/push-when-green": "queues Phil's press for the tree it reads then (pushintent); the push sends only a tree whose own gates passed",
    "/sync": "rebases the branch as it stands", "/catch-up": "catches the branch up as it stands",
    "/prep-push": "seals the branch as it stands", "/prep": "seals the branch as it stands",
    "/restack": "queues a restack of the forest as it stands", "/squash": "squashes the branch as it stands",
    "/reseat-children": "moves the children as they stand", "/dirty-resolve": "resolves the worktree as it stands",
    "/reconcile": "hands the branch as it stands to Claude", "/review-apply": "commits a suggestion onto the branch as it stands",
    "/review-helix": "lands Helix's edits onto the branch as it stands",
}


def unseen(route, raw):
    """Why a press that must name what it saw didn't, in words; "" when it did or needn't."""
    if not route.saw:
        return ""
    try:
        body = json.loads(raw or "{}")
    except ValueError:
        body = None
    if isinstance(body, dict) and body.get(route.saw):
        return ""
    return f"this press didn't say which {route.saw} it acted on — an older canopy build; restart Show"


SANDBOX_REFUSAL = "the sandbox has none of the machine's servers or processes — this would act on the real ones"


def refusal(route, req):
    """Why `route` won't run for `req`, in words; "" when it may. Outward is Phil's click whatever
    the table says, so a route can't be declared outward and open."""
    if "machine" in route.effects and preview.sandboxed():
        return SANDBOX_REFUSAL
    if (route.phil or "outward" in route.effects) and not actor.is_phil(req):
        return "only Phil's click does this"
    return ""


def post(req, path, raw):
    """The one POST dispatcher: unknown → 404, refused → 403 in words, else the handler."""
    route = POST.get(path)
    if route is None:
        return req._send(404, "{}")
    why = refusal(route, req)
    if why:
        return req._send(403, json.dumps({"ok": False, "err": why}))
    why = unseen(route, raw)
    if why:
        return req._send(400, json.dumps({"ok": False, "err": why, "unseen": True}))
    why = _owner_refusal(route, req, path, raw)
    if why:
        return req._send(403, json.dumps({"ok": False, "err": why, "owner": True}))
    key = _forest_key(route, path, raw)
    if not key:
        return route.handler(req, raw)
    try:
        with forestlock.hold(ctx.repo_cwd(), key, f"canopy {path}", wait=30, export=False):
            return route.handler(req, raw)
    except forestlock.Held as e:
        return req._send(409, json.dumps({"ok": False, "err": str(e), "held": True}))


# /restack only queues: the drainer's stack-restack takes the forest lock itself (holding it here
# would make that child wait on its own server)
_UNLOCKED = {"/restack"}


def _owner_refusal(route, req, path, raw):
    """One owning chat per forest (srv/forestowner.py): a route that changes a forest's history checks
    who asked against the forest's owner before it runs, and hands that initiator to what it spawns.
    Warn mode only records it; "" means go ahead."""
    if not route.effects & {"history"} and not (path == "/gates" and _wants_fix(raw)):
        return ""
    init = actor.initiator(req)
    actor.set_initiator(init)
    project = _project_named(raw)
    if not project:
        return ""
    kind, _, ident = init.partition(":")
    try:
        forestowner.guard(ctx.repo_cwd(), project, f"canopy {path}", "server", branches=_branches_named(raw),
                          who=(kind, ident or None), out=ctx.log)
    except forestowner.Refused as e:
        return str(e)
    return ""


def _body(raw):
    try:
        d = json.loads(raw or "{}")
    except ValueError:
        return {}
    return d if isinstance(d, dict) else {}


def _wants_fix(raw):
    return bool(_body(raw).get("fix"))


def _branches_named(raw):
    d = _body(raw)
    names = [d.get("branch")] + list(d.get("branches") or [])
    return [b for b in names if isinstance(b, str) and b]


def _project_named(raw):
    d = _body(raw)
    for b in _branches_named(raw):
        p = forestowner.project_of(ctx.repo_cwd(), b)
        if p:
            return p
    p = d.get("project")
    return p if isinstance(p, str) and p not in ("", "whole forest", "--all") else ""


def _forest_key(route, path, raw):
    """One writer per forest (srv/forestlock.py): a route that moves a branch or changes origin
    holds the forest of the branch it names. No branch named: nothing to key on, so no lock."""
    if path in _UNLOCKED or not route.effects & {"history", "outward"}:
        return ""
    try:
        d = json.loads(raw or "{}")
    except ValueError:
        return ""
    branch = d.get("branch") if isinstance(d, dict) and isinstance(d.get("branch"), str) else ""
    return forestlock.key_for(ctx.repo_cwd(), branch=branch) if branch else ""
