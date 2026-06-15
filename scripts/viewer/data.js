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
  // IMPORTANT: never cache a FAILED fetch. A transient error (e.g. the server
  // reaped + relaunched on a new port) must not poison this node into a permanent
  // "no textual diff" — clear the cache entry so the next render retries.
  NODEPATCH[key] = fetch(q)
    .then(r=>{ if(!r.ok) throw new Error('node '+r.status); return r.json(); })
    .catch(e=>{ delete NODEPATCH[key]; throw e; });
  return NODEPATCH[key];
}
// patch map {path:{patch,stale}} for the per-file diff renderer (shares fetchNode's cache)
function ensureNode(branch, base){
  return fetchNode(branch, base).then(d=>{ const m={}; (d.files||[]).forEach(f=>{ m[f.path]={patch:f.patch, stale:f.stale}; }); return m; });
}

const $ = (s,r=document)=>r.querySelector(s);
const el = (t,c,h)=>{const e=document.createElement(t); if(c)e.className=c; if(h!=null)e.innerHTML=h; return e;};
const segPath = p => p.replace(/(.*\/)([^/]+)$/, '<span class="seg">$1</span>$2');

function toast(html){const t=$('#toast'); t.innerHTML=html; t.classList.add('show'); clearTimeout(t._t); t._t=setTimeout(()=>t.classList.remove('show'),1900);}

async function fetchModel(){
  const b = Q.get('branch') || (MODEL && (MODEL.project||MODEL.leaf)) || '';
  const r = await fetch('/model?branch=' + encodeURIComponent(b));
  if(!r.ok) throw new Error('model fetch failed');
  return r.json();
}
// bless: live → POST then re-fetch (staleness recomputed server-side); static → copy the command
async function doBless(branch, file){
  if(!LIVE){ toast('read-only snapshot — open via <b>loops stack review --html</b> to bless'); return; }
  toast('blessing…');
  await fetch('/bless',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch,file})});
  Object.keys(NODEPATCH).forEach(k=>{ if(k===branch || k.startsWith(branch+'@')) delete NODEPATCH[k]; });  // all base-variants stale
  MODEL = await fetchModel();
  render(); toast('✦ blessed');
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

