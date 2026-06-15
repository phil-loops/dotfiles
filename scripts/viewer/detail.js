function renderRail(){
  $('#leaf').textContent = MODEL.project || MODEL.leaf || '';
  const tot=NODES.reduce((a,n)=>{a.c+=n.clean;a.s+=n.stale;a.u+=n.unblessed;a.t+=n.total;return a;},{c:0,s:0,u:0,t:0});
  $('#bar').style.width=(tot.t?Math.round(100*tot.c/tot.t):0)+'%';
  $('#tally').innerHTML=`<span><b>${tot.c}</b> blessed</span><span><b>${tot.s}</b> stale</span><span><b>${tot.u}</b> new</span>`;
  const rail=$('#rail'); rail.innerHTML='';
  // flat, honest list — structure lives in the docked graph, not fake indentation
  NODES.forEach(n=>{
    const li=el('li','lk'+(n.id===active?' on':''));
    li.innerHTML=`<div class="nm"><span class="dot ${n.status}"></span> ${n.branch.split('/').pop()}</div>
      <div class="pr">${n.clean}/${n.total} blessed</div>`;
    li.onclick=()=>{active=n.id; render();};
    rail.appendChild(li);
  });
}

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

  // diff base picker — view this node's diff against an upstream ref (default = parent)
  const baseRef = (diffBase && diffBase!==l.parent) ? diffBase : null;
  const bp=el('div','basepick'); bp.appendChild(el('span','bplabel','diff vs'));
  [['','parent'],['main','main']].forEach(([ref,lab])=>{
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
    const card=el('div','file '+f.status); card.style.animationDelay=(shown*28)+'ms';
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
      const d2h=(diff)=>{ new Diff2HtmlUI(w,diff,{drawFileList:false,outputFormat:'side-by-side',matching:'lines'}).draw(); };
      w.innerHTML='';
      // smart default — the minimum you must re-read:
      //   stale → ONLY the diff since you last blessed; else → the full link diff
      if(f.status==='stale' && pd.stale){
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

// keyboard: m → graph map, esc closes; ]/[ walk the tree, s → next stale/new node
addEventListener('keydown',e=>{
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

async function boot(){
  try{
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
          MODEL=await fetchModel();
          for(const k in NODEPATCH) delete NODEPATCH[k];   // diffs may have moved
          render(); buildDock();
          if($('#map').classList.contains('on')) renderGraph('#map');
          toast('↻ forest updated');
        }catch(e){}
      }, 3000);
    }
  }catch(e){ document.body.innerHTML = '<p style="margin:40px;color:#cf6a3a">could not load model: '+e+'</p>'; }
}
boot();
