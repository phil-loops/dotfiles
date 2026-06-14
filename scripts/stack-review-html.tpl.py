#!/usr/bin/env python3
"""Inject the stack model JSON into the review HTML template. Usage: tpl.py <model.json> <out.html>"""
import sys

model = open(sys.argv[1]).read()

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>blessing ledger</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,600;1,9..144,500&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/diff2html/bundles/css/diff2html.min.css">
<script src="https://cdn.jsdelivr.net/npm/diff2html/bundles/js/diff2html-ui.min.js"></script>
<style>
:root{
  --bg:#15110b; --rail:#1b160f; --panel:#1d1810; --raised:#241d13;
  --ink:#ece2cf; --dim:#8f8472; --faint:#5d5547; --line:#2e2619;
  --gold:#e0ad4e; --gold-soft:#3a2d12; --ember:#d36a36; --ember-soft:#3a2114;
  --unbl:#6f6650; --add:#7a9d5f; --del:#bf6055;
}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{
  background:var(--bg); color:var(--ink);
  font-family:'IBM Plex Mono',ui-monospace,monospace; font-size:13px; line-height:1.6;
  display:grid; grid-template-columns:296px 1fr; height:100vh; overflow:hidden;
}
/* grain + vignette atmosphere */
body::before{content:"";position:fixed;inset:0;pointer-events:none;z-index:99;
  background:radial-gradient(120% 100% at 50% -10%,transparent 55%,#0000 0,#00000066 100%);
  mix-blend-mode:multiply}
body::after{content:"";position:fixed;inset:0;pointer-events:none;z-index:98;opacity:.035;
  background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='160' height='160'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/></filter><rect width='100%25' height='100%25' filter='url(%23n)'/></svg>")}

/* ── rail ───────────────────────────────────────────── */
.rail{background:var(--rail);border-right:1px solid var(--line);display:flex;flex-direction:column;overflow:hidden}
.brand{padding:22px 22px 16px;border-bottom:1px solid var(--line)}
.brand h1{font-family:'Fraunces',serif;font-weight:600;font-size:23px;margin:0;letter-spacing:.2px;
  font-style:italic;color:var(--ink)}
.brand .sub{color:var(--faint);font-size:11px;margin-top:5px;letter-spacing:.18em;text-transform:uppercase}
.progress{margin:14px 22px 4px}
.bar{height:3px;background:var(--gold-soft);border-radius:2px;overflow:hidden}
.bar > i{display:block;height:100%;background:linear-gradient(90deg,var(--gold),#f4d27a);
  width:0;transition:width 1.1s cubic-bezier(.2,.8,.2,1);box-shadow:0 0 12px #e0ad4e88}
.tally{display:flex;gap:14px;margin:9px 22px 14px;color:var(--dim);font-size:11px}
.tally b{color:var(--ink);font-weight:600}
.links{list-style:none;margin:0;padding:8px 12px;overflow:auto;flex:1}
.lk{padding:11px 12px;border-radius:8px;cursor:pointer;border:1px solid transparent;
  display:flex;flex-direction:column;gap:5px;transition:.16s;position:relative}
.lk:hover{background:var(--panel)}
.lk.on{background:var(--panel);border-color:var(--line)}
.lk.on::before{content:"";position:absolute;left:-12px;top:14px;bottom:14px;width:2px;
  background:var(--gold);border-radius:2px;box-shadow:0 0 10px var(--gold)}
.lk .nm{font-size:12.5px;color:var(--ink);word-break:break-all}
.lk .guide{color:var(--faint);opacity:.6}
.lk .pr{font-size:10.5px;color:var(--faint);padding-left:2px}
.lk .meter{display:flex;gap:3px;margin-top:3px}
.lk .meter i{height:4px;flex:1;border-radius:2px;background:var(--line)}
.lk .meter i.c{background:var(--gold)} .lk .meter i.s{background:var(--ember)} .lk .meter i.u{background:var(--unbl)}
.dot{width:7px;height:7px;border-radius:50%;display:inline-block}
.dot.clean{background:var(--gold);box-shadow:0 0 7px var(--gold)} .dot.stale{background:var(--ember)} .dot.unblessed{background:var(--unbl)} .dot.partial{background:var(--ember)}

/* ── main ───────────────────────────────────────────── */
.main{overflow:auto;padding:30px 38px 120px}
.hd{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap;margin-bottom:4px}
.hd h2{font-family:'Fraunces',serif;font-weight:600;font-size:27px;margin:0;color:var(--ink);font-style:italic}
.hd .arrow{color:var(--faint)} .hd .par{color:var(--dim);font-size:13px}
.sub2{color:var(--dim);font-size:12px;margin:2px 0 20px;display:flex;gap:16px;align-items:center}
.sub2 .pill{padding:2px 9px;border:1px solid var(--line);border-radius:20px;cursor:pointer;color:var(--dim);transition:.15s}
.sub2 .pill:hover{color:var(--ink);border-color:var(--dim)}
.sub2 .pill.on{color:var(--gold);border-color:var(--gold-soft);background:var(--gold-soft)}
.blessall{margin-left:auto;font:inherit;font-size:11.5px;color:var(--gold);background:none;border:1px solid var(--gold-soft);
  padding:5px 13px;border-radius:7px;cursor:pointer;transition:.15s;letter-spacing:.04em}
.blessall:hover{background:var(--gold-soft);box-shadow:0 0 16px #e0ad4e33}

/* file card */
.file{border:1px solid var(--line);border-radius:11px;margin:11px 0;background:var(--panel);overflow:hidden;
  opacity:0;transform:translateY(8px);animation:rise .5s cubic-bezier(.2,.8,.2,1) forwards}
@keyframes rise{to{opacity:1;transform:none}}
.frow{display:flex;align-items:center;gap:12px;padding:13px 16px;cursor:pointer;user-select:none}
.frow:hover{background:var(--raised)}
.chip{flex:none;width:22px;height:22px;border-radius:6px;display:grid;place-items:center;font-size:12px;font-weight:600}
.chip.clean{color:var(--gold);background:var(--gold-soft);box-shadow:inset 0 0 0 1px #e0ad4e44}
.chip.stale{color:var(--ember);background:var(--ember-soft);box-shadow:inset 0 0 0 1px #d36a3644}
.chip.unblessed{color:var(--unbl);background:#241d13;box-shadow:inset 0 0 0 1px var(--line)}
.fpath{flex:1;font-size:12.5px;color:var(--ink);word-break:break-all}
.fpath .seg{color:var(--faint)}
.tag{font-size:10px;letter-spacing:.16em;text-transform:uppercase;color:var(--faint)}
.tag.stale{color:var(--ember)} .tag.clean{color:var(--gold)}
.bless{font:inherit;font-size:11px;border:1px solid var(--line);background:var(--raised);color:var(--dim);
  padding:4px 11px;border-radius:7px;cursor:pointer;transition:.15s;white-space:nowrap}
.bless:hover{color:var(--gold);border-color:var(--gold-soft);background:var(--gold-soft)}
.file.clean .frow{opacity:.62} .file.clean:hover .frow,.file.clean.open .frow{opacity:1}
.body{display:none;border-top:1px solid var(--line)}
.file.open .body{display:block}
.since{margin:0;padding:10px 16px;background:var(--ember-soft);border-bottom:1px solid var(--line);
  color:var(--ember);font-size:10.5px;letter-spacing:.16em;text-transform:uppercase}
.d2h-wrap{padding:2px 4px}
.caret{color:var(--faint);transition:transform .2s;flex:none}
.file.open .caret{transform:rotate(90deg)}

/* toast */
#toast{position:fixed;bottom:26px;left:50%;transform:translateX(-50%) translateY(20px);opacity:0;
  background:var(--raised);border:1px solid var(--gold-soft);color:var(--ink);padding:10px 18px;border-radius:9px;
  font-size:12px;transition:.25s;z-index:120;box-shadow:0 14px 40px #0008}
#toast.show{opacity:1;transform:translateX(-50%)}
#toast b{color:var(--gold)}

/* diff2html dark retune */
.d2h-file-wrapper{border:none!important;margin:0!important;border-radius:0!important;background:transparent!important}
.d2h-file-header{display:none!important}
.d2h-code-line,.d2h-code-side-line{font-family:'IBM Plex Mono',monospace!important;font-size:12px!important}
.d2h-diff-table{background:transparent!important}
.d2h-code-linenumber,.d2h-code-side-linenumber{background:var(--panel)!important;color:var(--faint)!important;border-color:var(--line)!important}
.d2h-ins{background:#1c2616!important} .d2h-ins .d2h-code-line-ctn{color:#bcd9a3!important}
.d2h-del{background:#2a1714!important} .d2h-del .d2h-code-line-ctn{color:#e0a59c!important}
.d2h-cntx .d2h-code-line-ctn{color:var(--dim)!important}
.d2h-info{background:var(--raised)!important;color:var(--faint)!important}
.hljs{background:transparent!important}
::selection{background:#e0ad4e44}

/* ── graph canvas overlay ───────────────────────────── */
.mapbtn{margin:13px 22px 2px;font:inherit;font-size:11px;color:var(--gold);background:none;
  border:1px solid var(--gold-soft);padding:5px 12px;border-radius:7px;cursor:pointer;letter-spacing:.06em;transition:.15s}
.mapbtn:hover{background:var(--gold-soft);box-shadow:0 0 14px #e0ad4e22}
.mapwrap{position:fixed;inset:0;z-index:200;display:none;overflow:auto;padding:26px 34px;
  background:radial-gradient(130% 90% at 28% -5%,#1d180f 0%,#100d08 70%)}
.mapwrap.on{display:block;animation:fadein .28s ease}
@keyframes fadein{from{opacity:0}to{opacity:1}}
.maphd{display:flex;align-items:baseline;gap:16px;margin-bottom:10px}
.maphd h3{font-family:'Fraunces',serif;font-style:italic;font-weight:600;font-size:23px;margin:0;color:var(--ink)}
.maphd .mapclose{color:var(--faint);font-size:11px;letter-spacing:.12em;text-transform:uppercase}
svg.graph{display:block;overflow:visible}
.ge{fill:none;stroke:var(--line);stroke-width:1.6;opacity:.85;stroke-dasharray:1;
  animation:flow .9s ease forwards}
@keyframes flow{from{stroke-dashoffset:1;opacity:0}to{stroke-dashoffset:0;opacity:.85}}
.ge.clean{stroke:#e0ad4e66} .ge.stale{stroke:#d36a3666} .ge.partial{stroke:#d36a3644} .ge.unblessed{stroke:var(--line)}
.gn{cursor:pointer;opacity:0;animation:rise .45s ease forwards}
.gn rect{fill:var(--panel);stroke:var(--line);stroke-width:1.2;transition:.15s}
.gn:hover rect{stroke:var(--dim);fill:var(--raised)}
.gn.sel rect{stroke:var(--gold);filter:drop-shadow(0 0 9px #e0ad4e55)}
.gn text{font-family:'IBM Plex Mono',monospace;font-size:11.5px;fill:var(--ink)}
.gn .cnt{fill:var(--faint);font-size:10px;text-anchor:end}
.gn .d{stroke:none}
.gn.clean .d{fill:var(--gold);filter:drop-shadow(0 0 5px #e0ad4eaa)} .gn.clean rect{stroke:#e0ad4e44}
.gn.stale .d{fill:var(--ember)} .gn.unblessed .d{fill:var(--unbl)} .gn.partial .d{fill:var(--ember)}
.gn.main circle{fill:var(--gold);filter:drop-shadow(0 0 7px #e0ad4e)}
.gn.main text{fill:var(--gold);font-family:'Fraunces',serif;font-style:italic;font-size:15px}
.main::-webkit-scrollbar,.links::-webkit-scrollbar{width:9px}
.main::-webkit-scrollbar-thumb,.links::-webkit-scrollbar-thumb{background:var(--line);border-radius:9px}
</style>
</head>
<body>
<nav class="rail">
  <div class="brand">
    <h1>blessed</h1>
    <div class="sub" id="leaf"></div>
    <button class="mapbtn" id="mapbtn">◇ graph view &nbsp;<span style="opacity:.6">m</span></button>
  </div>
  <div class="progress"><div class="bar"><i id="bar"></i></div></div>
  <div class="tally" id="tally"></div>
  <ul class="links" id="rail"></ul>
</nav>
<main class="main" id="main"></main>
<div class="mapwrap" id="map"></div>
<div id="toast"></div>

<script>
const BAKED = __MODEL__;                       // static snapshot: model is null when served live
const LIVE = !BAKED;                           // live mode → fetch /model, bless over HTTP
const Q = new URLSearchParams(location.search);
let MODEL = BAKED || null;
let active = 0, filter = 'all';

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
  if(!LIVE){
    const cmd = `loops bless ${branch}${file==='.'?'':' --file '+file}`;
    navigator.clipboard?.writeText(cmd); toast(`copied &nbsp;<b>${cmd}</b>`); return;
  }
  toast('blessing…');
  await fetch('/bless',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch,file})});
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

// ── graph canvas ──────────────────────────────────────
// unify both shapes into a {nodes, roots} adjacency for the diagram
function graphModel(){
  if(MODEL.nodes) return {nodes:MODEL.nodes, roots:MODEL.roots||[]};
  const nodes={}, links=MODEL.links||[];
  links.forEach((l,i)=>{ nodes[l.branch]=Object.assign({}, l, {children: i+1<links.length?[links[i+1].branch]:[]}); });
  return {nodes, roots: links.length?[links[0].branch]:[]};
}
function edge(x1,y1,x2,y2,st,i){ const mx=(x1+x2)/2; return `<path class="ge ${st}" style="animation-delay:${i*40}ms" d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}"/>`; }
function renderGraph(){
  const gm=graphModel(), N=gm.nodes;
  if(!Object.keys(N).length){ $('#map').innerHTML='<p style="color:var(--faint);margin:50px">nothing to graph</p>'; return; }
  const GAPY=58, GAPX=215, PADX=130, PADY=48;
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
  G+=`<g class="gn main" style="animation-delay:80ms" transform="translate(40,${mainY})"><circle r="6"/><text x="16" y="4">main</text></g>`;
  Object.keys(N).forEach(b=>{ const p=pos[b]; if(!p)return; const r=roll(b), w=nodeW(b);
    G+=`<g class="gn ${rollStatus(r)}${b===active?' sel':''}" data-b="${b}" style="animation-delay:${120+gi++*45}ms" transform="translate(${p.x},${p.y})">
      <rect x="0" y="-14" rx="8" width="${w}" height="28"/><circle class="d" cx="16" cy="0" r="5"/>
      <text x="30" y="4.5">${b.split('/').pop()}</text><text class="cnt" x="${w-12}" y="4.5">${r.clean}/${r.total}</text></g>`; });
  $('#map').innerHTML=`<div class="maphd"><h3>${MODEL.project||MODEL.leaf||'stack'} — dependency graph</h3><span class="mapclose">click a node · esc to close</span></div>
    <svg class="graph" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">${E}${G}</svg>`;
  $('#map').querySelectorAll('.gn[data-b]').forEach(g=>g.onclick=()=>{ active=g.getAttribute('data-b'); toggleMap(false); render(); });
}
function toggleMap(on){ const m=$('#map'); const show = on===undefined ? !m.classList.contains('on') : on; if(show) renderGraph(); m.classList.toggle('on',show); }
function curObj(){ return NODES.find(n=>n.id===active) || NODES[NODES.length-1] || {branch:'',parent:'',files:[]}; }
function pickInitial(){ const bad=NODES.find(n=>n.stale+n.unblessed>0); return (bad||NODES[NODES.length-1]||{}).id; }

function renderRail(){
  $('#leaf').textContent = MODEL.project || MODEL.leaf || '';
  const tot=NODES.reduce((a,n)=>{a.c+=n.clean;a.s+=n.stale;a.u+=n.unblessed;a.t+=n.total;return a;},{c:0,s:0,u:0,t:0});
  $('#bar').style.width=(tot.t?Math.round(100*tot.c/tot.t):0)+'%';
  $('#tally').innerHTML=`<span><b>${tot.c}</b> blessed</span><span><b>${tot.s}</b> stale</span><span><b>${tot.u}</b> new</span>`;
  const rail=$('#rail'); rail.innerHTML='';
  NODES.forEach(n=>{
    const sub=subtree(n.id);
    const li=el('li','lk'+(n.id===active?' on':''));
    li.style.paddingLeft=(12+n.depth*16)+'px';
    const meter = n.total? `<div class="meter">${'<i class="c"></i>'.repeat(n.clean)}${'<i class="s"></i>'.repeat(n.stale)}${'<i class="u"></i>'.repeat(n.unblessed)}</div>`:'';
    const guide = n.depth>0 ? '<span class="guide">└&nbsp;</span>' : '';
    const kids = (n.children&&n.children.length)? ` · ${n.children.length}▾` : '';
    li.innerHTML=`<div class="nm">${guide}<span class="dot ${rollStatus(sub)}"></span> ${n.branch.split('/').pop()}</div>
      <div class="pr">${sub.clean}/${sub.total} blessed${kids}</div>${meter}`;
    li.onclick=()=>{active=n.id; render();};
    rail.appendChild(li);
  });
}

function render(){
  NODES = flatten();
  if(!active || !NODES.some(n=>n.id===active)) active = pickInitial();
  renderRail();
  const l = curObj();
  const main=$('#main'); main.innerHTML='';
  main.appendChild(el('div','hd', `<h2>${l.branch.split('/').pop()}</h2><span class="arrow">◂</span><span class="par">${l.parent}</span>`));

  const sub=el('div','sub2');
  [['all','all '+l.total],['stale','stale '+l.stale],['unblessed','new '+l.unblessed]].forEach(([k,lab])=>{
    const p=el('span','pill'+(filter===k?' on':''),lab); p.onclick=()=>{filter=k;render();}; sub.appendChild(p);});
  const ba=el('button','blessall','✦ bless all remaining'); ba.onclick=()=>doBless(l.branch,'.'); sub.appendChild(ba);
  main.appendChild(sub);

  let shown=0;
  (l.files||[]).forEach(f=>{
    if(filter==='stale' && f.status!=='stale') return;
    if(filter==='unblessed' && f.status!=='unblessed') return;
    shown++;
    const card=el('div','file '+f.status); card.style.animationDelay=(shown*28)+'ms';
    const sym=f.status==='clean'?'✓':f.status==='stale'?'△':'·';
    const tag=f.status==='stale'?'<span class="tag stale">changed since blessed</span>'
            :f.status==='clean'?'<span class="tag clean">blessed</span>'
            :'<span class="tag">unreviewed</span>';
    const row=el('div','frow',
      `<span class="chip ${f.status}">${sym}</span>
       <span class="fpath">${segPath(f.path)}</span>${tag}
       <button class="bless">${f.status==='stale'?'re-bless':'bless'}</button>
       <span class="caret">›</span>`);
    const body=el('div','body'); card.append(row,body);
    let drawn=false;
    const draw=()=>{ if(drawn)return; drawn=true;
      if(f.status==='stale' && f.stale){
        body.appendChild(el('p','since','✦ since you blessed'));
        const w=el('div','d2h-wrap'); body.appendChild(w);
        new Diff2HtmlUI(w,f.stale,{drawFileList:false,outputFormat:'line-by-line',matching:'lines'}).draw();
        body.appendChild(el('p','since','full change in this link'));
      }
      if(f.patch){ const w=el('div','d2h-wrap'); body.appendChild(w);
        new Diff2HtmlUI(w,f.patch,{drawFileList:false,outputFormat:'line-by-line',matching:'lines'}).draw();
      } else { body.appendChild(el('div','d2h-wrap','<p style="color:var(--faint);padding:12px">no textual diff</p>')); }
    };
    row.onclick=(e)=>{ if(e.target.closest('.bless'))return; card.classList.toggle('open'); if(card.classList.contains('open'))draw(); };
    row.querySelector('.bless').onclick=()=>doBless(l.branch,f.path);
    if(f.status!=='clean' && filter==='all'){ card.classList.add('open'); draw(); }
    main.appendChild(card);
  });
  if(shown===0) main.appendChild(el('div',null,'<p style="color:var(--faint);margin-top:30px">nothing '+filter+' here — all blessed ✦</p>'));
}

// keyboard: m → graph map, esc closes; ]/[ walk the tree, s → next stale/new node
addEventListener('keydown',e=>{
  if(e.key==='m'){ toggleMap(); e.preventDefault(); return; }
  if(e.key==='Escape'){ toggleMap(false); return; }
  const idx=NODES.findIndex(n=>n.id===active);
  if(e.key===']'){active=(NODES[Math.min(idx+1,NODES.length-1)]||{}).id;render();}
  else if(e.key==='['){active=(NODES[Math.max(idx-1,0)]||{}).id;render();}
  else if(e.key==='s'){const nx=NODES.find((n,i)=>i>idx&&n.stale+n.unblessed>0)||NODES.find(n=>n.stale+n.unblessed>0); if(nx){active=nx.id;filter=nx.stale?'stale':'unblessed';render();}}
  else return;
  e.preventDefault();
});

async function boot(){
  try{
    if(!MODEL) MODEL = await fetchModel();
    NODES=flatten(); active=pickInitial(); render();
    $('#mapbtn').onclick=()=>toggleMap();
    if(LIVE) setInterval(()=>fetch('/heartbeat',{method:'POST'}).catch(()=>{}), 5000);
  }catch(e){ document.body.innerHTML = '<p style="margin:40px;color:#cf6a3a">could not load model: '+e+'</p>'; }
}
boot();
</script>
</body>
</html>"""

out = HTML.replace("__MODEL__", model)
open(sys.argv[2], "w").write(out)
