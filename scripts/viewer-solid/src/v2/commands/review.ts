// The review page's commands: GitHub's review verbs (comment on a line or a range, start and finish a
// review, reply, resolve, apply a suggestion, mark a file viewed) with GitHub's keys where it has
// them (r reply, ⌘↵ / ⌘⇧↵ in the comment box, ^G a suggestion, t the file finder) and Helix's
// otherwise (j/k, n/N, ]/[, x extends, K and g d types). Every write is optimistic; GitHub writes go
// through srv/reviewdesk + srv/ghreview, which refuse anything but your keypress or click.
import { BASE, navigate, reviewPath } from "../router";
import { command, type Write } from "../registry";
import { view, world } from "../store";
import type { Comment, DraftComment, Thread } from "../types";
import { setMenuOpen, setSheetOpen, menuOpen, sheetOpen } from "../ui";
import { suggestionOf } from "../review/markdown";
import { atRepoPath, page as pg, short, sideLine, type Composer } from "../review/page";
import { definition, dismiss, hover, pop } from "../review/types";

const rid = () => Math.random().toString(36).slice(2, 12);
const iso = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");
const repoPath = (p: string) => atRepoPath(pg.target()?.repo ?? "", p);
const name = () => pg.target()?.name ?? "";
const viewer = () => pg.conv()?.viewer || "you";
const thread = (id: string | undefined) => (id ? (view("thread", id) as Thread | undefined) : undefined);
const onFiles = () => pg.tab() === "files" && !pg.overlay();

// ── moving ──

const idx = () => {
  const h = pg.here();
  return h ? pg.stopIndex().get(h.key) ?? 0 : 0;
};
const goTo = (i: number) => {
  const s = pg.stops();
  if (!s.length) return;
  pg.setCursor(s[Math.max(0, Math.min(s.length - 1, i))].key);
  dismiss();
};
const seek = (dir: 1 | -1, ok: (k: string) => boolean) => () => {
  const s = pg.stops();
  for (let i = idx() + dir; i >= 0 && i < s.length; i += dir) {
    if (ok(s[i].key)) return goTo(i);
  }
  throw new Error(dir > 0 ? "nothing further down" : "nothing further up");
};

const nav = (id: string, title: string, keys: string[], local: () => void) =>
  command({ id, title, scope: "review", budget: "local", keys, quiet: true, available: onFiles, local });

nav("review.down", "Next line", ["j", "down"], () => {
  pg.setMark(undefined);
  goTo(idx() + 1);
});
nav("review.up", "Previous line", ["k", "up"], () => {
  pg.setMark(undefined);
  goTo(idx() - 1);
});
command({ id: "review.thread.next", title: "Next conversation", scope: "review", budget: "local", keys: ["n"], available: onFiles, local: seek(1, (k) => k.startsWith("t|")) });
command({ id: "review.thread.prev", title: "Previous conversation", scope: "review", budget: "local", keys: ["N"], available: onFiles, local: seek(-1, (k) => k.startsWith("t|")) });
command({ id: "review.file.next", title: "Next file", scope: "review", budget: "local", keys: ["]"], available: onFiles, local: seek(1, (k) => k.startsWith("f|")) });
command({ id: "review.file.prev", title: "Previous file", scope: "review", budget: "local", keys: ["["], available: onFiles, local: seek(-1, (k) => k.startsWith("f|")) });
nav("review.top", "First line", ["g g"], () => goTo(0));
nav("review.bottom", "Last line", ["G"], () => goTo(pg.stops().length - 1));
command({
  id: "review.cursor.set",
  title: "Put the cursor here",
  scope: "review",
  budget: "local",
  quiet: true,
  local: (key, e) => {
    if (!key) return;
    const shift = (e as MouseEvent | undefined)?.shiftKey;
    const h = pg.here();
    if (shift && key.startsWith("l|") && h?.kind === "line") pg.setMark(pg.mark() ?? h.key);
    else pg.setMark(undefined);
    pg.setCursor(key);
    dismiss();
  },
});
command({
  id: "review.file.go",
  title: "Go to a file",
  scope: "review",
  budget: "local",
  quiet: true,
  local: (path) => {
    pg.setTab("files");
    pg.setFiltering(false);
    if (path) pg.setCursor(`f|${path}`);
  },
});
command({
  id: "review.extend",
  title: "Extend the selection a line (comment on a range)",
  scope: "line",
  budget: "local",
  keys: ["x"],
  local: () => {
    const h = pg.here();
    if (!h || h.kind !== "line") return;
    if (!pg.mark()) return void pg.setMark(h.key);
    const s = pg.stops();
    for (let i = idx() + 1; i < s.length && s[i].path === h.path; i++) {
      if (s[i].kind === "line") return void pg.setCursor(s[i].key);
    }
  },
});

