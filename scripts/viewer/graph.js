// ── graph canvas ──────────────────────────────────────
// unify both shapes into a {nodes, roots} adjacency for the diagram
function graphModel(){
  if(MODEL.nodes) return {nodes:MODEL.nodes, roots:MODEL.roots||[]};
  const nodes={}, links=MODEL.links||[];
  links.forEach((l,i)=>{ nodes[l.branch]=Object.assign({}, l, {children: i+1<links.length?[links[i+1].branch]:[]}); });
  return {nodes, roots: links.length?[links[0].branch]:[]};
}
function edge(x1,y1,x2,y2,st,i,from,to){ const mx=(x1+x2)/2; return `<path class="ge ${st}" data-from="${from||''}" data-to="${to||''}" style="animation-delay:${i*40}ms" d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}"/>`; }
// a SKIP-LEVEL parent edge (child is >1 column past its git parent — e.g. it merges
// after a same-parent sibling that occupies the column between them). Route LOW:
// drop to the child's row right out of the parent, then run flat to the child, so
// the rail passes BELOW the intervening sibling instead of sweeping through it.
function skipEdge(x1,y1,x2,y2,st,i,from,to){ const k=Math.min(48,(x2-x1)/3);
  return `<path class="ge ${st}" data-from="${from||''}" data-to="${to||''}" style="animation-delay:${i*40}ms" d="M${x1},${y1} C${x1+k},${y2} ${x2-k},${y2} ${x2},${y2}"/>`; }
