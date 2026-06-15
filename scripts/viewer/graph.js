// ── graph canvas ──────────────────────────────────────
// unify both shapes into a {nodes, roots} adjacency for the diagram
function graphModel(){
  if(MODEL.nodes) return {nodes:MODEL.nodes, roots:MODEL.roots||[]};
  const nodes={}, links=MODEL.links||[];
  links.forEach((l,i)=>{ nodes[l.branch]=Object.assign({}, l, {children: i+1<links.length?[links[i+1].branch]:[]}); });
  return {nodes, roots: links.length?[links[0].branch]:[]};
}
function edge(x1,y1,x2,y2,st,i,from,to){ const mx=(x1+x2)/2; return `<path class="ge ${st}" data-from="${from||''}" data-to="${to||''}" style="animation-delay:${i*40}ms" d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}"/>`; }
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
function showTip(b, anchorEl){
  const up=upstreamOf(b), self=prState(b), t=nodeTip();
  const rows = up.map(u=>{ const s=prState(u.branch);
    return `<li class="us ${s.cls}"><span class="us-g">${s.glyph}</span>
      <span class="us-b">${u.branch}</span>${u.fanin?'<span class="us-tag">fan-in</span>':''}
      <span class="us-m">${s.meta}</span></li>`; }).join('');
  const v = verdictOf(b, up);
  const verdict = `<div class="tip-v ${v.cls}">${v.txt}</div>`;
  t.innerHTML = `<div class="tip-h"><b>${b.split('/').pop()}</b>
      <span class="tip-self ${self.cls}">${self.glyph} ${self.meta}</span></div>
    ${up.length?`<div class="tip-sec">must merge first · merge order ↓</div><ul class="tip-up">${rows}</ul>`:''}
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
function hideTip(){ const t=$('#ntip'); if(t) t.classList.remove('on'); unspotlight(); }
function renderGraph(sel){
  ensurePRs();   // kick off the one-time PR fetch (re-renders the rail when it arrives)
  const tgt=$(sel); if(!tgt) return;   // #dock is gone — only the fullscreen map (#map) renders here
  const gm=graphModel(), N=gm.nodes;
  if(!Object.keys(N).length){ tgt.innerHTML='<p style="color:var(--faint);margin:30px">nothing to graph</p>'; return; }
  const GAPY=52, GAPX=205, PADX=116, PADY=36;
  let leafY=0; const pos={};
  // each node reflects its OWN changes only — never a subtree rollup
  const own=b=>{ const n=N[b]||{}; return {clean:n.clean||0,stale:n.stale||0,unblessed:n.unblessed||0,total:n.total||0}; };
  const place=(b,d)=>{ const kids=(N[b]&&N[b].children)||[]; let y;
    if(!kids.length){ y=leafY*GAPY; leafY++; } else { const ys=kids.map(c=>place(c,d+1)); y=(ys[0]+ys[ys.length-1])/2; }
    pos[b]={x:PADX+d*GAPX, y:PADY+y, depth:d}; return y; };
  gm.roots.forEach(r=>place(r,1));
  const rootYs=gm.roots.map(r=>pos[r]?pos[r].y:PADY);
  const mainY=rootYs.length? rootYs.reduce((a,b)=>a+b,0)/rootYs.length : PADY;
  const maxD=Math.max(1, ...Object.values(pos).map(p=>p.depth));
  const W=PADX+(maxD+1)*GAPX, H=PADY*2+Math.max(1,leafY)*GAPY;
  const nodeW=b=>{ const lbl=b.split('/').pop(); return 50+lbl.length*7.2+34; };
  let E='', G='', ei=0, gi=0;
  gm.roots.forEach(r=>{ if(pos[r]) E+=edge(54,mainY,pos[r].x,pos[r].y,rollStatus(own(r)),ei++,'main',r); });
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; ((N[b].children)||[]).forEach(c=>{ if(pos[c]) E+=edge(p.x+nodeW(b),p.y,pos[c].x,pos[c].y,rollStatus(own(c)),ei++,b,c); }); });
  // fan-in: dashed inbound edge from each `requires` dep into the node that carries it
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; ((N[b].requires)||[]).forEach(rq=>{ if(pos[rq]) E+=edge(pos[rq].x+nodeW(rq),pos[rq].y,p.x,p.y,'fanin',ei++,rq,b); }); });
  G+=`<g class="gn main" style="animation-delay:80ms" transform="translate(40,${mainY})"><circle r="6"/><text x="16" y="4">main</text></g>`;
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; const r=own(b), w=nodeW(b);
    const done = r.total>0 && r.clean===r.total && r.stale===0;   // this branch's own files all reviewed
    const cnt = `${r.clean}/${r.total}`;   // always the count — gold border already signals "all blessed"; a 2nd ✓ collided with the PR badge
    G+=`<g class="gn ${done?'clean done':rollStatus(r)}${b===active?' sel':''}" data-b="${b}" style="animation-delay:${120+gi++*45}ms" transform="translate(${p.x},${p.y})">
      <rect x="0" y="-14" rx="8" width="${w}" height="28"/><circle class="d" cx="16" cy="0" r="5"/>
      <text x="30" y="4.5">${b.split('/').pop()}</text><text class="cnt" x="${w-12}" y="4.5">${cnt}</text>${prBadge(b,w)}</g>`; });
  const header = sel==='#map' ? `<div class="maphd"><h3>${MODEL.project||MODEL.leaf||'stack'} — dependency graph</h3><span class="mapclose">click a node · esc to close</span></div>` : '';
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
function toggleMap(on){ const m=$('#map'); const show = on===undefined ? !m.classList.contains('on') : on; if(show) renderGraph('#map'); m.classList.toggle('on',show); }
function curObj(){ return NODES.find(n=>n.id===active) || NODES[NODES.length-1] || {branch:'',parent:'',files:[]}; }
function pickInitial(){ const bad=NODES.find(n=>n.stale+n.unblessed>0); return (bad||NODES[NODES.length-1]||{}).id; }

