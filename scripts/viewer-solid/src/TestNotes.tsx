import { createResource, createSignal, Show } from "solid-js";
import { fetchJSON } from "./api";
import { withRepo, canMutate } from "./provider";
import { renderMarkdown } from "./markdown";

type Note = { branch: string; markdown: string; mtime: number };

// Per-branch test/repro notes (the stack-notes sidecar): how to recreate the state
// that verified this branch. Renders only when a note exists — authored at prep time
// via `stack-notes`, editable here so stale steps can be fixed mid-review.
export function TestNotes(props: { branch: () => string }) {
  const [note, { refetch }] = createResource(
    () => props.branch(),
    (b) => fetchJSON<Note>(withRepo("/notes") + "?branch=" + encodeURIComponent(b)),
  );
  const [open, setOpen] = createSignal(true);
  const [editing, setEditing] = createSignal(false);
  const [draft, setDraft] = createSignal("");

  const save = async () => {
    await fetch(withRepo("/notes"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: props.branch(), markdown: draft() }),
    });
    setEditing(false);
    void refetch();
  };

  return (
    <Show when={(note()?.markdown ?? "") !== ""}>
      <section class="test-notes mt-[-4px] mb-[20px] rounded-[9px] border border-solid border-rule bg-vellum-raise px-[16px] py-[12px]">
        <header class="flex items-baseline gap-3">
          <button
            class="cursor-pointer text-[11px] uppercase tracking-[0.08em] text-gold-leaf hover:text-gold-deep"
            title={open() ? "collapse test notes" : "expand test notes"}
            onClick={() => setOpen(!open())}
          >
            {open() ? "▾" : "▸"} test notes
          </button>
          <span class="text-[11px] text-ink-faint">how to recreate the verified state</span>
          <Show when={canMutate && open() && !editing()}>
            <button
              class="ml-auto cursor-pointer text-[11px] text-ink-dim hover:text-gold-leaf"
              onClick={() => {
                setDraft(note()?.markdown ?? "");
                setEditing(true);
              }}
            >
              edit
            </button>
          </Show>
        </header>
        <Show when={open()}>
          <Show
            when={!editing()}
            fallback={
              <div class="mt-2">
                <textarea
                  class="h-[260px] w-full resize-y rounded-[6px] border border-solid border-rule bg-vellum-edge p-3 font-mono text-[12px] leading-relaxed text-ink outline-none focus:border-gold-deep"
                  value={draft()}
                  onInput={(e) => setDraft(e.currentTarget.value)}
                />
                <div class="mt-2 flex justify-end gap-3 text-[12px]">
                  <button class="cursor-pointer text-ink-dim hover:text-ink" onClick={() => setEditing(false)}>
                    cancel
                  </button>
                  <button class="cursor-pointer text-gold-leaf hover:text-gold-deep" onClick={() => void save()}>
                    save
                  </button>
                </div>
              </div>
            }
          >
            <div
              class="wiki-prose mt-2 max-h-[420px] overflow-y-auto text-[13px]"
              innerHTML={renderMarkdown(note()?.markdown ?? "")}
            />
          </Show>
        </Show>
      </section>
    </Show>
  );
}
