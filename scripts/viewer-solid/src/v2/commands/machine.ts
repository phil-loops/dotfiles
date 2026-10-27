// The machine page's levers (srv/preview.py): open a server, read its log, restart it, swap its
// port to another build, kill it; run main, bring the stack up, reap the orphans, kill them all.
// Every kill — one, all, the orphans — takes a second press, like a push.
import { machine, type Server } from "../workstation";
import { command, type Write } from "../registry";
import { dispatch } from "../runner";
import { armed, setArmed } from "../ui";

const owned = (id: string | undefined) => {
  const s = machine.server(id);
  return !!s && s.managed !== false;
};
const label = (s: Server) => s.branch || s.name;

command({
  id: "machine.open",
  label: "open",
  title: "Open the server in the browser",
  scope: "server",
  budget: "local",
  keys: ["ret"],
  available: (id) => !!machine.server(id)?.url,
  local: (id) => void window.open(machine.server(id)!.url, "_blank", "noopener"),
});

command({
  id: "machine.log",
  label: "log",
  title: "Show the server's log",
  scope: "server",
  budget: "local",
  keys: ["l", "right"],
  v1: ["click:log"],
  available: (id) => owned(id) && machine.logFor() !== id,
  local: (id) => machine.showLog(id),
});
command({
  id: "machine.log.close",
  label: "log",
  title: "Hide the log",
  scope: "server",
  budget: "local",
  keys: ["h", "left"],
  v1: ["click:hide log"],
  available: () => !!machine.logFor(),
  local: () => machine.showLog(undefined),
});
command({
  id: "machine.log.jobs",
  label: "jobs",
  title: "Switch the log between web and the jobs worker",
  scope: "server",
  budget: "local",
  keys: ["tab"],
  v1: ["click:jobs worker", "click:web"],
  available: (id) => machine.logFor() === id && !!machine.server(id)?.jobs,
  local: (id) => machine.showLog(id, machine.logSrc() === "jobs" ? "web" : "jobs"),
});

command({
  id: "machine.restart",
  label: "restart",
  title: "Restart the server on its port",
  scope: "server",
  budget: "slow-io",
  keys: ["t"],
  v1: ["click:restart"],
  available: owned,
  write: (id): Write | null => {
    const s = machine.server(id);
    if (!s) return null;
    return {
      ops: [],
      path: "/preview-restart",
      body: { dir: s.dir, port: s.port },
      settled: () => true,
      said: `restarted ${label(s)} on :${s.port}`,
      failed: `${label(s)} didn't restart`,
    };
  },
});

command({
  id: "machine.swap",
  label: "swap",
  title: "Swap the port to the branch's parent build, or back",
  scope: "server",
  budget: "slow-io",
  keys: ["space w"],
  available: (id) => owned(id) && !!(machine.swapped()[id!] || machine.server(id)!.swapTo),
  write: (id): Write | null => {
    const s = machine.server(id);
    if (!s) return null;
    const before = machine.swapped();
    const back = before[s.port];
    const next = { ...before };
    if (back) delete next[s.port];
    else next[s.port] = { dir: s.dir, label: label(s) };
    machine.setSwapped(next);
    return {
      ops: [],
      path: "/preview-swap",
      body: back ? { port: s.port, dir: back.dir } : { port: s.port, branch: s.swapTo },
      settled: () => true,
      said: `:${s.port} now serves ${back ? back.label : s.swapTo}`,
      failed: `:${s.port} didn't swap`,
      rollback: () => machine.setSwapped(before),
    };
  },
});

// ── kill: arm, then send ──

const killArm = (id: string) => `kill ${id}`;
command({
  id: "machine.kill",
  label: "kill",
  title: "Kill the server",
  scope: "server",
  budget: "local",
  keys: ["X"],
  available: (id) => !!machine.server(id),
  route: (id) => (!machine.server(id) ? null : armed() === killArm(id!) ? "machine.stop" : "machine.kill.arm"),
});
command({
  id: "machine.kill.arm",
  title: "Ready a kill (the next press sends it)",
  scope: "server",
  budget: "local",
  quiet: true,
  available: (id) => !!machine.server(id),
  local: (id) => setArmed(killArm(id!)),
});
command({
  id: "machine.stop",
  title: "Kill a server",
  scope: "server",
  budget: "git-write",
  quiet: true,
  v1: ["machine.kill"],
  write: (id): Write | null => {
    setArmed(undefined);
    const s = machine.server(id);
    if (!s) return null;
    return {
      ops: [],
      path: "/preview-kill",
      body: { dir: s.dir, port: s.port },
      settled: () => !machine.server(id),
      said: `killed ${label(s)}`,
      failed: `${label(s)} is still running`,
    };
  },
});

command({
  id: "machine.killall",
  label: "kill all",
  title: "Kill every server",
  scope: "machine",
  budget: "local",
  keys: ["space x"],
  available: () => machine.servers().length > 0,
  route: () => (!machine.servers().length ? null : armed() === "kill all" ? "machine.stop.all" : "machine.killall.arm"),
});
command({
  id: "machine.killall.arm",
  title: "Ready killing every server (the next press sends it)",
  scope: "machine",
  budget: "local",
  quiet: true,
  local: () => setArmed("kill all"),
});
command({
  id: "machine.stop.all",
  title: "Kill every server",
  scope: "machine",
  budget: "local",
  quiet: true,
  v1: ["click:kill all"],
  local: (_t, e) => {
    setArmed(undefined);
    const via = e instanceof MouseEvent ? "click" : "key";
    for (const s of machine.servers()) dispatch("machine.stop", via, { target: s.port || s.dir });
  },
});

command({
  id: "machine.reap",
  label: "reap",
  title: "Reap orphaned servers (their worktree is gone)",
  scope: "machine",
  budget: "local",
  keys: ["space c"],
  available: () => machine.servers().length > 0,
  route: () => (!machine.servers().length ? null : armed() === "reap" ? "machine.reap.confirm" : "machine.reap.arm"),
});
command({
  id: "machine.reap.arm",
  title: "Ready a reap (the next press sends it)",
  scope: "machine",
  budget: "local",
  quiet: true,
  local: () => setArmed("reap"),
});
command({
  id: "machine.reap.confirm",
  title: "Reap orphaned servers",
  scope: "machine",
  budget: "git-write",
  quiet: true,
  v1: ["click:reap orphaned"],
  write: (): Write => {
    setArmed(undefined);
    return { ops: [], path: "/preview-reap", body: {}, settled: () => true, said: "reaped", failed: "reap failed" };
  },
});

command({
  id: "machine.main",
  label: "main",
  title: "Run main (on the port beside it, else a free one)",
  scope: "machine",
  budget: "slow-io",
  keys: ["space b"],
  v1: ["click:▷ run main"],
  available: () => !machine.main(),
  write: (): Write => ({
    ops: [],
    path: "/preview-main",
    body: { port: machine.mainPort().trim() },
    settled: () => !!machine.main(),
    failed: "main didn't start",
  }),
});

command({
  id: "machine.stack",
  label: "stack",
  title: "Start the shared Docker stack",
  scope: "machine",
  budget: "git-write",
  keys: ["space u"],
  v1: ["click:▷ start stack"],
  available: () => {
    const s = machine.substrate();
    return !!s && !s.starting && (s.total === 0 || s.up < s.total);
  },
  write: (): Write => ({
    ops: [],
    path: "/stack-up",
    body: { dir: machine.substrate()?.dir },
    settled: () => true,
    said: "starting the stack",
    failed: "the stack didn't start",
  }),
});
