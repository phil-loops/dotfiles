// The shared-history door: the ONE control in this app that reaches origin, and everything that
// explains what it would send. Split out of NodeActions because it is a verb of its own — Phil:
// "whatever is being shared publicly needs to be with me at the helm" — and because the header
// had grown into 1300 lines where the local motions and this sat interleaved.
//
// A hook plus a component, not one component: the parent's `busy()` reads pushOrigin.isPending
// and renders the pushed-link itself, so the state has to live where both can see it.
import { createSignal, For, Show } from "solid-js";
import { createMutation, createQuery } from "@tanstack/solid-query";
import { withRepo } from "./provider";
import { post } from "./actions";

const PUSH_RED = "cursor-pointer rounded-[5px] border border-del px-[9px] py-[3px] text-[12px] font-semibold leading-[1.55] opacity-90 enabled:hover:opacity-100 disabled:cursor-default disabled:opacity-35";
const FIX_SHAPE = "cursor-pointer rounded-[5px] border bg-transparent px-[9px] py-[3px] text-[12px] leading-[1.55] opacity-90 enabled:hover:opacity-100 disabled:cursor-default disabled:opacity-50";
const FIX = `${FIX_SHAPE} border-del text-del`;
const EDITOR_CLOSE = "cursor-pointer text-[11px] leading-[1.55] text-ink-faint";

export function usePushDoor(d: {
  branch: () => string;
  isReview: () => boolean;
  setDone: (s: string | null) => void;
  refresh: () => void;
}) {
  // push: the Phase-1 wards, mirrored from the /push card — server recomputes them all
  // at push time; this button only arms when the read-only verdict is green.
  const preview = createQuery(() => ({
    queryKey: ["push-preview", d.branch()],
    queryFn: () =>
      fetch(withRepo("/push-preview") + "?branch=" + encodeURIComponent(d.branch())).then(
        (r) =>
          r.json() as Promise<{
            ok?: boolean;
            outgoing?: number;
            reasons?: string[];
            web?: string;
            originExists?: boolean;
            published?: boolean;
            followup?: boolean;
            commits?: { sha: string; subject: string; date: string; files: number; add: number; del: number; merge: boolean; voiced: boolean }[];
            moreCommits?: number;
            files?: { path: string; add: number; del: number }[];
            moreFiles?: number;
            commit?: { sha: string; subject: string; body: string } | null;
            review?: { flags: string[] } | null;
          }>,
      ),
    enabled: !!d.branch() && !d.isReview(),
  }));
  // the manifest — GitHub Desktop's "what goes out on push" answered in the header: the
  // outgoing commits with their churn, the files origin receives, where it lands.
  const outN = () => preview.data?.outgoing ?? 0;
  const outLabel = () => (outN() === 1 ? "to origin" : `${outN()} commits`);
  const outChurn = () => {
    const cs = preview.data?.commits ?? [];
    return { add: cs.reduce((a, c) => a + c.add, 0), del: cs.reduce((a, c) => a + c.del, 0) };
  };
  const landing = () =>
    preview.data?.followup ? "onto the open PR — pushed as they are" : preview.data?.originExists ? "fast-forward of origin's copy" : "new branch on origin";
  const pushSummary = () => {
    const p = preview.data;
    if (!p) return "";
    const nFiles = (p.files?.length ?? 0) + (p.moreFiles ?? 0);
    return [
      `→ origin/${d.branch()} · ${landing()}`,
      ...(p.commits ?? []).map((c) => `${c.sha.slice(0, 10)}  ${c.subject}  +${c.add} −${c.del}`),
      ...(p.moreCommits ? [`+${p.moreCommits} more`] : []),
      `${nFiles} file${nFiles === 1 ? "" : "s"}  +${outChurn().add} −${outChurn().del}`,
    ].join("\n");
  };
  const [pushedWeb, setPushedWeb] = createSignal<string | null>(null);
  const pushOrigin = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; err?: string; web?: string; opened?: boolean }>("/push-origin", { branch: d.branch() }),
    onSuccess: (r) => {
      d.refresh();
      if (!r.ok) {
        d.setDone(`✗ ${r.err || "push refused"}`);
        return;
      }
      // The server opens the target in the local browser on success (the open PR if one
      // exists, else the compare-and-create form); the link below is the fallback
      // (mobile, or a headless host with no `open`).
      const isPr = (r.web ?? "").includes("/pull/");
      d.setDone(
        r.opened
          ? isPr
            ? "✓ pushed — opening the open PR"
            : "✓ pushed — opening the compare view to author the PR"
          : "✓ pushed — origin has it",
      );
      setPushedWeb(r.web ?? null);
    },
    onError: (e) => d.setDone(`✗ ${(e as Error).message || "push failed"}`),
  }));

  // outgoing==0 but the branch is up-to-date on origin: no push to make, so open the PR page
  // directly — the open PR if one exists (view), else the compare-and-create form (author).
  // The push-less exit from the dead-push-button trap; opens a browser tab, never gh pr create.
  const openPr = createMutation(() => ({
    mutationFn: () =>
      post<{ ok?: boolean; web?: string; opened?: boolean; hadPr?: boolean }>("/open-pr", { branch: d.branch() }),
    onSuccess: (r) => {
      if (!r.ok) {
        d.setDone("✗ no origin remote to open");
        return;
      }
      d.setDone(r.opened ? (r.hadPr ? "✓ opening the open PR" : "✓ opening the compare view to author the PR") : "✓ PR page ready");
      setPushedWeb(r.web ?? null);
    },
    onError: (e) => d.setDone(`✗ ${(e as Error).message || "couldn’t open"}`),
  }));
  return { preview, pushOrigin, openPr, pushedWeb, outN, outLabel, landing, pushSummary };
}