// ── the page ──

command({ id: "review.tab", title: "Conversation ↔ Files changed", scope: "review", budget: "local", keys: ["tab"], local: () => pg.setTab(pg.tab() === "files" ? "conversation" : "files") });
command({ id: "review.tab.files", title: "Files changed", scope: "review", budget: "local", quiet: true, local: () => pg.setTab("files") });
command({ id: "review.tab.conversation", title: "Conversation", scope: "review", budget: "local", quiet: true, local: () => pg.setTab("conversation") });
command({ id: "review.split", title: "Split ↔ unified diff", scope: "review", budget: "local", keys: ["s"], local: () => pg.setSplit(!pg.split()) });
command({ id: "review.outdated", title: "Show outdated conversations", scope: "review", budget: "local", keys: ["O"], local: () => pg.setShowOutdated(!pg.showOutdated()) });
command({ id: "review.words", title: "The words (description, outline, landing title)", scope: "review", budget: "local", keys: ["e"], local: () => pg.setOverlay(pg.overlay() === "words" ? null : "words") });
command({ id: "review.map", title: "The forest map", scope: "review", budget: "local", keys: ["m"], local: () => pg.setOverlay(pg.overlay() === "map" ? null : "map") });
command({
  id: "review.map.go",
  title: "Open a branch from the map",
  scope: "review",
  budget: "local",
  quiet: true,
  local: (target, e) => {
    pg.setOverlay(null);
    const i = target?.indexOf(":") ?? -1;
    if (target && i > 0) navigate(reviewPath(target.slice(0, i), target.slice(i + 1)), e);
  },
});
command({ id: "review.filter", title: "Find a file", scope: "review", budget: "local", keys: ["t"], local: () => pg.setFiltering(true) });
command({ id: "review.leave", title: "Back to Forests", scope: "review", budget: "local", keys: ["h"], local: (_t, e) => navigate(BASE, e) });
command({
  id: "review.back",
  title: "Back out",
  scope: "review",
  budget: "local",
  keys: ["esc"],
  quiet: true,
  local: () => {
    if (menuOpen() || sheetOpen()) {
      setMenuOpen(false);
      setSheetOpen(false);
    } else if (pop()) dismiss();
    else if (pg.composer()) pg.setComposer(null);
    else if (pg.finishing()) pg.setFinishing(false);
    else if (pg.overlay()) pg.setOverlay(null);
    else if (pg.filtering()) pg.setFiltering(false);
    else if (pg.mark()) pg.setMark(undefined);
    else throw new Error("nothing to back out of — h goes back to Forests");
  },
});
command({ id: "review.types", title: "Show the type (hover)", scope: "review", budget: "local", keys: ["K"], available: onFiles, local: () => hover() });
command({
  id: "review.definition",
  title: "Go to definition",
  scope: "review",
  budget: "local",
  keys: ["g d"],
  available: onFiles,
  local: () =>
    definition((path, line) => {
      const key = pg.stops().find((s) => s.kind === "line" && s.path === path && s.row.right?.new === line)?.key;
      if (key) pg.setCursor(key);
      return !!key;
    }),
});
command({
  id: "review.open",
  title: "Open in Helix",
  scope: "review",
  budget: "slow-io",
  keys: ["o"],
  write: (): Write | null => {
    const h = pg.here();
    if (!h || h.kind === "file") return null;
    const line = h.kind === "line" ? sideLine(h.row).line : thread(h.id)?.local?.line ?? null;
    return { ops: [], path: repoPath("/open"), body: { branch: name(), path: h.path, line }, settled: () => true, failed: "couldn't open it in Helix" };
  },
});

// ── viewed ──

