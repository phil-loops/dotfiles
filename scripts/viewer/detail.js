// the left rail IS the dependency graph now — a vertical tree (main → roots →
// children) with connector lines, per-node status + PR badge + N/N count. The
// horizontal flowchart with edges/spotlight lives in the fullscreen map (m).
function renderRail(){
  $('#leaf').textContent = MODEL.project || MODEL.leaf || '';
  const tot=NODES.reduce((a,n)=>{a.c+=n.clean;a.s+=n.stale;a.u+=n.unblessed;a.t+=n.total;return a;},{c:0,s:0,u:0,t:0});
  $('#bar').style.width=(tot.t?Math.round(100*tot.c/tot.t):0)+'%';
  $('#tally').innerHTML=`<span><b>${tot.c}</b> blessed</span><span><b>${tot.s}</b> stale</span><span><b>${tot.u}</b> new</span>`;
  const rail=$('#rail'); rail.innerHTML='';
  const N = MODEL.nodes;
  const row=(b,n,connector)=>{
    const done = n.total>0 && n.clean===n.total && n.stale===0;
    const li=el('li','lk'+(b===active?' on':'')+(done?' done':''));
    li.dataset.b=b;
    const pr=(typeof GPRS!=='undefined') ? GPRS[b] : null;
    const ps=(pr && typeof prState==='function') ? prState(b) : null;
    const badge = ps ? `<span class="rdot ${ps.cls}" title="${ps.meta}">${ps.glyph}</span>` : '';
    li.innerHTML=`<span class="tw">${connector}</span><span class="dot ${n.status}"></span>`
      +`<span class="nm">${b.split('/').pop()}</span>${badge}<span class="cnt2">${n.clean}/${n.total}</span>`;
    li.onclick=()=>{ active=b; render(); };
    li.addEventListener('mouseenter',()=>{ if(typeof showTip==='function') showTip(b, li); railSpot(b); });
    li.addEventListener('mouseleave',()=>{ if(typeof hideTip==='function') hideTip(); railUnspot(); });
    rail.appendChild(li);
  };
  if(N){
    const trunk=el('li','lk trunk');
    trunk.innerHTML='<span class="tw"> </span><span class="dot clean"></span><span class="nm main">main</span>';
    rail.appendChild(trunk);
    const seen=new Set();
    const walk=(b,anc,isLast)=>{
      if(seen.has(b))return; seen.add(b);
      const n=N[b]; if(!n)return;
      row(b,n, anc.map(v=>v?'│ ':'  ').join('')+(isLast?'└ ':'├ '));
      const kids=(n.children||[]).filter(c=>N[c] && !seen.has(c));
      kids.forEach((c,i)=>walk(c, anc.concat(!isLast), i===kids.length-1));
    };
    const roots=(MODEL.roots||[]).filter(r=>N[r]);
    roots.forEach((r,i)=>walk(r, [], i===roots.length-1));
    Object.keys(N).forEach(b=>{ if(!seen.has(b)) walk(b, [], true); });   // any orphans
  } else {
    NODES.forEach(n=>row(n.id, n, ''));   // linear snapshot fallback
  }
}
// hover spotlight in the tree: light the hovered row + its upstream blockers, dim the rest
function railSpot(b){
  if(typeof upstreamOf!=='function')return;
  const up=new Set(upstreamOf(b).map(u=>u.branch)), lit=new Set([b,...up]);
  const rail=$('#rail'); if(!rail)return; rail.classList.add('spotting');
  rail.querySelectorAll('li.lk[data-b]').forEach(li=>{ const id=li.dataset.b;
    li.classList.toggle('lit', lit.has(id)); li.classList.toggle('up', up.has(id)); });
}
function railUnspot(){ const rail=$('#rail'); if(!rail)return; rail.classList.remove('spotting');
  rail.querySelectorAll('li.lit,li.up').forEach(li=>li.classList.remove('lit','up')); }

