import { createSignal, createMemo, createEffect, on, Show, For, type JSX } from "solid-js";
import * as Diff2Html from "diff2html";
import { ColorSchemeType } from "diff2html/lib/types";
import { withRepo, canMutate } from "./provider";
import { isBlessed } from "./shared";
import { threadWorking, threadUnseenDone, threadMsgCount } from "./chatStore";
import type { FileDiff, Commit } from "./types";

function patchLineCounts(patch: string): { add: number; del: number } {
  let add = 0, del = 0;
  for (const line of patch.split("\n")) {
    if (line.startsWith("+") && !line.startsWith("+++")) add++;
    else if (line.startsWith("-") && !line.startsWith("---")) del++;
  }
  return { add, del };
}

export function DirtyRail(props: {
  dirty: { path: string; code: string; patch: string }[];
  worktree: string;
  branch: string;
  bless: { mutate: (file: string) => void };
  onCommit: (receipt?: string) => void;
  onChat: (f: FileDiff) => void;
}) {
  const [msg, setMsg] = createSignal("");
  const [err, setErr] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [showForm, setShowForm] = createSignal(false);
  let inputEl: HTMLInputElement | undefined;

  // the other half of "commit or stash first": set the whole working tree aside (incl.
  // untracked) so a blocked squash/prep gets its clean checkout — recoverable via git stash pop.
  const stashAll = async () => {
    setBusy(true);
    setErr("");
    try {
      const r = await fetch(withRepo("/dirty-resolve"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: props.branch, action: "stash" }),
      });
      const j = await r.json();
      if (!j.ok) { setErr(j.err ?? "stash failed"); return; }
      props.onCommit("✓ stashed all uncommitted changes — pop them back with git stash pop");
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const submit = async () => {
    if (!msg().trim()) return;
    setBusy(true);
    setErr("");
    try {
      const r = await fetch(withRepo("/commit-dirty"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: props.branch, message: msg().trim() }),
      });
      const j = await r.json();
      if (!j.ok) { setErr(j.err ?? "commit failed"); return; }
      setMsg("");
      setShowForm(false);
      props.onCommit("✓ all uncommitted changes committed to the branch");
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="uncommitted-rail">
      <div class="ur-head">
        <span class="ur-label">± uncommitted — working tree only</span>
        <span class="ur-wt">{props.worktree.replace(/.*\//, "")}</span>
        <button
          class="ur-stash-btn"
          title="stash all uncommitted changes (incl. untracked) — clears the tree for a blocked squash; recover with git stash pop"
          disabled={busy()}
          onClick={stashAll}
        >
          ⇤ stash all
        </button>
        <button
          class="ur-commit-btn"
          title="commit all uncommitted changes to this branch"
          onClick={() => { setShowForm((v) => !v); setTimeout(() => inputEl?.focus(), 0); }}
        >
          {showForm() ? "✕" : "↓ commit"}
        </button>
      </div>
      <Show when={showForm()}>
        <div class="ur-commit-form">
          <input
            ref={inputEl}
            class="ur-commit-input"
            placeholder="commit message…"
            value={msg()}
            onInput={(e) => setMsg(e.currentTarget.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } }}
            disabled={busy()}
          />
          <button class="ur-commit-go" onClick={submit} disabled={busy() || !msg().trim()}>
            {busy() ? "…" : "commit"}
          </button>
        </div>
        <Show when={err()}>
          <div class="ur-commit-err">{err()}</div>
        </Show>
      </Show>
      <For each={props.dirty}>
        {(f) => <DirtFile f={f} branch={props.branch} bless={props.bless} onChat={props.onChat} onDone={props.onCommit} />}
      </For>
    </div>
  );
}