function viewedWrite(path: string): Write {
  const to = !pg.isViewed(path);
  const was = pg.viewedOverride();
  pg.setViewedOverride(new Map(was).set(path, to));
  if (to) {
    const vs = pg.views();
    const next = vs[vs.findIndex((v) => v.file.path === path) + 1];
    pg.setCursor(`f|${next ? next.file.path : path}`);
  }
  return {
    ops: [],
    path: repoPath("/bless"),
    body: { branch: name(), file: path, ...(to ? {} : { unbless: true }) },
    settled: () => true,
    failed: `couldn't mark ${path.split("/").pop()} ${to ? "viewed" : "unviewed"}`,
    rollback: () => pg.setViewedOverride(was),
    inverse: { id: "review.viewed.file", target: path },
  };
}
command({
  id: "review.viewed",
  title: "Mark the file viewed",
  scope: "review",
  budget: "config-write",
  keys: ["v"],
  available: () => onFiles() && !!pg.here(),
  write: () => viewedWrite(pg.here()!.path),
});
command({ id: "review.viewed.file", title: "Mark a file viewed", scope: "review", budget: "config-write", quiet: true, write: (path) => viewedWrite(path) });

// ── writing: comments, the pending review, replies ──

const lineComposer = (): Composer | null => {
  const r = pg.range();
  if (!r) return null;
  return { kind: "line", key: `c|${r.path}|${r.side}|${r.line}|${r.startLine ?? ""}`, path: r.path, side: r.side, line: r.line, startLine: r.startLine };
};
const canWrite = () => !!pg.conv();

command({
  id: "review.comment",
  title: "Comment on the line (or the range x selected)",
  scope: "line",
  budget: "local",
  keys: ["c"],
  available: canWrite,
  local: () => pg.setComposer(lineComposer()),
});
command({
  id: "review.gutter",
  hint: ["click +", "shift-click"],
  title: "Comment on this line",
  scope: "review",
  budget: "local",
  quiet: true,
  available: canWrite,
  local: (key, e) => {
    if (!key) return;
    const h = pg.here();
    if ((e as MouseEvent | undefined)?.shiftKey && h?.kind === "line") pg.setMark(pg.mark() ?? h.key);
    else pg.setMark(undefined);
    pg.setCursor(key);
    pg.setComposer(lineComposer());
  },
});
command({
  id: "review.say.open",
  title: "Comment on the conversation",
  scope: "review",
  budget: "local",
  keys: ["c"],
  available: () => canWrite() && pg.tab() === "conversation",
  local: () => pg.setComposer({ kind: "say", key: "say" }),
});

const take = (c: Composer) => {
  const body = pg.text(c.key).trim();
  if (!body) throw new Error("write something first");
  pg.setText(c.key, "");
  pg.setComposer(null);
  pg.setMark(undefined);
  return () => {
    pg.setText(c.key, body);
    pg.setComposer(c);
  };
};

function draftAdd(c: DraftComment): Write {
  const d = pg.draft();
  const first = !d?.comments.length;
  return {
    ops: [{ type: "draft", id: pg.id(), fields: { comments: [...(d?.comments ?? []), c] } }],
    path: repoPath("/review-draft"),
    body: { branch: name(), op: "add", comment: c },
    settled: () => !!world.entities.draft[pg.id()]?.comments.some((x) => x.id === c.id),
    said: first ? "review started — S finishes it" : undefined,
    failed: "the comment didn't save",
    inverse: { id: "review.pending.remove", target: c.id },
  };
}

command({
  id: "review.compose.review",
  hint: ["⌘↵"],
  title: "Start a review (or add to it)",
  scope: "review",
  budget: "config-write",
  available: () => pg.composer()?.kind === "line",
  write: (): Write | null => {
    const c = pg.composer();
    if (c?.kind !== "line") return null;
    const body = pg.text(c.key).trim();
    const restore = take(c);
    return { ...draftAdd({ id: rid(), path: c.path, side: c.side, line: c.line, startLine: c.startLine, body, at: iso() }), rollback: restore };
  },
});
command({
  id: "review.pending.remove",
  title: "Delete the pending comment",
  scope: "pending",
  budget: "config-write",
  keys: ["d"],
  available: (id) => !!pg.draft()?.comments.some((c) => c.id === id),
  write: (id) => {
    const d = pg.draft()!;
    const c = d.comments.find((x) => x.id === id)!;
    return {
      ops: [{ type: "draft", id: pg.id(), fields: { comments: d.comments.filter((x) => x.id !== id) } }],
      path: repoPath("/review-draft"),
      body: { branch: name(), op: "remove", comment: { id } },
      settled: () => !world.entities.draft[pg.id()]?.comments.some((x) => x.id === id),
      said: "pending comment deleted — u puts it back",
      failed: "couldn't delete the pending comment",
      inverse: { id: "review.pending.restore", target: pg.id(), arg: c },
    };
  },
});
command({ id: "review.pending.restore", title: "Put a pending comment back", scope: "review", budget: "config-write", quiet: true, write: (_t, arg) => draftAdd(arg as DraftComment) });

