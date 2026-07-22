// Did POST /contract leave the branch gone? Shared by the map's ghost pill and NodeActions'
// contract button, which have now twice had to be corrected in lockstep about it.
//
// 404 is contraction's own outcome — the branch AND its stack config are already gone — so it
// reads as done, not as "⊘ drop failed". But the server answers an UNROUTED path with 404 and a
// bare `{}` too, and calling that success drops a live node off the map (or reports "already
// dropped" for a branch that never moved). The handler always sends {"ok": false, "err": …} with
// its 404, so require that shape: a 404 counts only when the contract handler itself refused.
//
// The premise, before you reuse this: 404+ok:false is read as "already gone", but /contract's 404
// ("no branch or stack config named X") equally covers "never existed". That is safe HERE only
// because the branch comes from a node on screen, so a name that resolves to nothing must have
// been dropped. Other endpoints now answer 404+ok:false for an unknown NAME (/preview-integration),
// which does not mean gone — point this at one of those and it repeats the "any 404 = success" bug
// it was written to kill. Widening its reach means the body must say gone-vs-never-existed.
export function contractionDone(res: { status: number; ok?: boolean }): boolean {
  return res.status === 404 ? res.ok === false : res.ok !== false;
}