// diff base: view a node's diff vs an upstream ref (null = its parent). resets per node.
let diffBase=null, diffBaseFor=null;
function render(){
  NODES = flatten();
  if(!active || !NODES.some(n=>n.id===active)) active = pickInitial();
  renderRail();
  updateDockSel();   // highlight the selected node in the docked graph (no rebuild)
  const l = curObj();
  if(diffBaseFor!==l.id){ diffBase=null; diffBaseFor=l.id; }   // reset base when switching nodes
  if(LIVE) ensureNode(l.branch);   // priority: prefetch the node you just landed on
  const main=$('#main'); main.innerHTML='';
  main.appendChild(el('div','hd', `<h2>${l.branch.split('/').pop()}</h2><span class="arrow">◂</span><span class="par">${l.parent}</span>`));

  // "what's the point" — git branch description (free); generation is opt-in, never automatic
  if(LIVE){
    const pc=el('div','purpose'); main.appendChild(pc);
    const showThesis=(p,saved)=>{
      pc.innerHTML=`<span class="pdot">✦</span><span class="ptext">${p.thesis}${p.enables?` <span class="penables">→ groundwork for ${p.enables}</span>`:''}</span>`;
      if(p.source!=='description' && !saved){
        const save=el('button','psave','save to branch'); pc.appendChild(save);
        save.onclick=async()=>{ save.textContent='saving…';
          await fetch('/purpose',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch:l.branch,text:p.thesis})});
          PURPOSE[l.branch]={thesis:p.thesis,enables:p.enables,source:'description'}; showThesis(PURPOSE[l.branch],true); toast('✦ saved to branch description'); };
      }
    };
    const showEmpty=()=>{
      pc.innerHTML='<span class="pdot" style="opacity:.45">✦</span><span class="ptext" style="color:var(--faint)">no purpose set</span>';
      const sg=el('button','psuggest','suggest'); pc.appendChild(sg);
      sg.onclick=async()=>{ sg.textContent='thinking…';
        const g=await (await fetch('/purpose?generate=1&branch='+encodeURIComponent(l.branch))).json();
        PURPOSE[l.branch]=g; if(curObj().branch===l.branch) showThesis(g); };
    };
    const route=p=>{ (p && p.thesis) ? showThesis(p) : showEmpty(); };
    if(PURPOSE[l.branch]) route(PURPOSE[l.branch]);
    else fetch('/purpose?branch='+encodeURIComponent(l.branch)).then(r=>r.json())   // read-only: NO tokens
      .then(p=>{ PURPOSE[l.branch]=p; if(curObj().branch===l.branch) route(p); }).catch(showEmpty);
  }

  const sub=el('div','sub2');
  [['all','all '+l.total],['stale','stale '+l.stale],['unblessed','new '+l.unblessed]].forEach(([k,lab])=>{
    const p=el('span','pill'+(filter===k?' on':''),lab); p.onclick=()=>{filter=k;render();}; sub.appendChild(p);});
  if(LIVE){ const ba=el('button','blessall','✦ bless all remaining'); ba.onclick=()=>doBless(l.branch,'.'); sub.appendChild(ba); }
  else { sub.appendChild(el('span','ro-badge','snapshot · read-only')); }
  main.appendChild(sub);

  // diff base picker — view this node's diff vs an upstream ref OR vs the last blessed blob
  const blessedMode = diffBase==='blessed';
  const baseRef = (diffBase && diffBase!=='blessed' && diffBase!==l.parent) ? diffBase : null;
  const bp=el('div','basepick'); bp.appendChild(el('span','bplabel','diff vs'));
  [['','parent'],['main','main'],['blessed','last blessed']].forEach(([ref,lab])=>{
    const c=el('span','bp'+(((diffBase||'')===ref)?' on':''),lab);
    c.onclick=()=>{ diffBase=ref||null; render(); }; bp.appendChild(c); });
  main.appendChild(bp);

  const host=el('div'); main.appendChild(host);
  const renderCards=(files)=>{
  let shown=0;
  (files||[]).forEach(f=>{
    if(filter==='stale' && f.status!=='stale') return;
    if(filter==='unblessed' && f.status!=='unblessed') return;
    shown++;
    const card=el('div','file '+f.status); card.dataset.path=f.path; card.style.animationDelay=(shown*28)+'ms';
    const sym=f.status==='clean'?'✓':f.status==='stale'?'△':'·';
    const tag=f.status==='stale'?'<span class="tag stale">changed since blessed</span>'
            :f.status==='clean'?'<span class="tag clean">blessed</span>'
            :'<span class="tag">unreviewed</span>';
    const blessBtn = LIVE ? `<button class="bless">${f.status==='stale'?'re-bless':'bless'}</button>` : '';
    const row=el('div','frow',
      `<span class="chip ${f.status}">${sym}</span>
       <span class="fpath">${segPath(f.path)}</span>${tag}
       ${blessBtn}
       <span class="caret">›</span>`);
    const body=el('div','body'); card.append(row,body);
    let drawn=false;
    const draw=async()=>{ if(drawn)return; drawn=true;
      body.innerHTML='';   // idempotent: a retry re-runs draw() cleanly
      // diffs load per node on demand; the link diff isn't on the critical path
      const w=el('div','d2h-wrap','<p style="color:var(--faint);padding:11px">loading diff…</p>'); body.appendChild(w);
      let pd;
      try { pd=(await ensureNode(l.branch, baseRef))[f.path] || {}; }
      catch(e){   // fetch failed (server restart / port change) — offer a retry, don't latch
        drawn=false;
        w.innerHTML='<p style="padding:11px;color:#cf6a3a">couldn’t load diff (server restarting?) — <a href="#" class="retry" style="color:var(--gold)">retry</a></p>';
        w.querySelector('.retry').onclick=ev=>{ ev.preventDefault(); draw(); };
        return;
      }
      const d2h=(diff)=>{ new Diff2HtmlUI(w,diff,{drawFileList:false,outputFormat:'side-by-side',matching:'lines'}).draw();
        // hover the new-side line-number gutter → click to land the warm nvim on that exact line.
        // (gutter, not the code cell, so reading/selecting the diff text never fires an open.)
        const panels=w.querySelectorAll('.d2h-file-side-diff'); const right=panels[panels.length-1];
        if(right) right.querySelectorAll('tr').forEach(tr=>{
          const numCell=tr.querySelector('.d2h-code-side-linenumber'); if(!numCell) return;
          const n=parseInt((numCell.textContent||'').trim(),10); if(!n) return;   // blank gutter (deleted/gap) — skip
          numCell.classList.add('lineopen'); numCell.title='⌁ open line '+n+' in nvim';
          numCell.onclick=async(e)=>{ e.stopPropagation();
            const r=await fetch('/open',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch:l.branch,path:f.path,pos:String(n)})}).then(x=>x.json()).catch(()=>({ok:false}));
            toast(r.ok ? '⌁ '+f.path.split('/').pop()+':'+n+' → review-nvim' : '⌁ open failed: '+((r.err||'').trim()||'see server')); };
          // hover anywhere on the row → press `o` to open that line in nvim (same as clicking the gutter #)
          tr.title='press o to open line '+n+' in nvim';
          tr.onmouseenter=()=>{ _hoverLine={branch:l.branch,path:f.path,n}; tr.classList.add('linehover'); };
          tr.onmouseleave=()=>{ if(_hoverLine&&_hoverLine.n===n&&_hoverLine.path===f.path)_hoverLine=null; tr.classList.remove('linehover'); };
        });
      };
      w.innerHTML='';
      // smart default — the minimum you must re-read:
      //   stale → ONLY the diff since you last blessed; else → the full link diff
      if(blessedMode){
        if(pd.stale){ body.insertBefore(el('p','since','✦ since you blessed'), w); d2h(pd.stale); }
        else if(f.status==='clean'){ w.innerHTML='<p style="color:var(--faint);padding:11px">unchanged since you blessed ✓</p>'; }
        else { w.innerHTML='<p style="color:var(--faint);padding:11px">never blessed — nothing to compare</p>'; }
      } else if(f.status==='stale' && pd.stale){
        body.insertBefore(el('p','since','✦ since you blessed'), w);
        d2h(pd.stale);
      } else if(pd.patch){ d2h(pd.patch); }
      else { w.innerHTML='<p style="color:var(--faint);padding:11px">no textual diff</p>'; }
      // full-file toggle (live only — needs the server to read the blob)
      if(LIVE){
        const ff=el('button','fulltoggle','⤢ full file'); let box=null, loaded=false;
        ff.onclick=async()=>{
          if(loaded){ const vis=box.style.display!=='none'; box.style.display=vis?'none':'block'; ff.textContent=vis?'⤢ full file':'⤢ hide full file'; return; }
          ff.textContent='loading…';
          const r=await fetch('/file?branch='+encodeURIComponent(l.branch)+'&path='+encodeURIComponent(f.path));
          box=el('div','fullfile'); const pre=el('pre','ff-pre'); const code=document.createElement('code');
          code.textContent=await r.text(); pre.appendChild(code); box.appendChild(pre); body.appendChild(box);
          if(window.hljs) try{ hljs.highlightElement(code); }catch(e){}
          loaded=true; ff.textContent='⤢ hide full file';
        };
        body.appendChild(ff);
        const nv=el('button','fulltoggle nvim','⌁ open in nvim');
        nv.onclick=async()=>{ nv.textContent='opening…';
          const r=await fetch('/open',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch:l.branch,path:f.path})}).then(x=>x.json()).catch(()=>({ok:false}));
          nv.textContent='⌁ open in nvim';
          toast(r.ok ? '⌁ '+f.path.split('/').pop()+' → review-nvim (warm LSP)' : '⌁ open failed: '+((r.err||'').trim()||'see server')); };
        body.appendChild(nv);
      }
    };
    row.onclick=(e)=>{ if(e.target.closest('.bless'))return; card.classList.toggle('open'); if(card.classList.contains('open'))draw(); };
    const bb=row.querySelector('.bless'); if(bb) bb.onclick=()=>doBless(l.branch,f.path);
    if(f.status!=='clean' && filter==='all'){ card.classList.add('open'); draw(); }
    host.appendChild(card);
  });
  if(shown===0) host.appendChild(el('div',null,'<p style="color:var(--faint);margin-top:30px">nothing '+filter+' here — all blessed ✦</p>'));
  };
  // vs parent → file list from the model (sync); vs an upstream base → fetch the cumulative diff
  if(!baseRef){ renderCards(l.files||[]); }
  else {
    host.innerHTML='<p style="color:var(--faint);margin-top:18px">loading diff vs '+baseRef.split('/').pop()+'…</p>';
    fetchNode(l.branch, baseRef).then(d=>{ if(curObj().id!==l.id) return; host.innerHTML=''; renderCards(d.files||[]); });
  }
}