command({
  id: "review.compose.single",
  hint: ["⌘⇧↵"],
  title: "Add single comment",
  scope: "review",
  budget: "slow-io",
  available: () => pg.composer()?.kind === "line",
  write: (): Write | null => {
    const c = pg.composer();
    if (c?.kind !== "line") return null;
    const body = pg.text(c.key).trim();
    const restore = take(c);
    const d = pg.draft();
    const sent: DraftComment = { id: rid(), path: c.path, side: c.side, line: c.line, startLine: c.startLine, body, at: iso(), single: true };
    return {
      ops: d ? [{ type: "draft", id: pg.id(), fields: { sending: [...(d.sending ?? []), sent] } }] : [],
      path: repoPath("/review-comment"),
      body: { branch: name(), path: c.path, side: c.side, line: c.line, startLine: c.startLine, body },
      settled: () => Object.values(world.entities.thread).some((t) => t.branch === name() && t.path === c.path && t.comments[0]?.body === body),
      failed: "the comment didn't post",
      rollback: restore,
    };
  },
});

const unpushedNamed = (body: string): string[] => {
  const un = pg.conv()?.unpushed ?? [];
  return [...new Set((body.match(/\b[0-9a-f]{7,40}\b/g) ?? []).flatMap((w) => un.filter((s) => s.startsWith(w))))];
};

command({
  id: "review.compose.reply",
  hint: ["⌘↵"],
  title: "Reply",
  scope: "review",
  budget: "slow-io",
  available: () => pg.composer()?.kind === "reply",
  write: (): Write | null => {
    const c = pg.composer();
    if (c?.kind !== "reply") return null;
    const t = thread(c.threadId);
    if (!t) return null;
    const body = pg.text(c.key).trim();
    const restore = take(c);
    const waits = unpushedNamed(body);
    const mine: Comment = { id: `local-${rid()}`, author: viewer(), body, at: iso(), url: "", sending: waits.length ? "waits" : "posting" };
    return {
      ops: [{ type: "thread", id: t.id, fields: { comments: [...t.comments, mine] } }],
      path: repoPath("/review-reply"),
      body: { branch: name(), thread: t.node, body },
      settled: () =>
        !!world.entities.thread[t.id]?.comments.some((x) => x.body === body) ||
        Object.values(world.entities.queued).some((q) => q.threadId === t.id && q.body === body),
      said: waits.length ? `waits for ${waits.map(short).join(", ")} to reach origin — d lets go` : undefined,
      failed: "the reply didn't post",
      rollback: restore,
    };
  },
});
command({
  id: "review.compose.say",
  hint: ["⌘↵"],
  title: "Comment",
  scope: "review",
  budget: "slow-io",
  available: () => pg.composer()?.kind === "say",
  write: (): Write | null => {
    const c = pg.composer();
    const cv = pg.conv();
    if (c?.kind !== "say" || !cv) return null;
    const body = pg.text(c.key).trim();
    const restore = take(c);
    return {
      ops: [{ type: "conv", id: cv.id, fields: { comments: [...cv.comments, { id: `local-${rid()}`, author: viewer(), body, at: iso(), url: "", sending: "posting" }] } }],
      path: repoPath("/review-say"),
      body: { branch: name(), body },
      settled: () => !!world.entities.conv[cv.id]?.comments.some((x) => x.body === body),
      failed: "the comment didn't post",
      rollback: restore,
    };
  },
});
command({ id: "review.compose.cancel", hint: ["esc"], title: "Cancel the comment", scope: "review", budget: "local", quiet: true, local: () => {
    const c = pg.composer();
    if (c) pg.setText(c.key, "");
    pg.setComposer(null);
  } });
