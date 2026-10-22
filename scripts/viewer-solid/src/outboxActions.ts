// The outbox's three writes — push, hold, landing title — each pinned to the row's own repo: the
// outbox spans repos, so the URL path can't carry one the way withRepo() reads it on a forest page.
import { createSignal } from "solid-js";
import { useQueryClient } from "@tanstack/solid-query";
import { knownRepos } from "./router";
import { fetchJSON } from "./api";
import type { OutboxData } from "./outboxModel";

export const atRepo = (repo: string, path: string): string =>
  repo && knownRepos().has(repo) ? "/" + encodeURIComponent(repo) + path : path;

export const outboxUrl = (project?: string, repo?: string): string =>
  "/outbox" + (project ? "?project=" + encodeURIComponent(project) + (repo ? "&repo=" + encodeURIComponent(repo) : "") : "");

export const fetchOutbox = (project?: string, repo?: string) => fetchJSON<OutboxData>(outboxUrl(project, repo));

async function postJSON<T>(url: string, body: unknown): Promise<T> {
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const text = await r.text();
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`HTTP ${r.status}${text ? ": " + text.slice(0, 200) : ""}`);
  }
}

export interface PushResult { ok?: boolean; err?: string; web?: string }

export function useOutboxActions() {
  const qc = useQueryClient();
  const [busy, setBusy] = createSignal<string | null>(null);
  const [flash, setFlash] = createSignal<{ text: string; ok: boolean; link?: string } | null>(null);
  let flashTimer: ReturnType<typeof setTimeout> | undefined;
  const say = (text: string, ok: boolean, link?: string) => {
    clearTimeout(flashTimer);
    setFlash({ text, ok, link });
    flashTimer = setTimeout(() => setFlash(null), link ? 12_000 : 5_000);
  };
  const settle = () => qc.invalidateQueries({ queryKey: ["outbox"] });

  const push = async (repo: string, branch: string, compareUrl?: string): Promise<boolean> => {
    setBusy("push:" + branch);
    try {
      const r = await postJSON<PushResult>(atRepo(repo, "/push-origin"), { branch, stay: true });
      if (r.ok) {
        say(`✓ pushed ${branch} — origin has it; open the PR next`, true, compareUrl);
      } else {
        say(`✗ ${branch}: ${r.err || "push refused"}`, false);
      }
      return !!r.ok;
    } catch (e) {
      say(`✗ ${branch}: ${(e as Error).message}`, false);
      return false;
    } finally {
      setBusy(null);
      settle();
    }
  };

  const hold = async (repo: string, target: { branch?: string; project?: string }, until: string) => {
    setBusy("hold:" + (target.branch ?? target.project));
    try {
      const r = await postJSON<{ ok?: boolean; err?: string }>(atRepo(repo, "/outbox-hold"), { ...target, until });
      if (!r.ok) say(`✗ ${r.err || "hold refused"}`, false);
    } finally {
      setBusy(null);
      settle();
    }
  };

  const setTitle = async (repo: string, branch: string, title: string) => {
    const r = await postJSON<{ ok?: boolean; err?: string }>(atRepo(repo, "/outbox-title"), { branch, title });
    if (!r.ok) say(`✗ ${r.err || "title not saved"}`, false);
    settle();
  };

  return { push, hold, setTitle, busy, flash, setFlash, say };
}

export type OutboxActions = ReturnType<typeof useOutboxActions>;
