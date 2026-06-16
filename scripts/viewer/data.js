const BAKED = __MODEL__;                       // static snapshot: model is null when served live
const LIVE = !BAKED;                           // live mode → fetch /model, bless over HTTP
const Q = new URLSearchParams(location.search);
let MODEL = BAKED || null;
let active = 0, filter = 'all';
const PURPOSE = {};   // branch → {thesis, enables} (lazy, live-only)
const NODEPATCH = {}; // branch[@base] → Promise<{files:[{path,status,patch,stale}]}> (raw /node)
const WTPREP = {};    // branch → true once we've asked the server to warm its worktree
function prepareWorktree(branch){   // fire-and-forget: build the branch's nvim worktree ahead of "open"
  if(!LIVE || WTPREP[branch]) return; WTPREP[branch]=true;
  fetch('/prepare',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch})}).catch(()=>{});
}
// fetch one node's diffs vs `base` (default = parent). cache key folds in the base
// so "vs parent" and "vs main" are cached separately. Returns the raw {files:[…]}.
function fetchNode(branch, base){
  const key = base ? branch + '@' + base : branch;
  if(NODEPATCH[key]) return NODEPATCH[key];
  if(!LIVE) return NODEPATCH[key] = Promise.resolve({files:[]});   // static snapshot: structure only
  prepareWorktree(branch);   // prefetch the worktree so "open in nvim" is instant for this node
  const q = '/node?branch=' + encodeURIComponent(branch) + (base ? '&base=' + encodeURIComponent(base) : '');
  // A /node fetch that never settles (e.g. the page loaded mid-restack while refs were
  // moving) must not latch the card on "loading diff…" forever. Bound each attempt with
  // an AbortController timeout and auto-retry the hang/network cases a few times; a
  // definitive HTTP error (404/500) skips the retries. On final failure clear the cache
  // entry so a redraw (or the retry link) starts fresh — never cache a FAILED fetch.
  const TIMEOUT_MS = 8000, RETRIES = 3;
  const attempt = (n) => {
    const ctl = new AbortController();
    const timer = setTimeout(()=>ctl.abort(), TIMEOUT_MS);
    return fetch(q, {signal: ctl.signal}).then(
      r=>{ clearTimeout(timer); if(!r.ok) throw new Error('node '+r.status); return r.json(); },
      err=>{ clearTimeout(timer); if(n < RETRIES) return attempt(n+1); throw err; });   // hang/network → retry
  };
  NODEPATCH[key] = attempt(0).catch(e=>{ delete NODEPATCH[key]; throw e; });
  return NODEPATCH[key];
}
// patch map {path:{patch,stale}} for the per-file diff renderer (shares fetchNode's cache)
function ensureNode(branch, base){
  return fetchNode(branch, base).then(d=>{ const m={}; (d.files||[]).forEach(f=>{ m[f.path]={patch:f.patch, stale:f.stale}; }); return m; });
}

const $ = (s,r=document)=>r.querySelector(s);
const el = (t,c,h)=>{const e=document.createElement(t); if(c)e.className=c; if(h!=null)e.innerHTML=h; return e;};
const segPath = p => p.replace(/(.*\/)([^/]+)$/, '<span class="seg">$1</span>$2');

function toast(html,sticky){const t=$('#toast'); t.innerHTML=html; t.classList.add('show'); clearTimeout(t._t);
  t.onclick=()=>{ t.classList.remove('show'); };   // click-to-dismiss (the only way out for a sticky toast)
  if(!sticky) t._t=setTimeout(()=>t.classList.remove('show'),1900);}