command({
  id: "review.compose.suggest",
  hint: ["^G"],
  title: "Insert a suggestion",
  scope: "review",
  budget: "local",
  quiet: true,
  available: () => !!pg.composer() && pg.composer()!.kind !== "say",
  local: () => {
    const c = pg.composer()!;
    let lines: string[] = [];
    const fv = (path: string) => pg.fileOf(path);
    const grab = (path: string, from: number, to: number) =>
      (fv(path)?.rows ?? []).filter((r) => r.right && r.right.new! >= from && r.right.new! <= to && r.right.kind !== "del").map((r) => r.right!.text);
    if (c.kind === "line") lines = grab(c.path, c.startLine ?? c.line, c.line);
    else if (c.kind === "reply") {
      const t = thread(c.threadId);
      if (t?.local) lines = grab(t.path, t.local.startLine ?? t.local.line, t.local.line);
    }
    const cur = pg.text(c.key);
    pg.setText(c.key, `${cur}${cur && !cur.endsWith("\n") ? "\n" : ""}\`\`\`suggestion\n${lines.join("\n")}\n\`\`\`\n`);
  },
});

command({
  id: "review.reply",
  title: "Reply",
  scope: "thread",
  budget: "local",
  keys: ["r"],
  available: (id) => canWrite() && !!thread(id),
  local: (id) => {
    const t = thread(id)!;
    const key = `r|${t.id}`;
    if (!pg.text(key) && t.local?.addressedBy && pg.conv()?.unpushed.includes(t.local.addressedBy)) pg.setText(key, `Addressed in ${short(t.local.addressedBy)}: `);
    pg.setUnfold((m) => new Map(m).set(t.id, true));
    pg.setComposer({ kind: "reply", key, threadId: t.id });
  },
});
command({
  id: "review.note.insert",
  title: "Reply with the second reader's draft",
  scope: "thread",
  budget: "local",
  keys: ["i"],
  available: (id) => canWrite() && !!thread(id)?.note?.draftReply,
  local: (id) => {
    const t = thread(id)!;
    const key = `r|${t.id}`;
    pg.setText(key, t.note!.draftReply!);
    pg.setUnfold((m) => new Map(m).set(t.id, true));
    pg.setComposer({ kind: "reply", key, threadId: t.id });
  },
});
command({
  id: "review.fold",
  title: "Fold or unfold the conversation",
  scope: "thread",
  budget: "local",
  keys: ["ret"],
  local: (id) => {
    const t = thread(id);
    if (t) pg.setUnfold((m) => new Map(m).set(t.id, !pg.isOpen(t)));
  },
});
command({
  id: "review.note.toggle",
  title: "Open or fold the second reader's note",
  scope: "thread",
  budget: "local",
  keys: ["z"],
  available: (id) => !!thread(id)?.note,
  local: (id) => {
    const k = `note:${id}`;
    pg.setUnfold((m) => new Map(m).set(k, !(m.get(k) ?? false)));
  },
});
command({
  id: "review.thread.show",
  title: "Show the conversation at its line",
  scope: "review",
  budget: "local",
  quiet: true,
  local: (id) => {
    const t = thread(id);
    if (!t) return;
    pg.setTab("files");
    if (t.outdated) pg.setShowOutdated(true);
    pg.setUnfold((m) => new Map(m).set(t.id, true));
    pg.setCursor(`t|${t.id}`);
  },
});
command({
  id: "review.resolve",
  title: "Resolve / unresolve conversation",
  scope: "thread",
  budget: "slow-io",
  keys: ["R"],
  available: (id) => {
    const t = thread(id);
    return !!t && (t.resolved ? t.canUnresolve : t.canResolve);
  },
  write: (id) => {
    const t = thread(id)!;
    const to = !t.resolved;
    pg.setUnfold((m) => {
      const n = new Map(m);
      n.delete(t.id);
      return n;
    });
    return {
      ops: [{ type: "thread", id: t.id, fields: { resolved: to, canResolve: !to, canUnresolve: to } }],
      path: repoPath("/review-resolve"),
      body: { branch: name(), thread: t.node, resolved: to },
      settled: () => world.entities.thread[t.id]?.resolved === to,
      said: to ? "resolved — u reopens it" : undefined,
      failed: to ? "couldn't resolve it" : "couldn't reopen it",
      inverse: { id: "review.resolve", target: t.id },
    };
  },
});
command({
  id: "review.apply",
  title: "Apply suggestion (a local commit)",
  scope: "thread",
  budget: "git-write",
  keys: ["a"],
  available: (id) => {
    const t = thread(id);
    return !!t && !t.outdated && t.side === "RIGHT" && !t.local?.addressedBy && !t.applying && t.comments.some((c) => suggestionOf(c.body) !== null);
  },
  write: (id) => {
    const t = thread(id)!;
    const tip = pg.tip();
    return {
      ops: [{ type: "thread", id: t.id, fields: { applying: true } }],
      path: repoPath("/review-apply"),
      body: { branch: name(), thread: t.node },
      settled: () => !!world.entities.thread[t.id]?.local?.addressedBy || (world.entities.conv[pg.id()]?.tip ?? tip) !== tip,
      said: "applied as a local commit — u drops it",
      failed: "couldn't apply the suggestion",
      inverse: (ans) => (typeof ans.sha === "string" ? { id: "review.unapply", target: pg.id(), arg: ans.sha } : undefined),
    };
  },
});
command({
  id: "review.unapply",
  title: "Drop the applied suggestion's commit",
  scope: "review",
  budget: "git-write",
  quiet: true,
  write: (_t, arg) => {
    const sha = String(arg);
    return {
      ops: [],
      path: repoPath("/revert-commit"),
      body: { branch: name(), sha },
      settled: () => (world.entities.conv[pg.id()]?.tip ?? world.entities.branch[pg.id()]?.tip) !== sha,
      said: `dropped ${short(sha)}`,
      failed: `couldn't drop ${short(sha)}`,
    };
  },
});
command({
  id: "review.queue.cancel",
  title: "Let go of the reply waiting for a push",
  scope: "thread",
  budget: "config-write",
  keys: ["d"],
  available: (id) => pg.queued().some((q) => q.threadId === id && q.state !== "posting"),
  write: (id) => {
    const q = pg.queued().find((x) => x.threadId === id && x.state !== "posting")!;
    return {
      ops: [{ type: "queued", id: q.id, fields: { cancelled: true } }],
      path: repoPath("/review-queue"),
      body: { id: q.id, op: "cancel" },
      settled: () => !world.entities.queued[q.id],
      said: "the waiting reply is let go",
      failed: "couldn't let go of the reply",
    };
  },
});

