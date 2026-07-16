import { Show, For, type JSX } from "solid-js";
import { Link } from "./router";
import type { NodeData, SpineNode, FileDiff } from "./types";

const ITEM =
  "file-item flex cursor-pointer items-center gap-[9px] border-l-2 py-[6px] pr-[16px] pl-[12px] transition-[background,border-color] duration-[120ms]";
const itemState = (active: boolean) =>
  active ? "border-l-gold-leaf bg-vellum-edge" : "border-l-transparent hover:bg-vellum-edge";
const NAME =
  "file-item-name min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[12px] [&_.file-dir]:text-ink-faint";

// the branch's file list (GitHub-PR-style sidebar): filter box + review rows + a dirt divider.
// A wide prop surface because it mirrors the review surface's state — clicking a row drives the
// diff cards on the right (activeFile/scrollToFile), and ⌘F focuses this filter.
export function FilePanel(props: {
  spine: () => SpineNode[];
  project: () => string;
  nodeData: () => NodeData | undefined;
  isGhost: () => boolean;
  blessedOf: (f: FileDiff) => boolean;
  activeFile: () => string;
  fileFilter: () => string;
  setFileFilter: (v: string) => void;
  matchFilter: (f: { path: string }) => boolean;
  scrollToFile: (path: string) => void;
  fileSeg: (p: string) => JSX.Element;
  onPanelClose: () => void;
  onFilterEl: (el: HTMLInputElement) => void;
  onRestorePanel: () => void;
}) {
  return (
      <aside class="spine">
        <button
          class="panel-collapse"
          title="collapse the file panel for more diff width (b)"
          onClick={() => props.onPanelClose()}
        >
          ‹
        </button>
        <Link class="brand inline-block px-[20px] pb-[2px] font-display text-[26px] font-semibold italic text-ink no-underline" to={{ kind: "home", tab: "forests" }}>
          <span class="brand-mark text-[18px] not-italic text-gold-leaf">✦</span> blessed
        </Link>
        {/* the branch tree migrated to the docked map (the navigator); the spine is now the
            file list for the active branch. */}
        <Show when={props.spine().length} fallback={<div class="spine-empty">{props.project()}</div>}>
          <Show when={props.nodeData()} fallback={<div class="spine-meta">loading…</div>}>
            {(data) => (
              <>
                <div class="spine-meta">
                  {props.isGhost()
                    ? `${data().files.length} files · ✦ all changes`
                    : `${data().files.filter(props.blessedOf).length}/${data().files.length} files blessed`}
                </div>
                <Show
                  when={data().files.length}
                  fallback={<div class="spine-empty">nothing to review</div>}
                >
                  <input
                    class="file-filter"
                    ref={props.onFilterEl}
                    placeholder="filter files… (⌘F)"
                    value={props.fileFilter()}
                    onInput={(e) => props.setFileFilter(e.currentTarget.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Escape") {
                        e.preventDefault();
                        e.stopPropagation(); // don't let the global Esc fire (would jump to the map)
                        if (props.fileFilter()) { props.setFileFilter(""); } else { e.currentTarget.blur(); props.onRestorePanel(); }
                      } else if ((e.metaKey || e.ctrlKey) && e.key === "f") {
                        props.onRestorePanel(); // a 2nd ⌘F bubbles to native find; fold an auto-opened panel back
                      }
                    }}
                  />
                  <ul class="file-list m-0 list-none p-0">
                    <For each={data().files.filter(props.matchFilter)}>
                      {(f) => (
                        <li
                          class={`${ITEM} ${itemState(props.activeFile() === f.path)}`}
                          classList={{ blessed: props.blessedOf(f), active: props.activeFile() === f.path }}
                          onClick={() => props.scrollToFile(f.path)}
                          title={f.path}
                        >
                          <span class={`dot ${props.blessedOf(f) ? "blessed" : "unblessed"}`} />
                          <span
                            class={`${NAME} ${props.activeFile() === f.path ? "text-ink" : "text-ink-dim"} ${
                              props.blessedOf(f) ? "[&_b]:font-medium [&_b]:text-gold-leaf" : "[&_b]:font-semibold"
                            }`}
                          >
                            {props.fileSeg(f.path)}
                          </span>
                          <span class="file-item-lines flex flex-none gap-[6px] text-[10px]">
                            <span class="add text-add">+{f.add ?? 0}</span>
                            <span class="del text-del">−{f.del ?? 0}</span>
                          </span>
                        </li>
                      )}
                    </For>
                  </ul>
                  <Show when={(data().dirty?.length ?? 0) > 0}>
                    {/* dirt files are DRIVABLE rows, same as the review set — click jumps to the
                        card, tab already cycles through them (.entry[data-path]). The story lives
                        in the divider's tooltip; the rows do the work. */}
                    <div
                      class="file-list-dirt-head mx-[2px] mt-[12px] mb-[4px] cursor-help border-t border-x-0 border-b-0 border-dashed border-rule pt-[9px] text-[10px] font-semibold uppercase tracking-[0.08em] text-ink-dim"
                      title={`uncommitted changes riding ${data().worktree || "the checkout"} — not part of this review, never blessed; ⟲ sync stops to ask about them`}
                    >
                      ± uncommitted · {(data().worktree ?? "").replace(/.*\//, "") || "checkout"}
                    </div>
                    <ul class="file-list m-0 list-none p-0">
                      <For each={data().dirty!.filter((f) => props.matchFilter(f))}>
                        {(f) => (
                          <li
                            class={`dirt ${ITEM} ${itemState(props.activeFile() === f.path)}`}
                            classList={{ active: props.activeFile() === f.path }}
                            onClick={() => props.scrollToFile(f.path)}
                            title={f.path}
                          >
                            <span class="dot dirt" />
                            <span
                              class={`${NAME} [&_b]:font-semibold ${props.activeFile() === f.path ? "text-ink" : "text-ink-dim"}`}
                            >
                              {props.fileSeg(f.path)}
                            </span>
                          </li>
                        )}
                      </For>
                    </ul>
                  </Show>
                </Show>
              </>
            )}
          </Show>
        </Show>
      </aside>
  );
}
