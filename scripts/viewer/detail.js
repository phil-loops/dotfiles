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

// ── view state ↔ URL hash ──────────────────────────────────────────────────
// keep the selected node, file filter, diff base, and graph-open flag in the
// location hash so a plain refresh restores the exact view you were looking at.
// (the project stays in ?branch=, which intentionally reloads; the hash updates
// silently via replaceState so it never spams browser history.)
function readView(){ const h=new URLSearchParams(location.hash.slice(1));
  return { node:h.get('node')||'', filter:h.get('filter')||'', base:h.get('base')||'', map:h.get('map')==='1' }; }
function writeView(){
  const p=new URLSearchParams();
  if(typeof active==='string' && active) p.set('node', active);
  if(filter && filter!=='all') p.set('filter', filter);
  if(diffBase) p.set('base', diffBase);
  const m=$('#map'); if(m && m.classList.contains('on')) p.set('map','1');
  const h=p.toString();
  history.replaceState(null, '', location.pathname + location.search + (h?'#'+h:''));
}
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
      // per-card toggle for a stale file: "since blessed" (default — the minimum you
      // must re-read) ↔ "vs parent" (the whole file diff, how GitHub shows it). Both
      // diffs come in one fetch, so flipping is instant. Used by the last-blessed view
      // AND the parent/main view — anywhere a stale file has a since-blessed delta.
      const staleToggle=()=>{
        let view='stale';
        const seg=el('div','sincetoggle');
        const pick=()=>{
          seg.innerHTML='';
          [['stale','✦ since blessed'],['parent','vs parent']].forEach(([k,lab])=>{
            const o=el('span','segopt'+(view===k?' on':''),lab);
            o.onclick=()=>{ if(view!==k){ view=k; pick(); } };
            seg.appendChild(o);
          });
          w.innerHTML='';
          d2h(view==='stale' ? pd.stale : (pd.patch||pd.stale));
        };
        body.insertBefore(seg, w);
        pick();
      };
      // smart default — the minimum you must re-read:
      //   stale → ONLY the diff since you last blessed; else → the full link diff
      if(blessedMode){
        if(pd.stale){ staleToggle(); }
        else if(f.status==='clean'){ w.innerHTML='<p style="color:var(--faint);padding:11px">unchanged since you blessed ✓</p>'; }
        else { w.innerHTML='<p style="color:var(--faint);padding:11px">never blessed — nothing to compare</p>'; }
      } else if(f.status==='stale' && pd.stale){
        staleToggle();
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
  writeView();   // mirror the current view (node/filter/base) into the URL hash
}