// One dirty file with its verdict: accept (commit just this file, message inline) or
// reject (tracked → restore to HEAD, untracked → delete; armed — it destroys work).
function DirtFile(props: {
  f: { path: string; code: string; patch: string };
  branch: string;
  bless: { mutate: (file: string) => void };
  onChat: (f: FileDiff) => void;
  onDone: (receipt?: string) => void;
}) {
  const [form, setForm] = createSignal(false);
  const [msg, setMsg] = createSignal("");
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [err, setErr] = createSignal("");
  let disarm: ReturnType<typeof setTimeout>;
  let inputEl: HTMLInputElement | undefined;
  const post = async (url: string, body: unknown) => {
    setBusy(true);
    setErr("");
    try {
      const r = await fetch(withRepo(url), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const j = await r.json();
      if (!j.ok) {
        setErr(j.err ?? "failed");
        return;
      }
      const name = props.f.path.replace(/.*\//, "");
      props.onDone(
        url === "/discard-dirty"
          ? `✕ ${name} ${j.was === "tracked" ? "restored to HEAD" : "deleted"} — the uncommitted change is gone`
          : `✓ ${name} committed to the branch`,
      );
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };
  const reject = () => {
    if (!armed()) {
      setArmed(true);
      clearTimeout(disarm);
      disarm = setTimeout(() => setArmed(false), 5000);
      return;
    }
    clearTimeout(disarm);
    setArmed(false);
    post("/discard-dirty", { branch: props.branch, path: props.f.path });
  };
  return (
    <div class="ur-file">
      <div class="ur-file-acts">
        <Show
          when={!form()}
          fallback={
            <>
              <input
                ref={inputEl}
                class="ur-commit-input"
                placeholder={`message for ${props.f.path.replace(/.*\//, "")}…`}
                value={msg()}
                onInput={(e) => setMsg(e.currentTarget.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && msg().trim()) {
                    e.preventDefault();
                    post("/commit-dirty", { branch: props.branch, message: msg().trim(), path: props.f.path });
                  }
                  if (e.key === "Escape") { e.stopPropagation(); setForm(false); }
                }}
                disabled={busy()}
              />
              <button
                class="ur-commit-go"
                disabled={busy() || !msg().trim()}
                onClick={() => post("/commit-dirty", { branch: props.branch, message: msg().trim(), path: props.f.path })}
              >
                {busy() ? "…" : "commit"}
              </button>
              <button class="ur-file-x" onClick={() => setForm(false)}>✕</button>
            </>
          }
        >
          <button
            class="ur-file-accept"
            disabled={busy()}
            title="accept — commit just this file to the branch (message next)"
            onClick={() => { setForm(true); setTimeout(() => inputEl?.focus(), 0); }}
          >
            ✓ accept
          </button>
          <button
            class="ur-file-reject"
            classList={{ armed: armed() }}
            disabled={busy()}
            title="reject — a tracked file restores to HEAD, an untracked one is deleted. This destroys the uncommitted work; two clicks."
            onClick={reject}
          >
            {busy() ? "…" : armed() ? "confirm: discard" : "✕ reject"}
          </button>
        </Show>
        <Show when={err()}>
          <span class="ur-commit-err">{err()}</span>
        </Show>
      </div>
      <FileEntry
        file={{ path: props.f.path, status: "dirty", patch: props.f.patch, ...patchLineCounts(props.f.patch) }}
        bless={props.bless}
        branch={props.branch}
        readOnly
        onChat={props.onChat}
      />
    </div>
  );
}

export function FileEntry(props: {
  file: FileDiff;
  blessed?: () => boolean;
  bless: { mutate: (file: string) => void };
  branch: string;
  readOnly?: boolean;
  onChat: (f: FileDiff) => void;
}) {
  const [foil, setFoil] = createSignal(false);
  const [copied, setCopied] = createSignal(false);
  // memo (not a bare accessor) so it only notifies on a real value change — a ⇧B on some *other*
  // row bumps the shared override signal but leaves this one's value alone, so the follow effect
  // below must not fire (it would clobber a manual expand/collapse).
  const blessed = createMemo(() => (props.blessed ? props.blessed() : isBlessed(props.file)));
  // a blessed file starts collapsed — it's reviewed with nothing new since (a changed-since-
  // blessed file reads as 'stale', not blessed), so it shouldn't cost screen space. Stale and
  // unblessed files start open.
  const [collapsed, setCollapsed] = createSignal(blessed());
  // follow bless state in place: ⇧B collapses this card, ⇧U expands it — no row teardown, so the
  // diff isn't re-rendered from scratch (defer skips the initial value, keeping manual toggles).
  createEffect(on(blessed, (b) => setCollapsed(b), { defer: true }));
  const chatWorking = () => threadWorking(props.branch, props.file.path);
  const chatUnseen = () => threadUnseenDone(props.branch, props.file.path);
  const doBless = () => {
    setFoil(true); // play the foil on the click; the steady gold lands as the override flips
    props.bless.mutate(props.file.path);
    setTimeout(() => setFoil(false), 750);
  };
  // Copy a paste-ready reference for dropping the file into a Claude conversation.
  const copyRef = async () => {
    try {
      await navigator.clipboard.writeText(`\`${props.file.path}\` (on branch \`${props.branch}\`)`);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      /* clipboard blocked (insecure origin / denied) — silently no-op */
    }
  };
  // a stale file (blessed once, changed since) can flip between its FULL diff and just the
  // delta past the blessed state — the part that's actually unreviewed.
  const tarnished = () => props.file.status === "stale" && !blessed();
  const [deltaView, setDeltaView] = createSignal(false);
  const shownPatch = () => (deltaView() && props.file.stale ? props.file.stale : props.file.patch);
  const html = () =>
    shownPatch()
      ? Diff2Html.html(shownPatch()!, {
          drawFileList: false,
          outputFormat: "side-by-side",
          matching: "lines",
          colorScheme: ColorSchemeType.DARK,
        })
      : `<p class="empty">no textual diff</p>`;
  const seg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0 ? <b>{p}</b> : [<span class="dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };
  return (
    <article class="entry" data-path={props.file.path} classList={{ blessed: blessed(), foil: foil() }}>
      <div class="entry-head">
        <button
          class="entry-toggle"
          title={collapsed() ? "expand" : "collapse"}
          onClick={() => setCollapsed((c) => !c)}
        >
          {collapsed() ? "▸" : "▾"}
        </button>
        <span class="gutter" classList={{ tarnish: tarnished() }}>{blessed() || foil() || tarnished() ? "✦" : ""}</span>
        <span class="path" onClick={() => setCollapsed((c) => !c)}>{seg(props.file.path)}</span>
        <span class="lines">
          <span class="add">+{props.file.add ?? 0}</span>
          <span class="del">−{props.file.del ?? 0}</span>
        </span>
        <Show when={tarnished() && props.file.stale}>
          <button
            class="file-act tarnish-chip"
            classList={{ on: deltaView() }}
            title="blessed once, changed since — flip between the full diff and just the delta past the blessed state (the unreviewed part)"
            onClick={() => { setDeltaView((v) => !v); setCollapsed(false); }}
          >
            {deltaView() ? "Δ vs blessed" : "✦ tarnished"}
          </button>
        </Show>
        <button
          class="file-act"
          title="copy a paste-ready file + branch reference for a Claude conversation"
          onClick={copyRef}
        >
          {copied() ? "copied ✓" : "⎘ copy ref"}
        </button>
        <Show when={threadMsgCount(props.branch, props.file.path) > 0}>
          <span class="chat-badge" title="this file has a chat thread">
            💬 {threadMsgCount(props.branch, props.file.path)}
          </span>
        </Show>
        <Show when={canMutate}>
          <button
            class="file-act chat-act"
            classList={{ working: chatWorking(), done: !chatWorking() && chatUnseen() }}
            title={
              chatWorking()
                ? "Claude is still answering on this file — click to watch"
                : chatUnseen()
                  ? "Claude finished while the drawer was closed — click to read"
                  : "chat about this file with Claude — streamed right here"
            }
            onClick={() => props.onChat(props.file)}
          >
            {chatWorking() ? "✦ working…" : chatUnseen() ? "✦ done ✓" : "✦ chat"}
          </button>
          <Show when={!props.readOnly}>
            <button class="bless-btn" disabled={blessed()} onClick={doBless}>
              {blessed() ? "blessed" : "bless ✦"}
            </button>
          </Show>
        </Show>
      </div>
      <Show when={!collapsed()}>
        <div class="diff" innerHTML={html()} />
      </Show>
    </article>
  );
}

export function CommitsList(props: { q: { data: Commit[] | undefined } }) {
  return (
    <Show when={props.q.data} fallback={<p class="loading">loading…</p>}>
      {(data) => (
        <Show
          when={data().length}
          fallback={<p class="loading">no commits on this branch</p>}
        >
          <ol class="commits">
            <For each={data()}>
              {(c) => (
                <li class="commit">
                  <span class="c-sha">{c.sha}</span>
                  <span class="c-subject">{c.subject}</span>
                  <span class="c-meta">{c.author} · {c.date}</span>
                </li>
              )}
            </For>
          </ol>
        </Show>
      )}
    </Show>
  );
}
