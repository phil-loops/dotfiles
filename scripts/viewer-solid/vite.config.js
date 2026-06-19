import { spawn } from "node:child_process";
import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// The existing Python viewer (`stack-review-server.py`) already exposes everything as a
// JSON/SSE API on :62333. Vite proxies those exact routes so the Solid app is a pure
// frontend swap — zero backend changes, the working vanilla viewer keeps running.
const API = "http://127.0.0.1:62333";
const ROUTES = [
  "/model", "/node", "/projects", "/prs", "/myprs", "/commits", "/file", "/sig",
  "/head", "/sync", "/syncs", "/events", "/restack-status", "/branches", "/standalone",
  "/bless", "/restack", "/restack-all", "/check-origin", "/prepare", "/checkout", "/open",
  "/claude", "/chat", "/integrate", "/purpose", "/squash", "/prep", "/restack-resolve", "/heartbeat",
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
  plugins: [solid(), keepBackendAlive()],
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