// ── finishing the review ──

command({
  id: "review.finish",
  title: "Finish your review",
  scope: "review",
  budget: "local",
  keys: ["S"],
  available: canWrite,
  local: () => pg.setFinishing(true),
});
for (const [ev, title] of [["COMMENT", "Comment"], ["APPROVE", "Approve"], ["REQUEST_CHANGES", "Request changes"]] as const) {
  command({ id: `review.event.${ev}`, title: `Finish as ${title}`, scope: "review", budget: "local", quiet: true, local: () => pg.setEvent(ev) });
}
command({
  id: "review.submit",
  hint: ["⌘↵"],
  title: "Submit review",
  scope: "review",
  budget: "slow-io",
  available: () => canWrite() && pg.finishing(),
  write: (): Write | null => {
    const cv = pg.conv();
    if (!cv) return null;
    const ev = pg.event();
    const body = pg.text("finish").trim();
    if (ev !== "APPROVE" && !body && !pg.draft()?.comments.length) throw new Error("say something, or add a comment, before finishing");
    const before = cv.reviews.length;
    pg.setText("finish", "");
    pg.setFinishing(false);
    return {
      ops: [
        { type: "draft", id: pg.id(), fields: { submitting: ev } },
        { type: "conv", id: cv.id, fields: { reviews: [...cv.reviews, { id: `local-${rid()}`, author: viewer(), state: { COMMENT: "COMMENTED", APPROVE: "APPROVED", REQUEST_CHANGES: "CHANGES_REQUESTED" }[ev], body, at: iso(), url: "", sending: true }] } },
      ],
      path: repoPath("/review-submit"),
      body: { branch: name(), event: ev, body },
      settled: () => (world.entities.conv[cv.id]?.reviews.length ?? 0) > before && !world.entities.draft[cv.id]?.comments.length,
      said: "review submitted",
      failed: "the review didn't submit",
      rollback: () => {
        pg.setText("finish", body);
        pg.setFinishing(true);
      },
    };
  },
});

/** Open a branch's review page (Forests' ↵ on a branch, and the map). */
export const openReview = (repo: string, branch: string, e?: Event) => navigate(reviewPath(repo, branch), e);
