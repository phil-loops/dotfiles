// A branch's full history, as it'll be pushed: every commit's sha, subject, author and date,
// pushed or local, and its whole body. A body carrying the generated forest plan says so — GitHub
// shows it on the PR's commits tab and pre-fills a one-commit PR with it — and an unpushed one
// can drop it in place (words.strip, undoable).
import { createResource, For, Show } from "solid-js";
import { hasPlan } from "../outlineHints";
import { atRepo } from "./model";
import { bind } from "./runner";
import { view } from "./store";
import { getJSON } from "./sync";
import { shown, stripping, type Outline } from "./words";

export default function Commits(props: { branchId: string }) {
  const b = () => view("branch", props.branchId);
  const [o] = createResource(
    () => (b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}` : null),
    async () => {
      const got = await getJSON<Outline>(atRepo(b()!.repo, `/outline?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null);
      if (got) shown.set(props.branchId, got);
      return got;
    },
  );
  return (
    <Show when={o()} fallback={<p class="m-0 text-ink-faint">{o.loading ? "reading the commits…" : "couldn't read the commits"}</p>}>
      <Show when={o()!.commits.length} fallback={<p class="m-0 text-ink-faint">no commits of its own</p>}>
        <ol class="m-0 list-none p-0">
          <For each={o()!.commits}>
            {(c) => {
              const body = () => stripping().get(c.sha) ?? c.body;
              return (
                <li class="mb-3">
                  <div class="flex items-baseline gap-2">
                    <code class={c.pushed ? "text-ink-faint" : "text-gold-leaf"}>{c.short.slice(0, 7)}</code>
                    <span class="text-ink">{c.subject}</span>
                  </div>
                  <div class="ml-[3.6em] text-[11px] text-ink-faint">
                    {c.author} · {c.date} · {c.pushed ? "pushed" : "local"}
                  </div>
                  <Show when={body()}>
                    <pre class="m-0 ml-[3.6em] mt-1 whitespace-pre-wrap font-mono text-[12px] text-ink-dim">{body()}</pre>
                  </Show>
                  <Show when={hasPlan(body())}>
                    <p class="m-0 ml-[3.6em] mt-1 border-l-2 border-gold-leaf pl-2 text-[12px] text-ink-dim">
                      This body carries the forest plan — GitHub shows it on the commits tab and pre-fills a one-commit PR with it; the squash keeps it off main.{" "}
                      <Show when={!c.locked} fallback={<span class="text-ink-faint">({c.locked})</span>}>
                        <button class="rv-quietbtn" onClick={bind("words.strip", `${props.branchId} ${c.sha}`)}>
                          strip it
                        </button>
                      </Show>
                    </p>
                  </Show>
                </li>
              );
            }}
          </For>
        </ol>
      </Show>
    </Show>
  );
}
