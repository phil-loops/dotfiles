// The review page's commands: GitHub's review verbs (comment on a line or a range, reply, apply a
// suggestion, mark a file viewed) with GitHub's keys where it has them (r reply, ⌘↵ in the comment
// box, ^G a suggestion, t the file finder) and Helix's otherwise (j/k, n/N, ]/[, x extends, K and
// g d types). What Phil writes lands in the ledger (srv/reviewdesk.py) and, on his keypress, in his
// PENDING review on GitHub — submitting it, and resolving, happen on GitHub, which S and R open.
import { BASE, forestPath, navigate, reviewPath } from "../router";
import { command, type Write } from "../registry";
import { view, world } from "../store";
import type { Item, Thread } from "../types";
import { setCursor, setMenuOpen, setSheetOpen, menuOpen, sheetOpen } from "../ui";
import { bkey } from "../model";
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
command({
  id: "review.forest",
  title: "Open this branch's forest page",
  scope: "review",
  budget: "local",
  keys: ["g p"],
  available: (id) => !!id && !!view("project", view("branch", id)?.project ?? ""),
  local: (id, e) => {
    const p = view("project", view("branch", id!)!.project)!;
    setCursor(bkey(id!));
    navigate(forestPath(p.repo, p.name), e);
  },
});
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
  // the bless ledger hashes the file's blob through stack-bless: a git read, not a config write
  budget: "git-write",
  keys: ["v"],
  available: () => onFiles() && !!pg.here(),
  write: () => viewedWrite(pg.here()!.path),
});
command({ id: "review.viewed.file", title: "Mark a file viewed", scope: "review", budget: "git-write", quiet: true, write: (path) => viewedWrite(path) });

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
  title: "Comment on this line",
  hint: ["click +", "shift-click"],
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

const unpushedNamed = (body: string): string[] => {
  const un = pg.conv()?.unpushed ?? [];
  return [...new Set((body.match(/\b[0-9a-f]{7,40}\b/g) ?? []).flatMap((w) => un.filter((s) => s.startsWith(w))))];
};

/** The composer's words as a new ledger item; send: on to the pending review, else a draft. */
function addItem(send: boolean): Write | null {
  const c = pg.composer();
  const d = pg.draft();
  if (!c || !d) return null;
  const body = pg.text(c.key).trim();
  if (!body) throw new Error("write something first");
  const waits = unpushedNamed(body);
  const base = { key: rid(), body, err: null, send, at: iso(), waitsFor: waits, state: (waits.length ? "waiting" : send ? "sending" : "draft") as Item["state"] };
  const t = c.kind === "reply" ? thread(c.threadId) : undefined;
  const item: Item =
    c.kind === "line"
      ? { ...base, kind: "comment", path: c.path, side: c.side, line: c.line, startLine: c.startLine }
      : { ...base, kind: "reply", thread: t?.node, threadId: c.threadId };
  pg.setText(c.key, "");
  pg.setComposer(null);
  pg.setMark(undefined);
  const restore = () =>
    window.setTimeout(() => {
      if (world.entities.draft[pg.id()]?.items.some((i) => i.key === item.key)) return;
      pg.setText(c.key, body);
      pg.setComposer(c);
    }, 400);
  return {
    ops: [{ type: "draft", id: pg.id(), fields: { items: [...d.items, item] } }],
    path: repoPath("/review-draft"),
    body: { branch: name(), op: "add", send, item: { key: item.key, kind: item.kind, path: item.path, side: item.side, line: item.line, startLine: item.startLine, thread: item.thread, body } },
    settled: () => {
      const got = world.entities.draft[pg.id()]?.items.find((i) => i.key === item.key);
      return !!got && got.state !== "sending";
    },
    said: waits.length ? `kept as a draft until ${waits.map(short).join(", ")} is on origin — d drops it` : send ? "in your pending review — S opens GitHub to submit it" : "saved as a draft — p sends it",
    failed: send ? "kept as a draft, not on GitHub" : "the draft didn't save",
    rollback: restore,
    ...(send ? {} : { inverse: { id: "review.pending.remove", target: item.key } }),
  };
}