// the diff line under the mouse (set by the d2h hover handlers) — press `o` to open it
let _hoverLine = null;
// keyboard: o → open hovered diff line in nvim; m → graph map, esc closes; ]/[ walk the tree, s → next stale/new node
addEventListener('keydown',e=>{
  if(e.key==='o' && _hoverLine){ const ae=document.activeElement;
    if(ae && /^(INPUT|TEXTAREA)$/.test(ae.tagName)) return;   // don't fire while typing
    e.preventDefault(); const h=_hoverLine;
    fetch('/open',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch:h.branch,path:h.path,pos:String(h.n)})})
      .then(x=>x.json()).then(r=>toast(r.ok?'⌁ '+h.path.split('/').pop()+':'+h.n+' → review-nvim':'⌁ open failed')).catch(()=>{});
    return; }
  if(e.key==='m'){ toggleMap(); e.preventDefault(); return; }
  if(e.key==='f'){ document.body.classList.toggle('focus'); e.preventDefault(); return; }
  if(e.key==='Escape'){ if($('#map').classList.contains('on')) toggleMap(false); else document.body.classList.remove('focus'); return; }
  const idx=NODES.findIndex(n=>n.id===active);
  if(e.key===']'){active=(NODES[Math.min(idx+1,NODES.length-1)]||{}).id;render();}
  else if(e.key==='['){active=(NODES[Math.max(idx-1,0)]||{}).id;render();}
  else if(e.key==='s'){const nx=NODES.find((n,i)=>i>idx&&n.stale+n.unblessed>0)||NODES.find(n=>n.stale+n.unblessed>0); if(nx){active=nx.id;filter=nx.stale?'stale':'unblessed';render();}}
  else return;
  e.preventDefault();
});