export type PushDoorState = ReturnType<typeof usePushDoor>;

export function PushDoor(props: {
  door: PushDoorState;
  branch: () => string;
  isReview: () => boolean;
  busy: () => boolean;
  armed: () => string | null;
  trigger: (id: string, run: () => void, holdMs?: number) => void;
  disarm: () => void;
  fire: (fn: () => void) => () => void;
  editorOpen: () => boolean;
  openEditor: (subject: string, body: string) => void;
}) {
  const { preview, pushOrigin, openPr, outN, outLabel, landing, pushSummary } = props.door;
  const isReview = props.isReview;
  const busy = props.busy;
  const armed = props.armed;
  const trigger = props.trigger;
  const disarm = props.disarm;
  const fire = props.fire;
  const editorOpen = props.editorOpen;
  return (
    <>
      {/* THE red button — the only way anything here reaches origin (Phil: "whatever is
          being shared publicly needs to be with me at the helm"). Deliberately not the
          spine's slot: local motions and the shared-history door never share a control.
          Appears only when a commit is actually outgoing; arms only when the wards are
          green; the server re-verifies everything at push time regardless. */}
      <Show when={!isReview() && (preview.data?.outgoing ?? 0) > 0}>
        <button
          class={`nh-fix nh-push-red ${PUSH_RED} ${armed() === "pushOrigin" ? "armed bg-del text-vellum-night" : "bg-transparent text-del enabled:hover:bg-del-bg"}`}
          disabled={busy() || !preview.data?.ok}
          title={
            preview.data?.ok
              ? `push to origin — the team sees this the moment it lands\n${pushSummary()}`
              : `not pushable yet:\n${(preview.data?.reasons ?? ["reading the branch…"]).join("\n")}`
          }
          onClick={fire(() => trigger("pushOrigin", () => pushOrigin.mutate(), 20000))}
        >
          {pushOrigin.isPending
            ? "pushing…"
            : armed() === "pushOrigin"
              ? `confirm: push ${outN() === 1 ? "" : `${outN()} commits `}to origin`
              : `⇧ push ${outLabel()}`}
        </button>
      </Show>

      {/* the crossing manifest — shown while the door is armed, so the second click is made
          knowing exactly what origin receives: each outgoing commit with its churn, the files,
          where it lands. Arming holds 20s here (not the 4s of the local motions) for reading. */}
      <Show when={!isReview() && armed() === "pushOrigin" && preview.data}>
        {(p) => (
          <div class="nh-manifest mt-1 flex basis-full flex-col gap-[7px] rounded-[9px] border border-solid border-del px-[14px] py-3">
            <div class="flex flex-wrap items-baseline gap-x-[10px]">
              <span class="font-display text-[15px] font-semibold italic text-del">
                pushing {outN()} commit{outN() === 1 ? "" : "s"} → origin/{props.branch()}
              </span>
              <span class="text-[11px] text-ink-faint">{landing()}</span>
            </div>
            <ol class="m-0 flex list-none flex-col gap-[3px] p-0">
              <For each={p().commits ?? []}>
                {(c) => (
                  <li class="flex items-baseline gap-[8px] text-[12px]">
                    <span class="font-mono text-[11px] text-ink-faint">{c.sha.slice(0, 10)}</span>
                    <span class={`flex-1 ${c.voiced ? "text-ink" : "text-del"}`}>{c.subject}</span>
                    <span class="whitespace-nowrap font-mono text-[11px] text-ink-faint">
                      {c.files} file{c.files === 1 ? "" : "s"} <span class="text-add">+{c.add}</span> <span class="text-del">−{c.del}</span>
                    </span>
                  </li>
                )}
              </For>
              <Show when={p().moreCommits}>{(m) => <li class="text-[11px] italic text-ink-faint">+{m()} more commits</li>}</Show>
            </ol>
            <div class="flex flex-wrap gap-x-[12px] gap-y-[2px] font-mono text-[11px] text-ink-dim">
              <For each={p().files ?? []}>
                {(f) => (
                  <span class="whitespace-nowrap">
                    {f.path} <span class="text-add">+{f.add}</span> <span class="text-del">−{f.del}</span>
                  </span>
                )}
              </For>
              <Show when={p().moreFiles}>{(m) => <span class="italic text-ink-faint">+{m()} more files</span>}</Show>
            </div>
            <div class="flex items-center gap-[10px] text-[11px] text-ink-faint">
              <span>✓ gates green for this exact tree</span>
              <Show when={p().review}>{(rv) => <span>{rv().flags.length ? `⚑ ${rv().flags.length} review flag${rv().flags.length === 1 ? "" : "s"} unapplied` : "✓ reviewed"}</span>}</Show>
              <button class={`nh-editor-close ${EDITOR_CLOSE}`} onClick={() => disarm()}>
                cancel
              </button>
            </div>
          </div>
        )}
      </Show>

      {/* push-ready's review verdict for THIS exact tree — tree-keyed like gates-green, so a
          moved tree silently retires it (the server sends null). Flags are the reviewer's
          unapplied findings, full text on hover; a fresh EMPTY list is reviewed-clean. */}
      <Show when={!isReview() && preview.data?.review}>
        {(rv) =>
          rv().flags.length ? (
            <span class="nh-review-flags cursor-help whitespace-nowrap text-[12px] text-patina" title={rv().flags.join("\n")}>
              ⚑ {rv().flags.length} review flag{rv().flags.length === 1 ? "" : "s"}
            </span>
          ) : (
            <span class="nh-reviewed cursor-help whitespace-nowrap text-[12px] text-ink-faint" title="push-ready reviewed this exact tree — no unapplied findings">
              ✓ reviewed
            </span>
          )
        }
      </Show>

      {/* open the ONE outgoing commit's message on demand — play with it (or ✦ voice it) and
          push, without running the whole sync motion first. Pre-filled from the push-preview
          verdict; the editor it opens is the same one prep ends at. Hidden while it's already
          open so a re-click can't clobber unsaved edits. */}
      <Show when={!isReview() && preview.data?.commit && !editorOpen()}>
        <button
          class={`nh-fix nh-open-pr ${FIX}`}
          disabled={busy()}
          title="edit this commit's message (subject + body) before pushing — no sync needed"
          onClick={() => {
            const c = preview.data!.commit!;
            props.openEditor(c.subject, c.body);
          }}
        >
          ✎ message
        </button>
      </Show>

      {/* the branch IS on origin: the PR page is one click away regardless of outgoing state.
          Open the PR (view/tweak) or the compare-and-create form (author) — no push, no gh pr
          create. With a commit still outgoing it shows what origin has NOW; push adds yours. */}
      <Show when={!isReview() && preview.data?.originExists}>
        <button
          class={`nh-fix nh-open-pr ${FIX}`}
          disabled={busy() || openPr.isPending}
          title={
            preview.data?.published
              ? "opens this branch's open PR in a browser — tweak it on github.com (no push)"
              : (preview.data?.outgoing ?? 0) > 0
                ? "opens the compare-and-create page for what origin already has — author or tweak the PR there; the outgoing commit joins it once you push (no push, no gh pr create)"
                : "pushed to origin but no PR yet — opens the compare-and-create page to author it (no push, no gh pr create)"
          }
          onClick={() => openPr.mutate()}
        >
          {openPr.isPending ? "opening…" : preview.data?.published ? "↗ view PR" : "↗ open PR"}
        </button>
      </Show>
    </>
  );
}