// the diff line under the mouse (set by the d2h hover handlers) — press `o` to open it
let _hoverLine = null;
// keyboard: o → open hovered diff line in nvim; m → graph map, esc closes; ]/[ walk the tree, s → next stale/new node
addEventListener('keydown',e=>{
  if(e.metaKey||e.ctrlKey||e.altKey) return;   // let ⌘F / ⌘O / etc. reach the browser — these are bare-key shortcuts
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
  const stale=document.getElementById('picker'); if(stale) stale.remove();   // idempotent: re-invokable to refresh in place
  let projs=[]; try{ projs=await (await fetch('/projects')).json(); }catch(e){}
  const ov=el('div'); ov.id='picker';
  ov.innerHTML=`<div class="pk-card"><h1>blessed</h1><p class="pk-sub">choose a project</p>`
    +`<div class="pk-list"></div><button class="pk-all">view the whole forest</button>`
    +`<div class="pk-standalone"></div></div>`;
  document.body.appendChild(ov);
  const list=ov.querySelector('.pk-list');
  if(!projs.length){ list.innerHTML='<p style="color:var(--faint);font-size:12px">no projects configured (stack-project.*.branch)</p>'; }
  const esc=s=>(s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
  const leaf=s=>esc(String(s).split('/').pop());
  const PK=renderPicker._p||(renderPicker._p={});   // branch → thesis cache, survives re-render
  // The picker is a static landing screen (no SSE here), so a handed-off restack
  // would otherwise leave the badge stuck on "⤳ restacking…" forever. stack-restack
  // parks on conflicts it can't auto-resolve (state at <git-dir>/stack-restack-state);
  // flip the badge to a "needs resolve" prompt so the escalation is visible.
  const markPaused=(fb, project, br, label, withToast, reason)=>{
    const PAUSED='⚠ resolve '+leaf(br);
    fb.classList.remove('armed'); fb.classList.add('paused'); fb.dataset.paused='1';
    fb.textContent=PAUSED;
    // lead the tooltip with the actual DECISION (the escalation reason from restack.log),
    // so a preference-conflict reads as "limitedCount or countSentPreviews?" not just "resolve".
    fb.title=(reason?'NEEDS YOU: '+reason+'\n\n':'')
      +'restack paused on a conflict in '+br+' — click to hand it to Claude (resolves with judgment, then resumes the cascade). Manual: `loops stack restack '+project+' --continue`. See restack.log.';
    // two-click arm: first click asks, second (within 3s) hands the conflict to Claude.
    fb.onclick=async e=>{ e.stopPropagation();
      if(fb.dataset.armed!=='1'){ fb.dataset.armed='1'; fb.classList.add('armed'); fb.textContent='⤳ hand '+leaf(br)+' to Claude?';
        fb._dt=setTimeout(()=>{ fb.dataset.armed=''; fb.classList.remove('armed'); fb.textContent=PAUSED; },3000); return; }
      clearTimeout(fb._dt); fb.dataset.armed=''; fb.dataset.paused=''; fb.classList.remove('armed','paused'); fb.textContent='⤳ Claude resolving…';
      try{ const r=await (await fetch('/restack-resolve',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({project})})).json();
        if(r.ok){ toast('⤳ handed conflict in <b>'+esc(leaf(br))+'</b> to Claude — resolving + resuming the cascade. Tailing restack.log.'); watchRestack(fb, project, label); }
        else { toast('⤳ handoff failed: '+esc(r.err||'?')); markPaused(fb, project, br, label, false, reason); }
      }catch(err){ toast('⤳ handoff failed — server unreachable'); markPaused(fb, project, br, label, false, reason); }
    };
    if(withToast) toast('⚠ restack of <b>'+esc(project)+'</b> hit a conflict on <b>'+esc(leaf(br))+'</b>'
      +(reason?' — <i>'+esc(reason)+'</i>':'')+' · click the badge to hand it to Claude. See restack.log.');
  };
  // one-shot: a restack may already be parked when the picker renders (e.g. a reload
  // mid-conflict) — reflect that without waiting for a click.
  const checkPaused=async(fb, project, label)=>{
    let s=null; try{ s=await (await fetch('/restack-status?project='+encodeURIComponent(project))).json(); }catch(e){}
    if(s && s.paused) markPaused(fb, project, s.current||project, label, false, s.reason);
  };
  // after a handoff: poll until it finishes (clear in place) or parks (flag it).
  // NOTE: while a handoff is actively resolving, the state file still exists
  // (paused) AND the process is alive (running) — so check `running` FIRST, else
  // we'd re-flag "needs resolve" mid-resolution. running=false + paused=true is
  // the real "parked, needs a human" state.
  const watchRestack=(fb, project, label)=>{
    let tries=0, sawRunning=false;
    const tick=async()=>{
      tries++;
      let s=null; try{ s=await (await fetch('/restack-status?project='+encodeURIComponent(project))).json(); }catch(e){}
      if(s && s.running){ sawRunning=true; if(tries<150) setTimeout(tick,2000); return; }   // still working (cap ~5min)
      if(s && s.paused){
        if(!sawRunning && tries<3){ setTimeout(tick,1500); return; }   // grace: the job may still be spawning
        markPaused(fb, project, s.current||project, label, true, s.reason); return;   // parked → needs a human
      }
      renderPicker();   // not running, not paused → finished/stopped: rebuild so freshness re-reads
    };
    setTimeout(tick, 1500);
  };
  projs.forEach(p=>{ const b=el('button','pk-btn');
    const ready=p.ready||[], cands=p.candidates||[];
    // hover shows the branch purpose via a styled tooltip (below); click opens the node.
    const chips=arr=>arr.map(r=>`<span class="pk-ready-b" data-b="${esc(r)}" data-p="${esc(p.name)}">${leaf(r)}</span>`).join('');
    // ready = no upstream blockers AND an open PR (the graph's legal-to-merge set).
    const readyRow = ready.length
      ? `<div class="pk-ready"><span class="pk-ready-h">✓ ready to merge</span>${chips(ready)}</div>` : '';
    // candidates = no upstream blockers but NO PR yet — local branches you could open
    // a PR for / merge straight into main.
    const candRow = cands.length
      ? `<div class="pk-ready pk-cand"><span class="pk-ready-h">○ candidate · no PR</span>${chips(cands)}</div>` : '';
    // freshness vs origin/main: ⟳ N behind → the forest trails main, restack to
    // refresh & condense; ✓ fresh → up to date. (server omits behind on old builds.)
    const beh = (typeof p.behind==='number') ? p.behind : null;
    const ov = !!p.overlap;   // does origin/main's drift touch files this forest changed?
    const behindTitle = ov
      ? `origin/main is ${beh} commit${beh===1?'':'s'} ahead and changes files this forest also touches — restack to refresh the diffs and head off conflicts. Click to restack ${esc(p.name)} onto fresh main (background → restack.log).`
      : `origin/main is ${beh} commit${beh===1?'':'s'} ahead but changes no file this forest touches — a restack here is a clean replay (cosmetic: SHA churn + re-bless). Click to restack anyway.`;
    const fresh = beh===null ? ''
      : beh>0 ? `<span class="pk-fresh behind${ov?'':' cosmetic'}" title="${behindTitle}">⟳ ${beh} behind${ov?'':' · cosmetic'}</span>`
              : `<span class="pk-fresh ok" title="up to date with origin/main">✓ fresh</span>`;
    b.innerHTML=`<div class="pk-top"><span class="pk-name">${esc(p.name)}</span>`
      +`<span class="pk-rt">${fresh}<span class="pk-meta">${p.branches} ${p.branches===1?'branch':'branches'}</span></span></div>`
      +readyRow+candRow;
    b.onclick=()=>{ location.search='branch='+encodeURIComponent(p.name); };
    list.appendChild(b);
    // behind badge → restack. Two-click arm (the card itself is clickable and the op
    // is destructive): first click asks, second within 3s hands off to /restack
    // (background `stack-restack <project>`, logs to restack.log).
    const fb = b.querySelector('.pk-fresh.behind');
    if(fb){ const label='⟳ '+beh+' behind';
      checkPaused(fb, p.name, label);   // a restack may already be parked on a conflict — surface it on render
      fb.onclick=async e=>{ e.stopPropagation();
        if(fb.dataset.paused==='1') return;   // already parked → onclick was reset by markPaused; guard the arm path
        if(fb.dataset.armed!=='1'){ fb.dataset.armed='1'; fb.classList.add('armed'); fb.textContent='↻ restack '+leaf(p.name)+'?';
          fb._dt=setTimeout(()=>{ fb.dataset.armed=''; fb.classList.remove('armed'); fb.textContent=label; },3000); return; }
        clearTimeout(fb._dt); fb.dataset.armed=''; fb.classList.remove('armed'); fb.textContent='handing off…';
        try{ const r=await (await fetch('/restack',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({project:p.name})})).json();
          if(r.ok){ toast('⤳ restacking <b>'+esc(p.name)+'</b> onto origin/main — tailing restack.log'); fb.textContent='⤳ restacking…'; watchRestack(fb, p.name, label); }
          else { toast('⤳ restack not started: '+esc(r.err||'?')); fb.textContent=label; }
        }catch(err){ toast('⤳ restack failed — server unreachable'); fb.textContent=label; }
      };
    } });
  // merge-candidate chips: hover → styled tooltip with the branch purpose; click → open its
  // node. purpose is read-only /purpose (no token spend), cached in PK across re-renders.
  const pkTipEl=()=>{ let t=document.getElementById('pktip'); if(!t){ t=el('div','pk-tip'); t.id='pktip'; document.body.appendChild(t); } return t; };
  const showPkTip=(chip,br)=>{ const t=pkTipEl();
    const why = PK[br] ? `<span class="pk-tip-why"><span class="x">✦</span>${esc(PK[br])}</span>`
                       : `<span class="pk-tip-why empty">no purpose set</span>`;
    t.innerHTML=`<span class="pk-tip-b">${esc(br)}</span>`+why; t.classList.add('on');
    const r=chip.getBoundingClientRect();
    t.style.left=Math.max(8, Math.min(r.left, innerWidth-t.offsetWidth-8))+'px';
    const above=r.top-t.offsetHeight-8; t.style.top=(above>8 ? above : r.bottom+8)+'px'; };
  const hidePkTip=()=>{ const t=document.getElementById('pktip'); if(t) t.classList.remove('on'); };
  list.querySelectorAll('.pk-ready-b[data-b]').forEach(chip=>{
    const br=chip.getAttribute('data-b');
    chip.onclick=e=>{ e.stopPropagation();   // open the branch's node; don't also fire the project nav
      location.href='?branch='+encodeURIComponent(chip.getAttribute('data-p'))+'#node='+encodeURIComponent(br); };
    const ensure=()=> (br in PK) ? Promise.resolve()
      : fetch('/purpose?branch='+encodeURIComponent(br)).then(r=>r.json())
          .then(p=>{ PK[br]=(p&&p.thesis)||''; }).catch(()=>{ PK[br]=''; });
    chip.addEventListener('mouseenter',()=>{ ensure().then(()=>{ if(chip.matches(':hover')) showPkTip(chip,br); }); });
    chip.addEventListener('mouseleave',hidePkTip);
  });
  ov.querySelector('.pk-all').onclick=()=>{ location.search='branch=--all'; };
  // standalone: an OPT-IN watch list, not auto-discovery (a real repo has ~1.5k
  // loose heads). The section is always present so "+ add" is reachable; pins
  // persist in git config (stack.standalone). Each row opens that branch as its
  // own one-root view (?branch=X → stack-forest expand([X])), reusing the whole
  // detail + toolbar with no downstream special-casing.
  const sa=ov.querySelector('.pk-standalone');
  async function refreshStandalone(){
    let loose=[]; try{ loose=await (await fetch('/standalone')).json(); }catch(e){}
    sa.innerHTML=`<div class="pk-sa-h">standalone branches`
      +`<span class="pk-sa-sub">${loose.length?loose.length+' pinned':'opt-in watch list'}</span>`
      +`<button class="pk-sa-add" title="pin a branch to watch here">+ add</button></div>`
      +`<div class="pk-sa-list"></div><div class="pk-sa-form"></div>`;
    const wrap=sa.querySelector('.pk-sa-list');
    if(!loose.length){ wrap.innerHTML='<p class="pk-sa-empty">nothing pinned — add a loose branch to open it from here</p>'; }
    loose.forEach(b=>{ const row=el('div','pk-sa-b');
      row.innerHTML=`<span class="pk-sa-d">◇</span>`
        +`<span class="pk-sa-path">${esc(b.branch)}</span>`
        +`<span class="pk-sa-stat"><span class="add">+${b.add}</span><span class="del">−${b.del}</span></span>`
        +`<button class="pk-sa-x" title="unpin">×</button>`;
      row.title=`${b.branch} · ${b.commits} commit${b.commits!==1?'s':''} ahead of main`;
      row.onclick=()=>{ location.search='branch='+encodeURIComponent(b.branch); };
      row.querySelector('.pk-sa-x').onclick=async e=>{ e.stopPropagation();
        await fetch('/standalone',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch:b.branch,op:'remove'})}).catch(()=>{});
        refreshStandalone(); };
      wrap.appendChild(row); });
    sa.querySelector('.pk-sa-add').onclick=()=>showAddForm(sa.querySelector('.pk-sa-form'));
  }
  // "+ add": a typeahead over local heads (most-recent first) backed by a datalist.
  async function showAddForm(host){
    if(host.dataset.open){ host.dataset.open=''; host.innerHTML=''; return; }
    host.dataset.open='1';
    let names=[]; try{ names=await (await fetch('/branches')).json(); }catch(e){}
    host.innerHTML=`<input class="pk-sa-in" list="pk-sa-dl" autocomplete="off" spellcheck="false"`
      +` placeholder="branch name… (${names.length} local, recent first)">`
      +`<datalist id="pk-sa-dl">${names.map(n=>`<option value="${esc(n)}"></option>`).join('')}</datalist>`;
    const inp=host.querySelector('.pk-sa-in'); inp.focus();
    const submit=async()=>{ const v=inp.value.trim(); if(!v) return;
      const r=await fetch('/standalone',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({branch:v,op:'add'})}).then(x=>x.json()).catch(()=>({ok:false,err:'server unreachable'}));
      if(!r.ok){ inp.classList.add('err'); inp.title=r.err||'could not add'; return; }
      host.dataset.open=''; host.innerHTML=''; refreshStandalone(); };
    inp.addEventListener('keydown',e=>{ inp.classList.remove('err');
      if(e.key==='Enter'){ e.preventDefault(); submit(); }
      else if(e.key==='Escape'){ host.dataset.open=''; host.innerHTML=''; } });
  }
  refreshStandalone();
}
// preserve scroll across a live re-render. NB the scroller is `.main` (the body is
// height:100vh/overflow:hidden) — driving window.scroll* is a no-op, which is why a
// refresh always snapped to the file top. We anchor on the exact DIFF LINE nearest
// the top of the viewport (its new-side line number) and re-find that line after the
// redraw, scrolling `.main` so it lands at the same offset — so you stay where your
// cursor was. The render remounts cards and the open diffs re-fetch async, so we
// re-apply on a schedule (~1.4s) to absorb late layout shifts. Falls back to the card
// top, then absolute scrollTop.
// the scroll container is <main id="main"> (overflow:auto; body is overflow:hidden).
// MUST select by id — `.main` also matches the rail's <span class="nm main"> trunk
// label, which sits earlier in the DOM, so querySelector('.main') returned THAT span
// (scrollTop always 0) and every restore silently no-op'd to the top.
function scroller(){ return document.getElementById('main'); }
function rightRows(card){   // the new-side (right) diff rows of a side-by-side render
  const panels=card.querySelectorAll('.d2h-file-side-diff'); const right=panels[panels.length-1];
  return right ? right.querySelectorAll('tr') : [];
}
function lineNo(tr){ const c=tr.querySelector('.d2h-code-side-linenumber'); const n=c&&parseInt((c.textContent||'').trim(),10); return n||0; }
function captureScroll(){
  const sc=scroller(); if(!sc) return null;
  const top=sc.getBoundingClientRect().top, st=sc.scrollTop;   // offsets measured relative to the scroller's top edge
  const card=[...sc.querySelectorAll('.file')].find(c=>c.getBoundingClientRect().bottom>top);
  if(!card) return {st};
  const path=card.dataset.path, cardOff=card.getBoundingClientRect().top - top;
  for(const tr of rightRows(card)){
    const n=lineNo(tr), r=tr.getBoundingClientRect();
    if(n && r.bottom>top+4) return {path, n, off:r.top-top, cardOff, st};   // first real line at/below the top edge
  }
  return {path, n:null, cardOff, st};
}
function restoreScroll(a){
  if(!a) return;
  const sc=scroller(); if(!sc) return;
  const start=document.timeline?document.timeline.currentTime:0;   // monotonic, no Date.now
  let stable=0, aborted=false;
  const bail=()=>{ aborted=true; };
  sc.addEventListener('wheel', bail, {once:true, passive:true});   // the moment you scroll, stop fighting you
  const tick=now=>{
    if(aborted) return;
    const top=sc.getBoundingClientRect().top;
    const card=a.path && sc.querySelector('.file[data-path="'+CSS.escape(a.path)+'"]');
    let row=null;
    if(card && a.n) for(const tr of rightRows(card)){ if(lineNo(tr)===a.n){ row=tr; break; } }
    const delta = row  ? (row.getBoundingClientRect().top  - top) - a.off
                : card ? (card.getBoundingClientRect().top - top) - a.cardOff
                : (a.st!=null ? a.st - sc.scrollTop : 0);
    if(Math.abs(delta)>1){ sc.scrollTop += delta; stable=0; } else stable++;
    // keep correcting every frame until the anchored line is found AND has held still
    // a few frames (the diff mounts async, cards above can still grow) — cap at ~2s.
    if((now-start)<2000 && (!row || stable<4)) requestAnimationFrame(tick);
    else sc.removeEventListener('wheel', bail);
  };
  requestAnimationFrame(tick);
}
// persist the anchor across a FULL page reload (manual refresh, or a future hot-reload)
// via sessionStorage, so reloading to pick up new viewer code doesn't bounce you to the
// top. pagehide fires on both reload and tab-close (more reliable than beforeunload).
const SCROLL_KEY='blessed:scroll';
function saveScroll(){
  try{ const a=captureScroll(); if(a) sessionStorage.setItem(SCROLL_KEY, JSON.stringify({branch:Q.get('branch'), active, a})); }catch(e){}
}
function loadScroll(){
  try{ const s=JSON.parse(sessionStorage.getItem(SCROLL_KEY)||'null');
    return (s && s.branch===Q.get('branch') && s.active===active) ? s.a : null; }catch(e){ return null; }
}
addEventListener('pagehide', saveScroll);
async function boot(){
  try{
    if(LIVE && !Q.get('branch')){ renderPicker(); return; }   // no project chosen → show the picker
    if(!MODEL) MODEL = await fetchModel();
    NODES=flatten();
    const V=readView();   // restore the view from the URL hash (refresh-safe)
    active=(V.node && NODES.some(n=>n.id===V.node)) ? V.node : pickInitial();
    if(V.filter) filter=V.filter;
    if(V.base){ diffBase=V.base; diffBaseFor=active; }   // keep the saved diff base for the restored node
    render(); buildDock();
    restoreScroll(loadScroll());   // refresh-safe: land back where you were, not at the top
    if(V.map) toggleMap(true);
    $('#mapbtn').onclick=()=>toggleMap();
    $('#focusbtn').onclick=()=>document.body.classList.toggle('focus');
    if(LIVE){
      // one server-pushed stream (SSE) replaces the old per-tab heartbeat + /sig + /?_hot
      // polls, so N open tabs cost N idle connections instead of a 3-timer fan-out + a
      // reload stampede when source changes. The server pushes two event kinds:
      //   `update` → the forest moved (re-root, rebase, bless): refetch + re-render in place.
      //   `reload` → the viewer source changed (code edit): reload the reassembled page, after
      //              a small random delay so many tabs don't all hit the render path at once.
      // EventSource auto-reconnects on drop (e.g. the server's self-reexec), so no manual retry.
      const es=new EventSource('/events');
      window.__events=es;   // shared so accessories (freshness chip) ride one stream, not their own
      es.addEventListener('update', async()=>{
        try{
          const anchor=captureScroll();
          MODEL=await fetchModel();
          for(const k in NODEPATCH) delete NODEPATCH[k];   // diffs may have moved
          render(); buildDock();
          if($('#map').classList.contains('on')) renderGraph('#map');
          restoreScroll(anchor);
          toast('↻ forest updated');
        }catch(e){}
      });
      es.addEventListener('reload', ()=>{ saveScroll(); setTimeout(()=>location.reload(), 150+Math.random()*1200); });
    }
  }catch(e){ document.body.innerHTML = '<p style="margin:40px;color:#cf6a3a">could not load model: '+e+'</p>'; }
}
boot();