// project picker — the landing screen. Lists configured projects as buttons
// (like the terminal fzf); clicking one opens ?branch=<project name>.
async function renderPicker(){
  let projs=[]; try{ projs=await (await fetch('/projects')).json(); }catch(e){}
  const ov=el('div'); ov.id='picker';
  ov.innerHTML=`<div class="pk-card"><h1>blessed</h1><p class="pk-sub">choose a project</p>`
    +`<div class="pk-list"></div><button class="pk-all">view the whole forest</button></div>`;
  document.body.appendChild(ov);
  const list=ov.querySelector('.pk-list');
  if(!projs.length){ list.innerHTML='<p style="color:var(--faint);font-size:12px">no projects configured (stack-project.*.branch)</p>'; }
  projs.forEach(p=>{ const b=el('button','pk-btn');
    b.innerHTML=`<span class="pk-name">${p.name}</span><span class="pk-meta">${p.branches} ${p.branches===1?'branch':'branches'}</span>`;
    b.onclick=()=>{ location.search='branch='+encodeURIComponent(p.name); };
    list.appendChild(b); });
  ov.querySelector('.pk-all').onclick=()=>{ location.search='branch=--all'; };
}
// preserve scroll across a live re-render. The render remounts every card and the
// open diffs re-fetch async, so a naive scrollY (or even card-top) anchor drops you
// at the top of the changed file. Instead anchor on the exact DIFF LINE nearest the
// top of the viewport — its new-side line number — and re-find that line after the
// redraw, so you stay where your cursor was. Falls back to the card top, then scrollY.
function rightRows(card){   // the new-side (right) diff rows of a side-by-side render
  const panels=card.querySelectorAll('.d2h-file-side-diff'); const right=panels[panels.length-1];
  return right ? right.querySelectorAll('tr') : [];
}
function lineNo(tr){ const c=tr.querySelector('.d2h-code-side-linenumber'); const n=c&&parseInt((c.textContent||'').trim(),10); return n||0; }
function captureScroll(){
  const card=[...document.querySelectorAll('.file')].find(c=>c.getBoundingClientRect().bottom>0);
  if(!card) return {path:null, y:window.scrollY};
  const path=card.dataset.path, cardTop=card.getBoundingClientRect().top;
  for(const tr of rightRows(card)){
    const n=lineNo(tr), r=tr.getBoundingClientRect();
    if(n && r.bottom>4) return {path, n, off:r.top, cardTop, y:window.scrollY};   // first real line at/below the top
  }
  return {path, n:null, cardTop, off:cardTop, y:window.scrollY};
}
function restoreScroll(a){
  if(!a) return;
  let tries=0;
  const apply=()=>{
    const card=a.path && document.querySelector('.file[data-path="'+CSS.escape(a.path)+'"]');
    let row=null;
    if(card && a.n) for(const tr of rightRows(card)){ if(lineNo(tr)===a.n){ row=tr; break; } }
    if(row)       window.scrollBy(0, row.getBoundingClientRect().top  - a.off);
    else if(card) window.scrollBy(0, card.getBoundingClientRect().top - a.cardTop);
    else          window.scrollTo(0, a.y);
    // the diff redraws async after remount — keep retrying until the anchored line lands
    if(++tries<8 && a.n && !row) setTimeout(apply, 80);
  };
  requestAnimationFrame(apply);
}
async function boot(){
  try{
    if(LIVE && !Q.get('branch')){ renderPicker(); return; }   // no project chosen → show the picker
    if(!MODEL) MODEL = await fetchModel();
    NODES=flatten(); active=pickInitial(); render(); buildDock();
    $('#mapbtn').onclick=()=>toggleMap();
    $('#focusbtn').onclick=()=>document.body.classList.toggle('focus');
    if(LIVE){
      setInterval(()=>fetch('/heartbeat',{method:'POST'}).catch(()=>{}), 5000);
      // live: poll a cheap signature; when refs/config/ledger change (re-root,
      // rebase, bless) re-fetch and re-render so the forest updates in place.
      let lastSig=null;
      setInterval(async()=>{
        try{
          const {sig}=await (await fetch('/sig')).json();
          if(lastSig===null){ lastSig=sig; return; }
          if(sig===lastSig) return;
          lastSig=sig;
          const anchor=captureScroll();
          MODEL=await fetchModel();
          for(const k in NODEPATCH) delete NODEPATCH[k];   // diffs may have moved
          render(); buildDock();
          if($('#map').classList.contains('on')) renderGraph('#map');
          restoreScroll(anchor);
          toast('↻ forest updated');
        }catch(e){}
      }, 3000);
    }
  }catch(e){ document.body.innerHTML = '<p style="margin:40px;color:#cf6a3a">could not load model: '+e+'</p>'; }
}
boot();
