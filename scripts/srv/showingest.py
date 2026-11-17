"""srv/showingest.py — Show's reply composer as the work journal's owned ingress (DESIGN.md round 25).

Three steps, each a `canopy-work` call from Show:

  bind     when a work-bound section is opened: binds the conversation `<deck>#<section>` to the
           work of the tracker record's current incarnation, once. Show keeps that work id and
           generation with the section; a record deleted or recreated since reads `replaced`, and
           Show refuses to send until a deliberate rebind — a reply is never retargeted.
  submit   on Send: captures the literal text under its stable id against that frozen binding,
           numbered next in the conversation (capture is the acceptance boundary, so the journal's
           order is the source order and coverage is complete), and routes it. Fast.
  deliver  then, separately: dispatches through the outbox; slow transports don't hold capture.

Show keeps every submission by id until it is captured and clears a draft only if it is still the
revision that was sent, so a crash, a retry or a quick second reply never loses or doubles one. The deck's
thread file is a projection Show writes afterwards for the worker to read; it is never read back
as input, and nothing another writer puts there becomes direction.
"""
import os

from . import todo, workdelivery, workjournal as wj

SOURCE = "show"


def conversation(deck, section):
    return f"{os.path.realpath(deck)}#{section}"


def bind(journal, *, deck, section, todo_id, rebind=False):
    """Opens (or re-reads) a work-bound section's conversation. On first use — or a deliberate
    rebind — binds it to the work of the tracker record's current incarnation. Afterwards the
    binding stands: `replaced` says the record it directs was deleted or recreated since, and
    Show refuses to send until someone rebinds."""
    journal.register_source(SOURCE, adapter="show-composer", ordering="sequence")
    conv = conversation(deck, section)
    b = journal.binding(SOURCE, conv)
    if b and b["excluded"]:
        raise wj.NotCollected(f"{conv} is excluded from collection")
    try:
        item = todo.read(todo_id)
    except (OSError, ValueError):
        item = None
    current = (item or {}).get("incarnation")
    if not b or not b["works"] or rebind:
        if not current:
            raise wj.JournalError(f"tracker item {todo_id} has no record with an incarnation (canopy-todo enroll {todo_id})")
        w = journal.work_for_todo(todo_id, current, create=True, title=item.get("title"), project=item.get("project"),
                                  branch=item.get("solved_by"))
        gen = journal.bind(SOURCE, conv, [w], by="show rebind" if rebind else "show")
        b = journal.binding(SOURCE, conv)
    w = journal.work(b["works"][0])
    replaced = bool(w["retired_at"]) or w["todo_id"] != todo_id or w["todo_incarnation"] != current
    return {"conversation": conv, "work_id": w["work_id"], "todo": w["todo_id"], "incarnation": w["todo_incarnation"],
            "generation": b["generation"], "replaced": replaced}


def submit(journal, envelope, *, target, note=None, host=None):
    """Captures one submitted reply under the binding Show froze when the section was opened, and
    routes it to the worker. Fast: delivery is `deliver`. Raises JournalError if it can't be
    captured (Show keeps the draft)."""
    for k in ("message_id", "text", "deck", "section", "work_id"):
        if not isinstance(envelope.get(k), str) or not envelope[k]:
            raise wj.JournalError(f"the submission has no {k}")
    gen = envelope.get("generation")
    if not isinstance(gen, int):
        raise wj.JournalError("the submission has no binding generation")
    journal.register_source(SOURCE, adapter="show-composer", ordering="sequence")
    conv = conversation(envelope["deck"], envelope["section"])
    b = journal.binding(SOURCE, conv)
    if b is None:
        raise wj.NotCollected(f"{conv} was never opened for work")
    if b["excluded"]:
        raise wj.NotCollected(f"{conv} is excluded from collection")
    if envelope["work_id"] not in journal.generation_works(SOURCE, conv, gen):
        raise wj.Conflict(f"binding generation {gen} of {conv} doesn't direct {envelope['work_id']}; not captured")
    if host:
        workdelivery.HeadlessClaudeTransport.register(journal, host["session"], cwd=host["cwd"], allowed_tools=host["allowed_tools"],
                                                      boot_prompt=host.get("boot_prompt", ""))
    r = journal.capture(source=SOURCE, conversation=conv, source_message_id=envelope["message_id"], text=envelope["text"],
                        source_seq="next", source_time=envelope.get("sent_at"), accepted_generation=gen, target=target, note=note)
    if r["outbox_id"] is None:
        r["outbox_id"] = journal.route(r["message_id"], target, note)
    seq = journal.message(r["message_id"])["source_seq"]
    journal.cover(SOURCE, conv, seq)
    return {"message_id": r["message_id"], "source_message_id": envelope["message_id"], "seq": seq, "duplicate": r["duplicate"],
            "works": r["works"], "outbox_id": r["outbox_id"]}


