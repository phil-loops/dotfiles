// Did POST /contract leave the branch gone? Shared by the map's ghost pill and NodeActions'
// contract button, which have now twice had to be corrected in lockstep about it.
//
// 404 is contraction's own outcome — the branch AND its stack config are already gone — so it
// reads as done, not as "⊘ drop failed". But the server answers an UNROUTED path with 404 and a
// bare `{}` too, and calling that success drops a live node off the map (or reports "already
// dropped" for a branch that never moved). The handler always sends {"ok": false, "err": …} with
// its 404, so require that shape: a 404 counts only when the contract handler itself refused.
export function contractionDone(res: { status: number; ok?: boolean }): boolean {
  return res.status === 404 ? res.ok === false : res.ok !== false;
}
