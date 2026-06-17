import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

// The existing Python viewer (`stack-review-server.py`) already exposes everything as a
// JSON/SSE API on :62333. Vite proxies those exact routes so the Solid app is a pure
// frontend swap — zero backend changes, the working vanilla viewer keeps running.
const API = "http://127.0.0.1:62333";
const ROUTES = [
  "/model", "/node", "/projects", "/prs", "/myprs", "/commits", "/file", "/sig",
  "/head", "/sync", "/syncs", "/events", "/restack-status", "/branches", "/standalone",
  "/bless", "/restack", "/restack-all", "/check-origin", "/prepare", "/open",
  "/purpose", "/squash", "/prep", "/restack-resolve", "/heartbeat",
];

export default defineConfig({
  plugins: [solid()],
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
