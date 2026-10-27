import { execSync, spawn } from "node:child_process";
import { defineConfig } from "vite";
import solid from "vite-plugin-solid";
import tailwindcss from "@tailwindcss/vite";

// The Python viewer (`stack-review-server.py`) exposes everything as a JSON/SSE API; Vite
// proxies those exact routes so the Solid app is a pure frontend. The backend port is now
// PER-REPO (so forests in several repos coexist), so resolve it from the same shared helper
// stack-review-serve uses — never hardcode it, or the proxy drifts off the live backend.
// $STACK_REVIEW_PORT overrides (point the dev server at another repo's backend); with no
// arg the helper derives from cwd = this repo (dotfiles), which is where you dev the viewer.
const PORT = execSync(`${process.env.HOME}/.dotfiles/scripts/stack-review-port`).toString().trim();
const API = `http://127.0.0.1:${PORT}`;
// Every route the SPA fetches must be listed — a missing one falls through to the SPA
// fallback, which answers 200 + index.html, so dev-mode saves "succeed" without reaching
// the backend (that's how /ticket silently no-opped under `npm run dev`).
const ROUTES = [
  "/commit-diff", "/commits", "/delta-tests", "/dirty-resolve", "/diverged-detail", "/events",
  "/file", "/fix-upstream", "/focus", "/footprint", "/force-origin", "/force-scope", "/gates", "/gates-progress", "/integrate",
  "/landed-why", "/learning-evidence", "/learning-question", "/learning-state", "/lsp/definition",
  "/lsp/hover", "/lsp/prepare", "/lsp/src", "/node", "/open", "/outbox-hold", "/outline",
  "/outline-undo", "/packet-compare", "/prep-push", "/prep-route", "/preview-kill", "/preview-log",
  "/preview-main", "/preview-reap", "/preview-restart", "/preview-swap", "/preview-wait",
  "/previews", "/project-state", "/push-origin", "/reconcile", "/reseat-children", "/restack",
  "/revert-commit", "/review-address", "/review-apply", "/review-draft", "/review-note",
  "/stack-up", "/state", "/sync", "/telemetry/summary", "/todo-item", "/track", "/tutor",
  "/tutor-import", "/tutor-src", "/tutor-stop", "/tutor-terminal", "/v2/events", "/viewed",
  "/wiki-pages", "/wiki-src", "/heartbeat",
];

// Dev-only keep-alive: the Python backend self-reaps after 15min without an /events
// SSE or /heartbeat (stack-review-server.py IDLE=900). `predev` starts it, but a closed
// tab (overnight) lets it reap mid-session with nothing to revive it — the proxy then
// 500s forever. Bind the backend's life to the `npm run dev` process instead: POST
// /heartbeat every 60s (resets the idle timer, so it never reaps), and if it's already
// down, respawn it headless. Zero prod impact — only runs under `vite serve`.
function keepBackendAlive() {
  const respawn = () =>
    spawn(`${process.env.HOME}/.dotfiles/scripts/stack-review-serve`, ["--ensure"], {
      stdio: "ignore",
      detached: true,
    })
      .on("error", () => {})
      .unref();

  return {
    name: "keep-backend-alive",
    apply: "serve",
    configureServer() {
      const beat = async () => {
        try {
          const r = await fetch(`${API}/heartbeat`, { method: "POST" });
          if (!r.ok) respawn();
        } catch {
          respawn(); // connection refused → backend down → bring it back
        }
      };
      void beat();
      setInterval(beat, 60_000).unref();
    },
  };
}

export default defineConfig({
  plugins: [solid(), tailwindcss(), keepBackendAlive()],
  build: {
    rollupOptions: {
      // the app is served at /v2 (dist/v2/index.html); its hashed assets in dist/assets
      input: { v2: "v2/index.html" },
      output: {
        // vendor in its own hashed chunk: app edits stop re-downloading the ~400kB of
        // solid/tanstack/deps (the single 511kB index chunk churned its hash every build).
        manualChunks: (id) =>
          id.includes("node_modules/solid-js") ? "solid" : id.includes("node_modules") ? "vendor" : undefined,
      },
    },
  },
  server: {
    port: 5174,
    strictPort: true,
    // Anchor each route as a regex (`^…` keys are RegExp in Vite) that matches ONLY the
    // exact endpoint or `endpoint?query` — NOT a prefix. Critical: a bare `/node` prefix
    // would otherwise swallow Vite's own `/node_modules/...` requests → 404 → blank page.
    proxy: Object.fromEntries(
      ROUTES.map((p) => [`^${p}(?:\\?|$)`, { target: API, changeOrigin: true }])
    ),
  },
});