async function fetchModel(){
  const b = Q.get('branch') || (MODEL && (MODEL.project||MODEL.leaf)) || '';
  const r = await fetch('/model?branch=' + encodeURIComponent(b));
  if(!r.ok) throw new Error('model fetch failed');
  return r.json();
}
// the source node object in MODEL (mutable — NODES are throwaway copies from flatten())
function srcNode(branch){ return MODEL.nodes ? MODEL.nodes[branch] : (MODEL.links||[]).find(l=>l.branch===branch); }
// our own bless writes the ledger, which the server re-broadcasts as an SSE 'update'.
// we already applied that optimistically in place, so suppress the remount for it until
// this deadline (re-armed around the POST so a slow round-trip can't let the echo leak).
let blessEchoUntil = 0;
// repaint ONE file card in place to `status` — chip, tag, class, bless-button label —
// without touching #main's diffs or scroll. Missing card (filtered out) is a no-op.
function paintFileCard(path, status){
  const main=$('#main'); if(!main) return;
  const card=[...main.querySelectorAll('.file[data-path]')].find(c=>c.dataset.path===path); if(!card) return;
  card.classList.remove('clean','stale','unblessed'); card.classList.add(status);
  const chip=card.querySelector('.chip'); if(chip){ chip.className='chip '+status;
    chip.textContent = status==='clean'?'✓':status==='stale'?'△':'·'; }
  const tag=card.querySelector('.tag'); if(tag){ tag.className='tag'+(status==='clean'?' clean':status==='stale'?' stale':'');
    tag.textContent = status==='clean'?'blessed':status==='stale'?'changed since blessed':'unreviewed'; }
  const bb=card.querySelector('.bless'); if(bb) bb.textContent = status==='stale'?'re-bless':'bless';
}
// bless: live → flip the UI OPTIMISTICALLY (status + counts + cards, no remount), then POST
// in the background and roll back if it fails. static → tell the user it's read-only.
async function doBless(branch, file){
  if(!LIVE){ toast('read-only snapshot — open via <b>loops stack review --html</b> to bless'); return; }
  const n=srcNode(branch);
  const targets = (n&&n.files) ? (file==='.' ? n.files.filter(f=>f.status!=='clean')
                                             : n.files.filter(f=>f.path===file && f.status!=='clean')) : [];
  const undo = targets.map(f=>({f, status:f.status}));   // capture for rollback
  undo.forEach(({f,status})=>{ if(status==='stale') n.stale--; else if(status==='unblessed') n.unblessed--; n.clean++; f.status='clean'; });
  undo.forEach(({f})=>paintFileCard(f.path,'clean'));
  NODES=flatten(); renderRail();   // rail + tally only — leaves #main (diffs, scroll) untouched
  toast('✦ blessed');
  blessEchoUntil = Date.now()+3000;   // arm BEFORE the write so the echoed pulse is covered
  try{
    const r=await fetch('/bless',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch,file})});
    if(!r.ok) throw new Error('bless '+r.status);
    Object.keys(NODEPATCH).forEach(k=>{ if(k===branch || k.startsWith(branch+'@')) delete NODEPATCH[k]; });  // since-blessed diffs reset
    blessEchoUntil = Date.now()+3000;   // re-arm: the ledger pulse lands shortly AFTER the POST returns
  }catch(e){
    blessEchoUntil = 0;
    undo.forEach(({f,status})=>{ f.status=status; if(status==='stale') n.stale++; else if(status==='unblessed') n.unblessed++; n.clean--; });
    undo.forEach(({f,status})=>paintFileCard(f.path,status));
    NODES=flatten(); renderRail();
    toast('⚠ bless failed — reverted');
  }
}

// normalize either shape — forest {nodes,roots} OR linear {links} — into a flat,
// depth-tagged list in tree order. Rail + keyboard walk this uniformly.
let NODES = [];
function flatten(){
  if(MODEL.nodes){
    const out=[], seen=new Set();
    const walk=(b,d)=>{ if(seen.has(b))return; seen.add(b);
      const n=MODEL.nodes[b]; if(!n)return;
      out.push(Object.assign({}, n, {depth:d, id:b}));
      (n.children||[]).forEach(c=>walk(c,d+1)); };
    (MODEL.roots||[]).forEach(r=>walk(r,0));
    Object.keys(MODEL.nodes).forEach(b=>{ if(!seen.has(b)) walk(b,0); });
    return out;
  }
  return (MODEL.links||[]).map(l=>Object.assign({}, l, {depth:0, id:l.branch}));
}
// rollup over a node + all its descendants
function subtree(id){
  const n = MODEL.nodes ? MODEL.nodes[id] : NODES.find(x=>x.id===id);
  if(!n) return {clean:0,stale:0,unblessed:0,total:0};
  const r={clean:n.clean,stale:n.stale,unblessed:n.unblessed,total:n.total};
  (n.children||[]).forEach(c=>{const s=subtree(c); r.clean+=s.clean;r.stale+=s.stale;r.unblessed+=s.unblessed;r.total+=s.total;});
  return r;
}
function rollStatus(r){ return r.stale>0?'stale':(r.clean+r.stale===0?'unblessed':(r.unblessed>0?'partial':'clean')); }