// a PLANNED (`requires`) edge. When the carrier sits to the right it flows forward
// like any edge (source right → target left). But a planned dep often points at a
// SAME-COLUMN sibling (no structural offset) — there it hugs as a short vertical
// dashed connector (bottom→top center) instead of looping back across the grid.
function faninEdge(s,t,sw,tw,i,from,to){
  if(t.x > s.x+sw+8) return edge(s.x+sw,s.y,t.x,t.y,'fanin',i,from,to);
  // same-column siblings: hug the LEADING edge (left-third) as a vertical dashed
  // tie. Anchoring at center would cross the busy right side (a child junction);
  // riding the node edges (top/bottom, not mid-y) keeps it clear of the parent rail.
  const lx=Math.min(s.x,t.x)+22, down=t.y>=s.y, y1=s.y+(down?13:-13), y2=t.y+(down?-13:13);
  return `<path class="ge fanin" data-from="${from}" data-to="${to}" style="animation-delay:${i*40}ms" d="M${lx},${y1} L${lx},${y2}"/>`;
}
// open-PR decorations: branch → {num,url,draft,base,toMain}. Fetched ONCE and
// re-rendered when it lands. stack-prs persists the map in the git dir, so it's
// already warm on reload + after a server restart (no GitHub round-trip).
let GPRS = {}, _gprsLoading = false;
function ensurePRs(){
  if(_gprsLoading || typeof LIVE==='undefined' || !LIVE) return;
  _gprsLoading = true;
  fetch('/prs').then(r=>r.ok?r.json():{}).then(p=>{ GPRS = p||{};
    if(typeof renderRail==='function') renderRail();   // rail PR badges
    const m=$('#map'); if(m && m.classList.contains('on')) renderGraph('#map');
  }).catch(()=>{});
}
// fork-staleness decorations: branch → /sync ({behind, syncable}). One /sync per
// node (mirrors the branchbar), cached; re-renders when they land. A node whose
// fork point lags origin/main shows a "↺N" badge so staleness reads on the MAP,
// not just the selected branch's bar.
let GSYNC = {}, _gsyncLoading = false;
function ensureSync(){
  if(_gsyncLoading || typeof LIVE==='undefined' || !LIVE) return;
  _gsyncLoading = true;
  Promise.all(Object.keys(graphModel().nodes).map(b =>
    fetch('/sync?branch='+encodeURIComponent(b)).then(r=>r.ok?r.json():null)
      .then(s=>{ if(s) GSYNC[b]=s; }).catch(()=>{})
  )).then(()=>{
    if(typeof renderRail==='function') renderRail();   // rail ↺N badges
    const m=$('#map'); if(m && m.classList.contains('on')) renderGraph('#map');
  });
}
function isLanded(b){ const N=(typeof graphModel==='function')&&graphModel().nodes; return !!(N && N[b] && N[b].landed); }
function landedBadge(b,w){   // branch already merged into origin/main (commits patch-equal) — its ref just lingers
  if(!isLanded(b)) return '';
  const txt = '⤓merged', pw = 12 + txt.length*6.5;
  return `<g class="stalebadge landed" transform="translate(${w-pw/2+2},14)">
      <title>already merged into origin/main — restack to drop this branch</title>
      <rect class="sbp" x="${-pw/2}" y="-8" width="${pw}" height="16" rx="8"/>
      <text x="0" y="4">${txt}</text></g>`;
}
function staleBadge(b,w){   // a corner badge if this branch's fork point lags origin/main
  const s = GSYNC[b]; if(!s || !s.behind) return '';
  if(isLanded(b)) return '';   // landed reads as "drop it", not "restack to refresh" — landedBadge owns the corner
  const txt = '↺'+s.behind, pw = 12 + txt.length*7;
  const note = s.behind+' behind origin/main'
    + (s.syncable ? ' · syncable: rebase onto fresh origin/main (no force-push)'
                  : (s.why ? ' · '+s.why : ' · needs a restack'));
  // proud of the bottom-right corner (mirrors the PR badge at the top-right)
  return `<g class="stalebadge${s.syncable?' syncable':''}" transform="translate(${w-pw/2+2},14)">
      <title>${note}</title><rect class="sbp" x="${-pw/2}" y="-8" width="${pw}" height="16" rx="8"/>
      <text x="0" y="4">${txt}</text></g>`;
}
function prBadge(b,w){   // a corner badge if this branch has an open PR
  const pr = GPRS[b]; if(!pr) return '';
  // colour = base correctness (into main / off-base / draft); glyph = review state
  const kind = pr.draft ? 'draft' : (pr.toMain ? 'tomain' : 'offbase');
  const rev  = pr.review || '';   // APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ''
  const rs   = rev==='APPROVED' ? 'approved' : rev==='CHANGES_REQUESTED' ? 'changes' : 'pending';
  const glyph= rs==='approved' ? '✓' : rs==='changes' ? '!' : '↑';
  const revtxt = rs==='approved' ? 'approved' : rs==='changes' ? 'changes requested'
               : (rev==='REVIEW_REQUIRED' ? 'review required' : 'awaiting review');
  const note = `PR #${pr.num} → ${pr.base} · ${revtxt}` + (pr.draft?' · draft':'') + (pr.toMain?'':' · NOT into main');
  // sits proud of the node's top-right corner so it reads at a glance
  return `<g class="prbadge ${kind} ${rs}" data-pr="${pr.url}" transform="translate(${w-1},-12)">
      <title>${note}</title><circle r="9"/><text x="0" y="3.5">${glyph}</text></g>`;
}
// ── upstream merge requirements (hover tooltip) ───────────────────────────
// what must merge before `b` can become a candidate to merge into main: its
// parent chain back to a root that forks off main, PLUS the transitive `requires`
// (fan-in) closure. Each is still in the forest = still unmerged. Ordered nearest-
// main-first (i.e. merge order), and tagged stack-ancestor vs fan-in dependency.
function distToMain(b){ const N=graphModel().nodes; let d=0,x=b,g=0;
  while(x && N[x] && N[x].parent && N[x].parent!=='main' && N[N[x].parent] && g++<64){ x=N[x].parent; d++; }
  return d; }
function parentChain(b){ const N=graphModel().nodes; const s=new Set(); let x=b,g=0;
  while(x && N[x] && N[x].parent && N[x].parent!=='main' && N[N[x].parent] && g++<64){ x=N[x].parent; s.add(x); }
  return s; }