def deliver(journal, outbox_id, *, retry=False, transports=None):
    """Dispatches due deliveries and reports this one's state. `retry` is a deliberate resend."""
    row = next((o for o in journal.outbox() if o["outbox_id"] == outbox_id), None)
    if row is None:
        raise wj.JournalError(f"no delivery {outbox_id}")
    if retry:
        if row["state"] in ("uncertain", "abandoned"):
            journal.requeue(outbox_id, by="show retry")
        journal.hurry(row["message_id"])
    results = workdelivery.dispatch(journal, transports if transports is not None else workdelivery.transports(), target=row["target"])
    row = next(o for o in journal.outbox() if o["outbox_id"] == outbox_id)
    receipt = next(iter(reversed(journal.receipts(outbox_id=outbox_id))), None)
    return {"dispatched": results, "delivery": {"outbox_id": outbox_id, "message_id": row["message_id"], "state": row["state"],
                                                "error": row["last_error"], "receipt_id": receipt["receipt_id"] if receipt else None,
                                                "receipt": receipt["state"] if receipt else None}}


def turn_state(journal, receipt_id):
    """How the worker turn for a receipt is going, observed now without writing: running,
    succeeded, failed, lost (its process vanished without a record), unknown — or none when no
    owned turn was started."""
    t = journal.turn(receipt_id)
    if t is None:
        return {"state": "none"}
    if t["outcome"] == "running":
        obs = {o["receipt_id"]: o["observed"] for o in workdelivery.HeadlessClaudeTransport.observe(journal, t["worker"], record=False)}
        return {"state": obs.get(receipt_id, "unknown"), "pid": t["pid"]}
    return {"state": t["outcome"], "exit_code": t["exit_code"], "detail": t["detail"]}


def recover(journal, *, deck, sections, transports=None):
    """What Show runs when it opens a work-bound deck: resumes each section's safe pending
    deliveries (captured before a crash, or queued behind a turn that has ended), lets an expired
    lease be reconciled rather than resent, and reports every section's newest delivery and its
    turn. Uncertain deliveries are reported, never resent; that takes a deliberate retry."""
    convs = {s: conversation(deck, s) for s in sections}
    targets = {o["target"] for s, c in convs.items() for o in journal.conversation_outbox(SOURCE, c)
               if o["state"] in ("pending", "leased")}
    tr = transports if transports is not None else workdelivery.transports()
    dispatched = [r for t in sorted(targets) for r in workdelivery.dispatch(journal, tr, target=t)]
    out = {}
    for s, c in convs.items():
        rows = journal.conversation_outbox(SOURCE, c)
        if not rows:
            continue
        row = rows[-1]
        receipt = next(iter(reversed(journal.receipts(outbox_id=row["outbox_id"]))), None)
        out[s] = {"outbox_id": row["outbox_id"], "message_id": row["message_id"], "target": row["target"], "state": row["state"],
                  "error": row["last_error"],
                  "receipt_id": receipt["receipt_id"] if receipt else None, "receipt": receipt["state"] if receipt else None,
                  "turn": turn_state(journal, receipt["receipt_id"]) if receipt else {"state": "none"}}
    return {"sections": out, "dispatched": dispatched}
