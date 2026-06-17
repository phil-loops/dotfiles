// the left rail lists the SELECTED node's edited files (path + bless status); click
// one to open + scroll to its diff card in the main panel. Branch navigation lives
// in the fullscreen map (m) and the ]/[ keys — the rail is per-node now, not the
// forest tree.
function renderRail(){
  const l = (typeof curObj==='function') ? curObj() : {branch:'',files:[]};
  $('#leaf').textContent = (l.branch||MODEL.project||MODEL.leaf||'').split('/').pop();
  const node = (MODEL.nodes && MODEL.nodes[l.branch]) || null;
  const c=node?node.clean:0, s=node?node.stale:0, u=node?node.unblessed:0,
        t=node?node.total:(l.files||[]).length;
  $('#bar').style.width=(t?Math.round(100*c/t):0)+'%';
  $('#tally').innerHTML=`<span><b>${c}</b> blessed</span><span><b>${s}</b> stale</span><span><b>${u}</b> new</span>`;
  const rail=$('#rail'); rail.innerHTML=''; rail.classList.add('files');
  const files=(l.files||[]).filter(f=>
    filter==='all' || (filter==='stale' ? f.status==='stale' : f.status==='unblessed'));
  if(!files.length){
    rail.appendChild(el('li','rail-empty', filter==='all' ? 'no files in this branch' : 'nothing '+filter+' here'));
    return;
  }
  files.forEach(f=>{
    const sym=f.status==='clean'?'✓':f.status==='stale'?'△':'·';
    const li=el('li','fk '+f.status); li.dataset.path=f.path;
    li.innerHTML=`<span class="dot ${f.status}"></span><span class="fnm">${segPath(f.path)}</span><span class="fsym">${sym}</span>`;
    li.title=f.path+' — '+(f.status==='clean'?'blessed':f.status==='stale'?'changed since blessed':'unreviewed');
    li.onclick=()=>{
      rail.querySelectorAll('li.fk.on').forEach(x=>x.classList.remove('on')); li.classList.add('on');
      const card=[...document.querySelectorAll('#main .file')].find(c=>c.dataset.path===f.path);
      if(card){
        if(!card.classList.contains('open')){ const fr=card.querySelector('.frow'); if(fr) fr.click(); }
        card.scrollIntoView({block:'nearest',behavior:'smooth'});
      }
    };
    rail.appendChild(li);
  });
}
// Tab / Shift+Tab walk the rail's file list: select the next/previous file, opening
// + scrolling to its diff card. Wraps around at the ends.
function stepRailFile(dir){
  const rows=[...document.querySelectorAll('#rail li.fk')];
  if(!rows.length) return;
  const cur=rows.findIndex(li=>li.classList.contains('on'));
  const next=(((cur<0 ? (dir>0?0:-1) : cur+dir)%rows.length)+rows.length)%rows.length;
  rows[next].click();
  rows[next].scrollIntoView({block:'nearest'});
}

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
// keyboard: o → open hovered diff line in nvim; m → graph map; ]/[ walk the tree;
// s → next stale/new node; Tab/⇧Tab → next/prev file. Nav model: projects → graph
// → node/files; esc pops one level back up (node→graph→projects).
addEventListener('keydown',e=>{
  if(e.metaKey||e.ctrlKey||e.altKey) return;   // let ⌘F / ⌘O / etc. reach the browser — these are bare-key shortcuts
  if(document.getElementById('picker')) return;   // on the project-listing overlay: no in-forest shortcuts
  if(e.key==='Tab'){ const ae=document.activeElement;
    if(ae && /^(INPUT|TEXTAREA)$/.test(ae.tagName)) return;   // let Tab move between fields while typing
    if($('#map').classList.contains('on')) return;   // graph view: Tab walks files only in the node view
    e.preventDefault(); stepRailFile(e.shiftKey?-1:1); return; }
  if(e.key==='o' && _hoverLine){ const ae=document.activeElement;
    if(ae && /^(INPUT|TEXTAREA)$/.test(ae.tagName)) return;   // don't fire while typing
    e.preventDefault(); const h=_hoverLine;
    fetch('/open',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch:h.branch,path:h.path,pos:String(h.n)})})
      .then(x=>x.json()).then(r=>toast(r.ok?'⌁ '+h.path.split('/').pop()+':'+h.n+' → review-nvim':'⌁ open failed')).catch(()=>{});
    return; }
  if(e.key==='m'){ toggleMap(); e.preventDefault(); return; }
  if(e.key==='f'){ document.body.classList.toggle('focus'); e.preventDefault(); return; }
  if(e.key==='Escape'){
    if(document.body.classList.contains('focus')){ document.body.classList.remove('focus'); return; }
    if($('#map').classList.contains('on')){ location.assign('/'); return; }   // graph → project listings
    toggleMap(true); return;                                                  // node/files → graph
  }
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
  let projs=[],myprs=[],opened={};
  [projs,myprs,opened]=await Promise.all([
    fetch('/projects').then(r=>r.json()).catch(()=>[]),
    fetch('/myprs').then(r=>r.json()).catch(()=>[]),
    fetch('/project-opened').then(r=>r.json()).catch(()=>({})),
  ]);
  if(!Array.isArray(projs)) projs=[];
  if(!Array.isArray(myprs)) myprs=[];
  if(!opened||typeof opened!=='object') opened={};
  const behindAll=projs.filter(p=>typeof p.behind==='number'&&p.behind>0).map(p=>p.name);
  const allBtn=behindAll.length
    ? `<button class="pk-restack-all" title="restack all ${behindAll.length} behind forests onto fresh main, one after another (background, scratch worktree). Stops at the first real conflict for you to resolve, then re-run to finish.">⟳ restack all ${behindAll.length} behind</button>`
    : '';
  const ov=el('div'); ov.id='picker';
  ov.innerHTML=`<div class="pk-card"><h1>blessed</h1><button class="pk-checkorigin" title="fetch origin/main + refresh open PRs and behind-counts — see what merged and what now needs a restack">↻ check origin</button><div class="pk-myprs"></div><p class="pk-sub">choose a project</p>`
    +allBtn
    +`<div class="pk-list"></div><button class="pk-all">view the whole forest</button>`
    +`<div class="pk-standalone"></div></div>`;
  document.body.appendChild(ov);
  const list=ov.querySelector('.pk-list');
  if(!projs.length){ list.innerHTML='<p style="color:var(--faint);font-size:12px">no projects configured (stack-project.*.branch)</p>'; }
  const esc=s=>(s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
  const leaf=s=>esc(String(s).split('/').pop());
  // Projects that already have an open PR — their card is moved up beneath their PR
  // row (below), so they aren't also listed again under "choose a project".
  const prdProjects=new Set(myprs.map(p=>p.project).filter(Boolean));
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
  // restack-all: poll the GLOBAL restack status (no project) until the back-to-back
  // sequence finishes or parks, then rebuild — the parked project's card shows ⚠ resolve,
  // the finished ones go ✓ fresh / contract.
  const watchRestackAll=()=>{ let tries=0;
    const tick=async()=>{ tries++;
      let s=null; try{ s=await (await fetch('/restack-status')).json(); }catch(e){}
      if(s && s.running){ if(tries<400) setTimeout(tick,2500); return; }   // still churning through the chain
      if(s && s.paused){   // the chain HALTED on a conflict — make it loud + actionable (one tiny card badge is easy to miss)
        const pj=s.project||'a forest', br=leaf(s.current||pj);
        toast('\u26a0 restack-all halted on <b>'+esc(pj)+'</b>'+(s.reason?' \u2014 <i>'+esc(s.reason)+'</i>':'')
          +'<br>open its card and click <b>\u26a0 resolve '+esc(br)+'</b> to hand it to Claude, or run '
          +'<code>loops stack restack '+esc(pj)+' --continue</code>  \u00b7  click to dismiss', true);
      }
      renderPicker();
    };
    setTimeout(tick,1500);
  };
  // build a project card (freshness badge + ready/candidate chips + two-click restack).
  // Returns the wired button; the caller places it (under its PR row, or in the list).
  const makeCard=p=>{ const b=el('button','pk-btn');
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
              : `<span class="pk-fresh ok" title="up to date with origin/main — click to restack anyway (refetch + verify, no-op if nothing moved)">✓ fresh</span>`;
    b.innerHTML=`<div class="pk-top"><span class="pk-name">${esc(p.name)}</span>`
      +`<span class="pk-rt">${fresh}<span class="pk-meta">${p.branches} ${p.branches===1?'branch':'branches'}</span></span></div>`
      +readyRow+candRow;
    b.onclick=()=>{ location.search='branch='+encodeURIComponent(p.name); };
    // freshness chip = the restack button, on EVERY card (behind or fresh). Two-click
    // arm (the card itself is clickable and the op is destructive): first click asks,
    // second within 3s fires /restack (background `stack-restack <project>`, logs to
    // restack.log). On a fresh card a restack is a harmless no-op (refetch + verify).
    const fb = b.querySelector('.pk-fresh');
    if(fb && beh!==null){ const label = beh>0 ? ('⟳ '+beh+' behind'+(ov?'':' · cosmetic')) : '✓ fresh';
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
    }
    return b; };
  const projByName={}; projs.forEach(p=>{ projByName[p.name]=p; });
  // "your open PRs": rows grouped by project; each PR'd project's card is moved in
  // beneath its rows (keeping the freshness/restack badge) rather than listed below.
  const myhost=ov.querySelector('.pk-myprs');
  if(myhost){
    if(!myprs.length){ myhost.remove(); }
    else {
      const rv=r=> r==='APPROVED'?'<span class="prr-rv ok" title="approved">✓</span>'
                : r==='CHANGES_REQUESTED'?'<span class="prr-rv chg" title="changes requested">⚠</span>'
                : r==='REVIEW_REQUIRED'?'<span class="prr-rv req" title="review required">•</span>':'';
      const NP='__noproj__', byProj={}, order=[];
      myprs.forEach(p=>{ const k=p.project||NP; if(!(k in byProj)){ byProj[k]=[]; order.push(k); } byProj[k].push(p); });
      myhost.innerHTML='<div class="pk-myprs-h">your open PRs</div>';
      order.forEach(k=>{
        const lbl = k===NP ? '<span class="pk-myprs-noproj">no local project</span>' : esc(k);
        const g=el('div','pk-myprs-g');
        let html=`<div class="pk-myprs-proj">${lbl}</div>`;
        byProj[k].forEach(p=>{
          html+=`<button class="pk-prrow" data-proj="${esc(p.project||'')}" data-br="${esc(p.branch||'')}" data-url="${esc(p.url||'')}">`
            +`<span class="prr-num">#${esc(String(p.num))}</span>`
            +`<span class="prr-title">${esc(p.title||'')}</span>`
            +`${p.draft?'<span class="prr-draft">draft</span>':''}${rv(p.review)}</button>`;
        });
        g.innerHTML=html;
        if(k!==NP && projByName[k]) g.appendChild(makeCard(projByName[k]));   // card moves up under its PR rows
        myhost.appendChild(g);
      });
      myhost.querySelectorAll('.pk-prrow').forEach(row=>{
        row.onclick=()=>{ const pr=row.dataset.proj, br=row.dataset.br;
          if(pr) location.href='?branch='+encodeURIComponent(pr)+'#node='+encodeURIComponent(br);
          else if(row.dataset.url) window.open(row.dataset.url,'_blank');
        };
      });
    }
  }
  // "choose a project": only projects WITHOUT an open PR, most-recently-opened (hover+o) first.
  const noPr=projs.filter(p=>!prdProjects.has(p.name))
    .sort((a,b)=>(opened[b.name]||0)-(opened[a.name]||0));
  noPr.forEach(p=>{ list.appendChild(makeCard(p)); });
  if(!noPr.length){ const sub=ov.querySelector('.pk-sub'); if(sub) sub.remove(); }   // no unattached projects → drop the header
  // header "restack all behind" → restack every trailing forest back-to-back. Two-click
  // arm (destructive, many forests). One background job; halts at the first conflict.
  // "check origin" — fetch origin/main + force-refresh the PR/behind caches, then
  // rebuild the homepage: merged PRs drop off, review states + "N behind" go current.
  const coBtn=ov.querySelector('.pk-checkorigin');
  if(coBtn){ const o0=coBtn.textContent;
    coBtn.onclick=async()=>{ coBtn.disabled=true; coBtn.textContent='↻ checking origin…';
      try{ const r=await (await fetch('/check-origin',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).json();
        if(r.ok){ toast('↻ origin checked — '+(r.moved>0?('main +'+r.moved+' commit'+(r.moved===1?'':'s')):'up to date')+' · PRs + behind-counts refreshed'); renderPicker(); }
        else { toast('↻ check failed: '+esc(r.err||'?')); coBtn.disabled=false; coBtn.textContent=o0; }
      }catch(e){ toast('↻ check origin failed — server unreachable'); coBtn.disabled=false; coBtn.textContent=o0; }
    };
  }
  const allEl=ov.querySelector('.pk-restack-all');
  if(allEl){ const orig=allEl.textContent;
    allEl.onclick=async e=>{ e.stopPropagation();
      if(allEl.dataset.armed!=='1'){ allEl.dataset.armed='1'; allEl.classList.add('armed'); allEl.textContent='↻ restack all '+behindAll.length+'?';
        allEl._dt=setTimeout(()=>{ allEl.dataset.armed=''; allEl.classList.remove('armed'); allEl.textContent=orig; },3000); return; }
      clearTimeout(allEl._dt); allEl.dataset.armed=''; allEl.classList.remove('armed'); allEl.textContent='⤳ restacking all…';
      try{ const r=await (await fetch('/restack-all',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({projects:behindAll})})).json();
        if(r.ok){ toast('⤳ restacking <b>'+behindAll.length+'</b> forests onto fresh main, in sequence — tailing restack.log. Conflicts halt the run on that forest’s card.'); watchRestackAll(); }
        else { toast('⤳ restack-all not started: '+esc(r.err||'?')); allEl.textContent=orig; }
      }catch(err){ toast('⤳ restack-all failed — server unreachable'); allEl.textContent=orig; }
    };
  }
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
  ov.querySelectorAll('.pk-ready-b[data-b]').forEach(chip=>{
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
    // nav model: picking a project lands on the graph; a node is only shown when the
    // URL hash names one (a click, refresh, or bookmark). fresh project click → no
    // node in hash → open the map by default.
    if(V.map || !V.node) toggleMap(true);
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
      let _updateT;   // debounce: coalesce a restack's rapid per-branch moves into one re-render
      es.addEventListener('update', async()=>{
        // Our own bless already updated the UI optimistically; the server then re-broadcasts
        // the ledger write as an 'update'. Reconcile counts silently (refetch + rail repaint,
        // NO #main remount, no toast) so the page doesn't flash/scroll-jump on every bless.
        if(Date.now() < blessEchoUntil){
          try{ MODEL=await fetchModel(); NODES=flatten(); renderRail();
            const l=curObj(); (l&&l.files||[]).forEach(f=>paintFileCard(f.path, f.status));   // absorb any drift
          }catch(e){}
          return;
        }
        // Coalesce a restack's rapid per-branch moves, then re-render ONLY what moved.
        // Re-rendering the whole detail panel on every forest move thrashed the page —
        // diff-cache wiped, scroll jumped, the open file reloaded — even when the restack
        // was nowhere near your node. So: settle, then diff the model per-node by its
        // file-signature (path+status+add/del — which encodes the parent→node diff, so it
        // catches a move of the node OR its parent), and touch only the movers. The node
        // you're reading is left completely alone unless it actually changed.
        clearTimeout(_updateT);
        _updateT=setTimeout(async()=>{
          try{
            const prevNODES=NODES;
            MODEL=await fetchModel(); NODES=flatten();
            const fsig=n=>JSON.stringify((n&&n.files)||[]);
            const psig={}; prevNODES.forEach(n=>{ psig[n.id]=fsig(n); });
            const changed=new Set();
            NODES.forEach(n=>{ if(psig[n.id]!==fsig(n)) changed.add(n.id); });
            prevNODES.forEach(n=>{ if(!NODES.some(x=>x.id===n.id)) changed.add(n.id); });
            if(!changed.size) return;                                  // nothing real moved → don't touch the page
            // wipe cached diffs only for nodes that moved (others keep their open diff)
            changed.forEach(id=>{ for(const k in NODEPATCH){ if(k===id||k.startsWith(id+'@')) delete NODEPATCH[k]; } });
            renderRail();                                              // status dots: cheap, always
            if($('#map').classList.contains('on')) renderGraph('#map');
            buildDock();
            const cur=curObj();                                        // remount detail ONLY if YOUR node moved
            if(cur && changed.has(cur.id)){
              const anchor=captureScroll(); render(); restoreScroll(anchor); toast('↻ this node updated');
            }
          }catch(e){}
        }, 800);
      });
      es.addEventListener('reload', ()=>{ saveScroll(); setTimeout(()=>location.reload(), 150+Math.random()*1200); });
    }
  }catch(e){ document.body.innerHTML = '<p style="margin:40px;color:#cf6a3a">could not load model: '+e+'</p>'; }
}
boot();
