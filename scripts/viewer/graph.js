// ── graph canvas ──────────────────────────────────────
// unify both shapes into a {nodes, roots} adjacency for the diagram
function graphModel(){
  if(MODEL.nodes) return {nodes:MODEL.nodes, roots:MODEL.roots||[]};
  const nodes={}, links=MODEL.links||[];
  links.forEach((l,i)=>{ nodes[l.branch]=Object.assign({}, l, {children: i+1<links.length?[links[i+1].branch]:[]}); });
  return {nodes, roots: links.length?[links[0].branch]:[]};
}
function edge(x1,y1,x2,y2,st,i){ const mx=(x1+x2)/2; return `<path class="ge ${st}" style="animation-delay:${i*40}ms" d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}"/>`; }
function renderGraph(sel){
  const tgt=$(sel), gm=graphModel(), N=gm.nodes;
  if(!Object.keys(N).length){ tgt.innerHTML='<p style="color:var(--faint);margin:30px">nothing to graph</p>'; return; }
  const GAPY=52, GAPX=205, PADX=116, PADY=36;
  let leafY=0; const pos={}, sub={};
  const roll=b=>{ if(sub[b])return sub[b]; const n=N[b]||{}; const r={clean:n.clean||0,stale:n.stale||0,unblessed:n.unblessed||0,total:n.total||0};
    (n.children||[]).forEach(c=>{const s=roll(c); r.clean+=s.clean;r.stale+=s.stale;r.unblessed+=s.unblessed;r.total+=s.total;}); return sub[b]=r; };
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
  gm.roots.forEach(r=>{ if(pos[r]) E+=edge(54,mainY,pos[r].x,pos[r].y,rollStatus(roll(r)),ei++); });
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; ((N[b].children)||[]).forEach(c=>{ if(pos[c]) E+=edge(p.x+nodeW(b),p.y,pos[c].x,pos[c].y,rollStatus(roll(c)),ei++); }); });
  // fan-in: dashed inbound edge from each `requires` dep into the node that carries it
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; ((N[b].requires)||[]).forEach(rq=>{ if(pos[rq]) E+=edge(pos[rq].x+nodeW(rq),pos[rq].y,p.x,p.y,'fanin',ei++); }); });
  G+=`<g class="gn main" style="animation-delay:80ms" transform="translate(40,${mainY})"><circle r="6"/><text x="16" y="4">main</text></g>`;
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; const r=roll(b), w=nodeW(b);
    G+=`<g class="gn ${rollStatus(r)}${b===active?' sel':''}" data-b="${b}" style="animation-delay:${120+gi++*45}ms" transform="translate(${p.x},${p.y})">
      <rect x="0" y="-14" rx="8" width="${w}" height="28"/><circle class="d" cx="16" cy="0" r="5"/>
      <text x="30" y="4.5">${b.split('/').pop()}</text><text class="cnt" x="${w-12}" y="4.5">${r.clean}/${r.total}</text></g>`; });
  const header = sel==='#map' ? `<div class="maphd"><h3>${MODEL.project||MODEL.leaf||'stack'} — dependency graph</h3><span class="mapclose">click a node · esc to close</span></div>` : '';
  tgt.innerHTML = header + `<svg class="graph" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">${E}${G}</svg>`;
  tgt.querySelectorAll('.gn[data-b]').forEach(g=>g.onclick=()=>{ active=g.getAttribute('data-b'); if(sel==='#map') toggleMap(false); render(); });
}
function buildDock(){ renderGraph('#dock'); }
function updateDockSel(){ document.querySelectorAll('#dock .gn[data-b]').forEach(g=>g.classList.toggle('sel', g.getAttribute('data-b')===active)); }
function toggleMap(on){ const m=$('#map'); const show = on===undefined ? !m.classList.contains('on') : on; if(show) renderGraph('#map'); m.classList.toggle('on',show); }
function curObj(){ return NODES.find(n=>n.id===active) || NODES[NODES.length-1] || {branch:'',parent:'',files:[]}; }
function pickInitial(){ const bad=NODES.find(n=>n.stale+n.unblessed>0); return (bad||NODES[NODES.length-1]||{}).id; }