command({
  id: "review.compose.send",
  title: "Add to your pending review on GitHub",
  hint: ["⌘↵"],
  scope: "review",
  budget: "slow-io",
  available: () => !!pg.composer(),
  write: () => addItem(true),
});
command({
  id: "review.compose.draft",
  title: "Save as a draft (only here)",
  hint: ["⌘⇧↵"],
  scope: "review",
  budget: "config-write",
  available: () => !!pg.composer(),
  write: () => addItem(false),
});
command({
  id: "review.compose.cancel",
  title: "Cancel the comment",
  hint: ["esc"],
  scope: "review",
  budget: "local",
  quiet: true,
  local: () => {
    const c = pg.composer();
    if (c) pg.setText(c.key, "");
    pg.setComposer(null);
  },
});
command({
  id: "review.compose.suggest",
  title: "Insert a suggestion",
  hint: ["^G"],
  scope: "review",
  budget: "local",
  quiet: true,
  available: () => !!pg.composer(),
  local: () => {
    const c = pg.composer()!;
    let lines: string[] = [];
    const grab = (path: string, from: number, to: number) =>
      (pg.fileOf(path)?.rows ?? []).filter((r) => r.right && r.right.new! >= from && r.right.new! <= to && r.right.kind !== "del").map((r) => r.right!.text);
    if (c.kind === "line") lines = grab(c.path, c.startLine ?? c.line, c.line);
    else {
      const t = thread(c.threadId);
      if (t?.local) lines = grab(t.path, t.local.startLine ?? t.local.line, t.local.line);
    }
    const cur = pg.text(c.key);
    pg.setText(c.key, `${cur}${cur && !cur.endsWith("\n") ? "\n" : ""}\`\`\`suggestion\n${lines.join("\n")}\n\`\`\`\n`);
  },
});

const item = (key: string | undefined) => pg.draft()?.items.find((i) => i.key === key);
const unsent = (i: Item | undefined) => !!i && (i.state === "draft" || i.state === "waiting" || i.state === "gone");

command({
  id: "review.pending.remove",
  title: "Delete the draft",
  scope: "pending",
  budget: "config-write",
  keys: ["d"],
  available: (key) => unsent(item(key)),
  write: (key) => {
    const d = pg.draft()!;
    const it = item(key)!;
    return {
      ops: [{ type: "draft", id: pg.id(), fields: { items: d.items.filter((x) => x.key !== key) } }],
      path: repoPath("/review-draft"),
      body: { branch: name(), op: "remove", key },
      settled: () => !world.entities.draft[pg.id()]?.items.some((x) => x.key === key),
      said: "draft deleted — u puts it back",
      failed: "couldn't delete the draft",
      inverse: { id: "review.pending.restore", target: pg.id(), arg: it },
    };
  },
});
command({
  id: "review.pending.restore",
  title: "Put a draft back",
  scope: "review",
  budget: "config-write",
  quiet: true,
  write: (_t, arg) => {
    const it = arg as Item;
    const d = pg.draft()!;
    return {
      ops: [{ type: "draft", id: pg.id(), fields: { items: [...d.items, { ...it, state: "draft" as const }] } }],
      path: repoPath("/review-draft"),
      body: { branch: name(), op: "add", item: { key: it.key, kind: it.kind, path: it.path, side: it.side, line: it.line, startLine: it.startLine, thread: it.thread, body: it.body } },
      settled: () => !!world.entities.draft[pg.id()]?.items.some((x) => x.key === it.key),
      failed: "couldn't put the draft back",
    };
  },
});

function sendWrite(keys: string[]): Write | null {
  const d = pg.draft();
  if (!d || !keys.length) return null;
  return {
    ops: [{ type: "draft", id: pg.id(), fields: { items: d.items.map((i) => (keys.includes(i.key) && i.state === "draft" ? { ...i, state: "sending" as const, err: null } : i)) } }],
    path: repoPath("/review-draft"),
    body: { branch: name(), op: "send", keys },
    settled: () => !world.entities.draft[pg.id()]?.items.some((i) => keys.includes(i.key) && i.state === "sending"),
    said: "in your pending review — S opens GitHub to submit it",
    failed: "kept as a draft, not on GitHub",
  };
}
command({
  id: "review.send",
  title: "Send the draft to your pending review",
  scope: "pending",
  budget: "slow-io",
  keys: ["p"],
  available: (key) => item(key)?.state === "draft",
  write: (key) => sendWrite([key]),
});
command({
  id: "review.send.all",
  title: "Send every draft to your pending review",
  scope: "review",
  budget: "slow-io",
  keys: ["P"],
  available: () => (pg.draft()?.items ?? []).some((i) => i.state === "draft"),
  write: () => sendWrite((pg.draft()?.items ?? []).filter((i) => i.state === "draft").map((i) => i.key)),
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
  title: "Resolve on GitHub (opens the conversation there)",
  scope: "thread",
  budget: "local",
  keys: ["R"],
  available: (id) => !!thread(id)?.comments[0]?.url,
  local: (id) => void window.open(thread(id)!.comments[0].url, "_blank", "noopener"),
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

// ── submitting happens on GitHub ──

command({
  id: "review.finish",
  title: "Open on GitHub to submit your review",
  scope: "review",
  budget: "local",
  keys: ["S"],
  available: canWrite,
  local: () => void window.open(`${pg.conv()!.url}/files`, "_blank", "noopener"),
});

/** Open a branch's review page (Forests' ↵ on a branch, and the map). */
export const openReview = (repo: string, branch: string, e?: Event) => navigate(reviewPath(repo, branch), e);
