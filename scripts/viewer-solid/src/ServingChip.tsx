// ServingChip — the ambient answer to "what is that preview port actually serving?",
// sitting beside the server-status dot. Born 2026-09-07: review comments landed on PR
// footers-11 while :3011 served footers-10 — nothing bound the diff being read to the
// branch being served. Closed-state of the foreign-forests switcher (wiki: foreign-forests);
// clicking lands on the Machine page until the slice-3 walk rail exists.
//
// Quiet grammar: renders ONLY while a non-main preview is alive; faint ink when the served
// branch matches the diff on screen (or nothing relevant is on screen); ember ⚠ when they
// disagree (the will-ambush case); del ⚠ when the port's own X-Dev-Worktree claim disagrees
// with the preview registry — the port is not what the card says.
import { Show } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { canMutate } from "./provider";
import { useViewerLocation } from "./router";

type Preview = {
  name: string;
  port: string;
  branch?: string;
  health: string;
  serves?: string; // the server's own X-Dev-Worktree claim: "<branch>@<sha> <path>"
  servesMismatch?: boolean;
};
type PreviewsResp = { ok: boolean; previews: Preview[] };

// states where a port is (or is about to be) answering — dead/orphaned rows say nothing
const ALIVE = new Set(["healthy", "compiling", "starting", "error"]);

export function ServingChip() {
  if (!canMutate) return null; // static snapshot: no live ports to name
  const { location, navigate } = useViewerLocation();
  const q = createQuery<PreviewsResp>(() => ({
    queryKey: ["previews"], // shared with MachinePage; refreshed by the pulse's procs event
    queryFn: () => fetch("/previews").then((r) => r.json() as Promise<PreviewsResp>),
  }));
  // the branch whose diff is on screen right now — same derivation as the chat drawer's
  const viewing = () => {
    const l = location();
    return l.kind === "forest" ? (l.node ?? "") : l.kind === "standalone" ? l.branch : "";
  };
  // main on :3000 is ambient normal — the chip exists for side previews
  const side = () => (q.data?.previews ?? []).filter((p) => ALIVE.has(p.health) && p.branch !== "main");
  // trust the port's own claim over the registry when it carries one
  const servedBranch = (p: Preview) => (p.serves ? p.serves.split(" ")[0]!.split("@")[0]! : (p.branch ?? ""));
  const label = (p: Preview) => (p.serves ? p.serves.split(" ")[0]! : (p.branch ?? p.name));
  // surface the row that matches the diff on screen when one does; else the first alive.
  // On a failing server the stale rows say nothing true — yield the corner to "reconnecting…".
  const pick = () =>
    q.isError ? undefined : (side().find((p) => viewing() !== "" && servedBranch(p) === viewing()) ?? side()[0]);
  const lying = (p: Preview) => !!p.servesMismatch;
  const clash = (p: Preview) => viewing() !== "" && servedBranch(p) !== viewing();
  const hint = (p: Preview) =>
    lying(p)
      ? `:${p.port}'s own X-Dev-Worktree claim disagrees with the preview registry — the port is not what its card says. Click for the Machine page.`
      : clash(p)
        ? `:${p.port} serves ${label(p)} — the diff on screen is ${viewing()}. Don't test one against the other. Click for the Machine page.`
        : `:${p.port} serves ${label(p)}. Click for the Machine page.`;
  return (
    <Show when={pick()}>
      {(p) => (
        <button
          class="fixed bottom-3 left-[34px] z-[70] cursor-pointer border-0 bg-transparent p-0 font-mono text-[11px] tracking-[0.02em]"
          classList={{
            "text-del": lying(p()),
            "text-ember": !lying(p()) && clash(p()),
            "text-ink-faint opacity-70 hover:opacity-100": !lying(p()) && !clash(p()),
          }}
          title={hint(p())}
          onClick={() => navigate({ kind: "machine" })}
        >
          {lying(p()) || clash(p()) ? "⚠ " : ""}serving :{p().port} · {label(p())}
          {side().length > 1 ? ` +${side().length - 1}` : ""}
        </button>
      )}
    </Show>
  );
}
