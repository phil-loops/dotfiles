import { createSignal, createEffect } from "solid-js";
import { openChat } from "./chatDrawer";
import type { ViewerLocation } from "./router";
import type { NodeData } from "./types";

// Cross-forest chat opening: the read-only index overlay + resolving a chat target into the
// drawer. Opening on another branch navigates there first, then opens once its files load.
export function useNodeChat(deps: {
  active: () => string;
  location: () => ViewerLocation;
  nodeData: () => NodeData | undefined;
  navigate: (loc: ViewerLocation) => void;
}) {
  const [showChats, setShowChats] = createSignal(false);
  // a chat the index asked to open on a (possibly other) branch: navigate there, then open the
  // drawer once that node's files have loaded (see the effect below). Cleared once opened.
  const [pendingChat, setPendingChat] = createSignal<{ branch: string; path: string } | null>(null);

  // resolve a chat target into the drawer: prefer the real FileDiff (carries the patch); else
  // synthesize a minimal one so the server computes the diff for that path. "" path → whole branch.
  const openChatFor = (path: string) => {
    const at = { branch: deps.active(), origin: deps.location() };
    if (!path) {
      openChat({ ...at, file: null });
      return;
    }
    const real = deps.nodeData()?.files.find((f) => f.path === path);
    openChat({ ...at, file: real ?? { path, status: "modified" } });
  };
  // from the index: open a chat in its own branch+file context. Same branch → open now; another
  // branch → navigate (as a standalone node) and let the effect open it once its files arrive.
  const openChatInContext = (branch: string, path: string) => {
    setShowChats(false);
    if (branch === deps.active()) {
      openChatFor(path);
    } else {
      setPendingChat({ branch, path });
      deps.navigate({ kind: "standalone", branch });
    }
  };
  createEffect(() => {
    const p = pendingChat();
    if (p && deps.active() === p.branch && deps.nodeData()?.files) {
      openChatFor(p.path);
      setPendingChat(null);
    }
  });
  return { showChats, setShowChats, openChatFor, openChatInContext };
}