function upstreamOf(b){
  const N=graphModel().nodes, seen=new Set(), out=[];
  const visit=x=>{ const n=N[x]; if(!n) return;
    const ups=[]; if(n.parent && N[n.parent]) ups.push(n.parent); (n.requires||[]).forEach(r=>{ if(N[r]) ups.push(r); });
    ups.forEach(u=>{ if(!seen.has(u)){ seen.add(u); out.push(u); visit(u); } }); };
  visit(b);
  const chain=parentChain(b);
  return out
    .map(u=>({branch:u, fanin:!chain.has(u), d:distToMain(u)}))
    .sort((a,b2)=> a.d-b2.d || a.branch.localeCompare(b2.branch));
}
function prState(b){   // → {cls, glyph, meta} describing b's open PR (or none)
  const pr=GPRS[b];
  if(!pr) return {cls:'none', glyph:'∅', meta:'no PR yet'};
  if(pr.draft) return {cls:'draft', glyph:'◔', meta:`#${pr.num} draft`};
  const base = pr.toMain ? '' : ` → ${pr.base}`;
  if(pr.review==='APPROVED')          return {cls:'approved', glyph:'✓', meta:`#${pr.num} approved${base}`};
  if(pr.review==='CHANGES_REQUESTED') return {cls:'changes',  glyph:'!', meta:`#${pr.num} changes requested${base}`};
  return {cls:'pending', glyph:'⋯', meta:`#${pr.num} review required${base}`};
}
function verdictOf(b, up){   // can b merge into main now? gates on upstream AND its own PR
  const pr=GPRS[b], blockers=[];
  if(up.length) blockers.push(`${up.length} upstream`);
  if(!pr)                                 blockers.push('no PR yet');
  else if(pr.draft)                       blockers.push('PR in draft');
  else if(pr.review==='CHANGES_REQUESTED')blockers.push('changes requested');
  else if(pr.review!=='APPROVED')         blockers.push('review pending');
  else if(!pr.toMain)                      blockers.push(`PR → ${pr.base}, not main`);
  if(!blockers.length) return {cls:'ready', txt:'✓ ready to merge into main'};
  const cls = (pr && pr.review==='CHANGES_REQUESTED') ? 'changes' : 'blocked';
  return {cls, txt:'blocked: '+blockers.join(' · ')};
}
function nodeTip(){ let t=$('#ntip'); if(!t){ t=el('div'); t.id='ntip'; document.body.appendChild(t); } return t; }
let _tipBranch=null; const _purposeFetching=new Set();
function showTip(b, anchorEl){
  _tipBranch=b;
  const up=upstreamOf(b), self=prState(b), t=nodeTip();
  // lead with the WHY — the branch purpose. read-only, cached; lazy-fetch + re-render if missing.
  const pp = (typeof PURPOSE!=='undefined') ? PURPOSE[b] : null;
  let why='';
  if(pp && pp.thesis){ why=`<div class="tip-why"><span class="pwhy">✦</span> ${pp.thesis}</div>`; }
  else if(!pp && typeof LIVE!=='undefined' && LIVE && !_purposeFetching.has(b)){
    _purposeFetching.add(b);
    fetch('/purpose?branch='+encodeURIComponent(b)).then(r=>r.json()).then(p=>{
      PURPOSE[b]=p; _purposeFetching.delete(b); if(_tipBranch===b) showTip(b, anchorEl);
    }).catch(()=>_purposeFetching.delete(b));
  }
  // two kinds of upstream, deliberately kept distinct:
  //   builds on  → the git parent chain. a LOGICAL dependency: this branch
  //                literally compiles on top of those.
  //   merge after→ fan-in `requires`. a PLANNED dependency: no compile link,
  //                just a deliberate merge-order we stand by (and could pivot).
  const row = u=>{ const s=prState(u.branch);
    return `<li class="us ${s.cls}"><span class="us-g">${s.glyph}</span>
      <span class="us-b">${u.branch}</span>
      <span class="us-m">${s.meta}</span></li>`; };
  const builds = up.filter(u=>!u.fanin), planned = up.filter(u=>u.fanin);
  const sec = (title, items)=> items.length
    ? `<div class="tip-sec">${title}</div><ul class="tip-up">${items.map(row).join('')}</ul>` : '';
  const v = verdictOf(b, up);
  const verdict = `<div class="tip-v ${v.cls}">${v.txt}</div>`;
  t.innerHTML = `<div class="tip-h"><b>${b.split('/').pop()}</b>
      <span class="tip-self ${self.cls}">${self.glyph} ${self.meta}</span></div>${why}
    ${sec('builds on · logical ↓', builds)}
    ${sec('merge after · planned ↓', planned)}
    ${verdict}`;
  const r=anchorEl.getBoundingClientRect();
  t.style.left = Math.min(r.left, innerWidth-360)+'px';
  t.style.top  = Math.min(r.bottom+8, innerHeight-40)+'px';
  t.classList.add('on');
  spotlight(b);
}
// spotlight the merge path: light the hovered node + its upstream blockers and the
// edges between them, gold-glow those edges, dim everything else.
function spotlight(b){
  const up=new Set(upstreamOf(b).map(u=>u.branch));
  const lit=new Set([b, 'main', ...up]);   // 'main' so the root→main edges stay lit
  document.querySelectorAll('svg.graph').forEach(svg=>{
    svg.classList.add('focusing');
    svg.querySelectorAll('.gn[data-b]').forEach(g=>{ const id=g.getAttribute('data-b');
      g.classList.toggle('lit', lit.has(id)); g.classList.toggle('up', up.has(id)); });   // 'up' = a blocker to merge first
    svg.querySelectorAll('.ge').forEach(e=>{
      e.classList.toggle('lit', lit.has(e.getAttribute('data-from')) && lit.has(e.getAttribute('data-to'))); });
  });
}
function unspotlight(){
  document.querySelectorAll('svg.graph').forEach(svg=>{ svg.classList.remove('focusing');
    svg.querySelectorAll('.lit,.up').forEach(x=>x.classList.remove('lit','up')); });
}
function hideTip(){ _tipBranch=null; const t=$('#ntip'); if(t) t.classList.remove('on'); unspotlight(); }
function renderGraph(sel){
  ensurePRs();   // kick off the one-time PR fetch (re-renders the rail when it arrives)
  ensureSync();  // kick off per-node fork-staleness (re-renders the map when it lands)
  const tgt=$(sel); if(!tgt) return;   // #dock is gone — only the fullscreen map (#map) renders here
  const gm=graphModel();
  // ── contract spent nodes ───────────────────────────────────────────────────
  // A node whose own diff vs its parent is empty (total===0) is spent: squash-
  // merged into main (its commits now redundant) or nothing committed yet. It
  // adds nothing to review, so rather than draw a blank node we DROP it and lift
  // its children onto its nearest surviving ancestor (or main) — the graph
  // contracts by that node, exactly as `loops stack restack` contracts the real
  // forest. Build a copy; gm.nodes is the shared cached MODEL — never mutate it.
  const N = (()=>{ const src=gm.nodes, spent=b=>!!src[b] && (src[b].total||0)===0;
    const lift=p=>{ let g=0; while(p && p!=='main' && src[p] && spent(p) && g++<64) p=src[p].parent;
      return (p && p!=='main' && src[p] && !spent(p)) ? p : 'main'; };
    const out={};
    Object.keys(src).forEach(b=>{ if(spent(b)) return; const n=Object.assign({}, src[b]);
      n.parent = (src[b].parent && src[b].parent!=='main') ? lift(src[b].parent) : 'main';
      // keep only fan-in deps that still have a live (non-spent) node; a merged dep
      // is satisfied by main, so it just drops out.
      n.requires = [...new Set((src[b].requires||[]).filter(r=>src[r] && !spent(r) && r!==b))];
      n.children = []; out[b]=n; });
    Object.keys(out).forEach(b=>{ const p=out[b].parent; if(p!=='main' && out[p]) out[p].children.push(b); });
    return out; })();
  gm.roots = Object.keys(N).filter(b=>(N[b].parent||'main')==='main');
  if(!Object.keys(N).length){ tgt.innerHTML='<p style="color:var(--faint);margin:30px">nothing to graph — every branch here is merged into main</p>'; return; }
  const GAPY=64, GAPX=205, PADX=116, PADY=36, HGAP=70;
  let leafY=0; const pos={};
  const nodeW=b=>{ const lbl=b.split('/').pop(); return 50+lbl.length*7.2+34; };
  // each node reflects its OWN changes only — never a subtree rollup
  const own=b=>{ const n=N[b]||{}; return {clean:n.clean||0,stale:n.stale||0,unblessed:n.unblessed||0,total:n.total||0}; };
  // ── columns (x) = MERGE-SEQUENCE position: a node sits one past EVERYTHING that
  // must merge before it — its git parent chain (logical) AND its `requires`
  // (planned). So a node that merges after a same-parent sibling lands one column
  // further out, never in the sibling's column. When that pushes a node >1 column
  // past its git parent, the parent rail is routed LOW (see skipEdge) so it runs
  // below the intervening sibling instead of colliding with it.
  const depth={}; const depthOf=(b,g)=>{ if(depth[b]!=null) return depth[b]; if(g>64) return depth[b]=1;
    const n=N[b]||{}; let d=1;
    if(n.parent && n.parent!=='main' && N[n.parent]) d=Math.max(d, depthOf(n.parent,g+1)+1);
    (n.requires||[]).forEach(r=>{ if(N[r]) d=Math.max(d, depthOf(r,g+1)+1); });
    return depth[b]=d; };
  Object.keys(N).forEach(b=>depthOf(b,0));
  const maxD=Math.max(1, ...Object.values(depth));
  // variable-width columns: a column's x starts past the WIDEST node in the
  // previous column + HGAP. Fixed-stride columns let a long branch name overflow
  // into its child's column (the read-lock-from-flag / wire-and-cleanup overlap);
  // sizing each column to its content guarantees no node ever overlaps the next.
  const colMaxW={}; Object.keys(N).forEach(b=>{ const d=depth[b]; colMaxW[d]=Math.max(colMaxW[d]||0, nodeW(b)); });
  const colX={1:PADX+GAPX}; for(let d=2; d<=maxD; d++){ colX[d]=colX[d-1]+(colMaxW[d-1]||0)+HGAP; }
  // ── rows (y): tidy-tree over a layout spine. A node hangs under its git
  // parent; a dep that only forks off main is ADOPTED under the (first) fan-in
  // node that requires it, so requires-deps cluster beneath the node that
  // carries them instead of scattering down the column.
  const lkids={}; Object.keys(N).forEach(b=>lkids[b]=[]); const lpar={};
  Object.keys(N).forEach(b=>{ const p=N[b].parent; if(p && p!=='main' && N[p]) lpar[b]=p; });
  Object.keys(N).forEach(f=>{ (N[f].requires||[]).forEach(r=>{ if(N[r] && r!==f && lpar[r]==null) lpar[r]=f; }); });
  Object.keys(lpar).forEach(b=>{ if(lkids[lpar[b]]) lkids[lpar[b]].push(b); });
  const lroots=Object.keys(N).filter(b=>lpar[b]==null);
  const place=(b,g)=>{ const kids=(g>64?[]:lkids[b])||[]; let y;
    if(!kids.length){ y=leafY*GAPY; leafY++; } else { const ys=kids.map(c=>place(c,g+1)); y=(ys[0]+ys[ys.length-1])/2; }
    pos[b]={x:colX[depth[b]], y:PADY+y, depth:depth[b]}; return y; };
  lroots.forEach(r=>place(r,0));
  // safety: any node missed (e.g. a requires-cycle) still gets its own row
  Object.keys(N).forEach(b=>{ if(!pos[b]){ pos[b]={x:colX[depth[b]], y:PADY+leafY*GAPY, depth:depth[b]}; leafY++; } });
  const rootYs=gm.roots.map(r=>pos[r]?pos[r].y:PADY);
  const mainY=rootYs.length? rootYs.reduce((a,b)=>a+b,0)/rootYs.length : PADY;
  const W=colX[maxD]+(colMaxW[maxD]||0)+PADX, H=PADY*2+Math.max(1,leafY)*GAPY;
  let E='', G='', ei=0, gi=0;
  gm.roots.forEach(r=>{ if(pos[r]) E+=edge(54,mainY,pos[r].x,pos[r].y,rollStatus(own(r)),ei++,'main',r); });
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; ((N[b].children)||[]).forEach(c=>{ if(!pos[c])return;
    const fn = (pos[c].depth - p.depth > 1) ? skipEdge : edge;   // low-route when the child skips a column past its parent
    E+=fn(p.x+nodeW(b),p.y,pos[c].x,pos[c].y,rollStatus(own(c)),ei++,b,c); }); });
  // fan-in: a "phantom" inbound edge from each `requires` dep into the node that
  // carries it — a PLANNED (deliberate, revisable) merge-order, not a logical
  // build-link, so it reads in a softer/neutral style than the solid parent rail.
  // Edge-case: if the dep is already a parent-ANCESTOR, the solid chain implies
  // it — drawing a dashed edge too would contradict, so skip it as redundant.
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; const chain=parentChain(b);
    ((N[b].requires)||[]).forEach(rq=>{ if(pos[rq] && !chain.has(rq)) E+=faninEdge(pos[rq],p,nodeW(rq),nodeW(b),ei++,rq,b); }); });
  G+=`<g class="gn main" style="animation-delay:80ms" transform="translate(40,${mainY})"><circle r="6"/><text x="16" y="4">main</text></g>`;
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; const r=own(b), w=nodeW(b);
    const done = r.total>0 && r.clean===r.total && r.stale===0;   // this branch's own files all reviewed
    const cnt = `${r.clean}/${r.total}`;   // always the count — gold border already signals "all blessed"; a 2nd ✓ collided with the PR badge
    // legal-to-merge: nothing upstream still in the forest (parent is main + all fan-in
    // deps landed) AND an open PR exists — i.e. "this PR is unblocked, go merge it".
    // surfaced persistently as a left edge-bar so the ready bases read without a hover.
    // (PR map loads async; ensurePRs re-renders the map once it lands, lighting these up.)
    const mergeable = !!(N[b] && N[b].mergeable) && !!GPRS[b];   // topology from stack-forest; PR keeps the bar to "ready"
    const mbar = mergeable ? `<rect class="mbar" x="-5" y="-13" width="3.5" height="26" rx="1.75"><title>legal to merge into main — no upstream blockers</title></rect>` : '';
    G+=`<g class="gn ${done?'clean done':rollStatus(r)}${mergeable?' mergeable':''}${b===active?' sel':''}" data-b="${b}" style="animation-delay:${120+gi++*45}ms" transform="translate(${p.x},${p.y})">
      ${mbar}<rect x="0" y="-14" rx="8" width="${w}" height="28"/><circle class="d" cx="16" cy="0" r="5"/>
      <text x="30" y="4.5">${b.split('/').pop()}</text><text class="cnt" x="${w-12}" y="4.5">${cnt}</text>${prBadge(b,w)}${landedBadge(b,w)}${staleBadge(b,w)}</g>`; });
  // legend: name the two edge kinds so the visual language decodes at a glance —
  // solid rail = logical (builds on parent), phantom = planned (merge-after fan-in).
  // swatches reuse the real .ge classes so they never drift from the actual edges.
  const swatch = cls=>`<svg class="lgsw" width="26" height="8" viewBox="0 0 26 8"><path class="ge ${cls}" style="animation:none;opacity:1" d="M1,4 L25,4"/></svg>`;
  const legend = `<span class="maplegend">${swatch('clean')}<span class="lgl">builds on</span>${swatch('fanin')}<span class="lgl">merge after · planned</span></span>`;
  const header = sel==='#map' ? `<div class="maphd"><h3>${MODEL.project||MODEL.leaf||'stack'} — dependency graph</h3>${legend}<span class="mapclose">click a node · esc to close</span></div>` : '';
  tgt.innerHTML = header + `<svg class="graph" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">${E}${G}</svg>`;
  tgt.querySelectorAll('.gn[data-b]').forEach(g=>{ g.onclick=()=>{ active=g.getAttribute('data-b'); if(sel==='#map') toggleMap(false); render(); };
    // hover → what must merge before this branch is a candidate to merge into main
    g.addEventListener('mouseenter',()=>showTip(g.getAttribute('data-b'), g));
    g.addEventListener('mouseleave',hideTip); });
  // a click on the PR badge opens the PR instead of selecting the node
  tgt.querySelectorAll('.prbadge[data-pr]').forEach(g=>g.addEventListener('click',e=>{ e.stopPropagation(); window.open(g.getAttribute('data-pr'),'_blank'); }));
}
function buildDock(){ renderGraph('#dock'); }
function updateDockSel(){ document.querySelectorAll('#dock .gn[data-b]').forEach(g=>g.classList.toggle('sel', g.getAttribute('data-b')===active)); }
function toggleMap(on){ const m=$('#map'); const show = on===undefined ? !m.classList.contains('on') : on; if(show) renderGraph('#map'); m.classList.toggle('on',show); if(typeof writeView==='function') writeView(); }
function curObj(){ return NODES.find(n=>n.id===active) || NODES[NODES.length-1] || {branch:'',parent:'',files:[]}; }
function pickInitial(){ const bad=NODES.find(n=>n.stale+n.unblessed>0); return (bad||NODES[NODES.length-1]||{}).id; }

