// ── branch toolbar actions ──────────────────────────────────────────────────
// adds two affordances to the .sub2 toolbar. the renderer rebuilds .sub2 every
// render, so rather than touch it we re-inject via a MutationObserver:
//   ⎇ commits        — icon → popover listing this branch's commits (parent..branch)
//   ⤓ check out here — git checkout the viewed branch into the server's working
//      tree, so your terminal (and Claude) sit on the branch you're looking at.
// live-only: both hit endpoints that mutate/inspect the real repo.
(function(){
  function branchOf(){
    if(typeof active==='string' && active) return active;
    if(typeof curObj==='function'){ try{ return curObj().branch||''; }catch(e){} }
    return '';
  }
  function esc(s){ return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
  function lastLine(s){ return ((s||'').trim().split('\n').pop())||'see server'; }

  // ---- commits popover -------------------------------------------------------
  let pop=null, popAnchor=null;
  function popEl(){
    if(!pop){ pop=el('div'); pop.id='commitspop';
      pop.addEventListener('mousedown',e=>e.stopPropagation());
      document.body.appendChild(pop); }
    return pop;
  }
  function hidePop(){ if(pop) pop.classList.remove('on'); }
  function place(){ if(!pop||!popAnchor) return; const r=popAnchor.getBoundingClientRect();
    pop.style.left=Math.max(8, Math.min(r.left, innerWidth-pop.offsetWidth-8))+'px';
    pop.style.top =Math.min(r.bottom+6, innerHeight-pop.offsetHeight-8)+'px'; }
  async function showCommits(anchor){
    const branch=branchOf(); if(!branch) return;
    popAnchor=anchor; const p=popEl();
    p.innerHTML='<div class="cp-load">loading commits…</div>'; p.classList.add('on'); place();
    let list=[];
    try{ list=await (await fetch('/commits?branch='+encodeURIComponent(branch))).json(); }
    catch(e){ p.innerHTML='<div class="cp-load">couldn’t load commits</div>'; place(); return; }
    if(!Array.isArray(list)||!list.length){ p.innerHTML='<div class="cp-load">no commits vs parent</div>'; place(); return; }
    p.innerHTML='<div class="cp-h">'+list.length+' commit'+(list.length>1?'s':'')+' · '+esc(branch.split('/').pop())+' vs parent</div>'
      +'<ul class="cp-list">'+list.map(c=>
        '<li class="cp-it"><span class="cp-sha">'+esc(c.sha)+'</span>'
        +'<span class="cp-sub">'+esc(c.subject)+'</span>'
        +(c.date?'<span class="cp-date">'+esc(c.date)+'</span>':'')+'</li>').join('')+'</ul>'
      +'<div class="cp-foot"></div>';
    squashIdle(branch, list.length);
    place();
  }
  // transitive children of a branch within the loaded forest model — these get
  // reparented by a squash and need a restack afterward.
  function descendantsOf(b){
    const N=(typeof MODEL!=='undefined' && MODEL && MODEL.nodes)||{}, out=[], seen=new Set();
    (function walk(x){ ((N[x]&&N[x].children)||[]).forEach(c=>{ if(N[c]&&!seen.has(c)){ seen.add(c); out.push(c); walk(c); } }); })(b);
    return out;
  }
  function foot(){ return pop && pop.querySelector('.cp-foot'); }
  function squashIdle(branch, n){
    const f=foot(); if(!f) return;
    if(n<=1){ f.innerHTML='<span class="cp-note">1 commit — nothing to squash</span>'; return; }
    f.innerHTML=''; const b=el('button','cp-squash','⤿ squash into one');
    b.onclick=()=>squashConfirm(branch, n); f.appendChild(b);
  }
  function squashConfirm(branch, n){
    const f=foot(); if(!f) return;
    const desc=descendantsOf(branch);
    f.innerHTML='<div class="cp-warn">squash <b>'+n+'</b> commits into one, message drafted in your voice.'
      +(desc.length?' <span class="cp-orphan">⚠ reparents '+desc.length+' descendant'+(desc.length>1?'s':'')+' ('+desc.map(d=>esc(d.split('/').pop())).join(', ')+') — they’ll need a restack.</span>':'')+'</div>';
    const go=el('button','cp-go','squash & commit'); go.onclick=()=>doSquash(branch, desc);
    const cx=el('button','cp-cancel','cancel'); cx.onclick=()=>squashIdle(branch, n);
    const bar=el('div','cp-actions'); bar.append(go, cx); f.appendChild(bar);
  }
  async function doSquash(branch, desc){
    const f=foot(); if(!f) return;
    f.innerHTML='<span class="cp-note">drafting message + squashing…</span>';
    let r;
    try{ r=await (await fetch('/squash',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch})})).json(); }
    catch(e){ f.innerHTML='<span class="cp-warn">squash failed — server unreachable</span>'; return; }
    if(!r || !r.ok){ f.innerHTML='<span class="cp-warn">squash failed: '+esc((r&&r.err)||'see server')+'</span>'; return; }
    toast('⤿ squashed <b>'+esc(branch.split('/').pop())+'</b> → '+esc(r.header)+(r.voiced?'':' <span style="opacity:.7">(fallback msg — claude unavailable)</span>'));
    f.innerHTML='<div class="cp-done">✓ '+esc(r.sha||'')+' '+esc(r.header)+(r.voiced?'':' · <em>fallback message</em>')+'</div>';
    if(desc.length){
      const proj=(typeof MODEL!=='undefined' && MODEL && MODEL.project) || '';
      const hb=el('button','cp-go','⤳ hand off restack to Claude');
      hb.onclick=()=>doRestack(proj, hb, desc.length);
      f.appendChild(hb);
    }
  }
  async function doRestack(project, btn, n){
    btn.textContent='handing off…'; btn.disabled=true;
    try{
      const r=await (await fetch('/restack',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({project})})).json();
      toast(r.ok ? '⤳ restack of '+n+' descendant'+(n>1?'s':'')+' handed off to Claude — tailing restack.log'
                 : '⤳ restack not started: '+esc(r.err||'no project'));
    }catch(e){ toast('⤳ restack handoff failed — server unreachable'); }
    btn.textContent='⤳ restack handed off';
  }
  document.addEventListener('mousedown',e=>{ if(pop && !pop.contains(e.target) && !(e.target.closest&&e.target.closest('.commitsbtn'))) hidePop(); });
  document.addEventListener('scroll', hidePop, true);

  // ---- checkout --------------------------------------------------------------
  async function doCheckout(btn){
    const branch=branchOf(); if(!branch) return;
    const t=btn.textContent; btn.textContent='checking out…'; btn.disabled=true;
    let r;
    try{ r=await fetch('/checkout',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch})}).then(x=>x.json()); }
    catch(e){ toast('⤓ checkout failed — server unreachable'); btn.textContent=t; btn.disabled=false; return; }
    btn.textContent=t; btn.disabled=false;
    if(r.ok){ toast('⤓ checked out <b>'+esc(branch.split('/').pop())+'</b> in your tree'); return; }
    if(r.worktree){ showFree(btn, branch, r.worktree); return; }   // blocked: branch lives in another worktree
    toast('⤓ checkout failed: '+esc(lastLine(r.err)));
  }

  // ---- branch held by another worktree → free it, then checkout here ---------
  let coPop=null, coAnchor=null;
  function coEl(){
    if(!coPop){ coPop=el('div'); coPop.id='copop';
      coPop.addEventListener('mousedown',e=>e.stopPropagation());
      document.body.appendChild(coPop); }
    return coPop;
  }
  function hideFree(){ if(coPop) coPop.classList.remove('on'); }
  function placeFree(){ if(!coPop||!coAnchor) return; const r=coAnchor.getBoundingClientRect();
    coPop.style.left=Math.max(8, Math.min(r.left, innerWidth-coPop.offsetWidth-8))+'px';
    coPop.style.top =Math.min(r.bottom+6, innerHeight-coPop.offsetHeight-8)+'px'; }
  function showFree(anchor, branch, wt){
    coAnchor=anchor; const p=coEl();
    p.innerHTML='<div class="pp-h"><b>'+esc(branch.split('/').pop())+'</b> is open in another worktree</div>'
      +'<div class="pp-note">'+esc(wt)+'</div>'
      +'<div class="cp-warn"><span class="cp-orphan">⚠ frees the branch by detaching that worktree’s HEAD (its commits are kept), then checks it out here. Don’t do this if a session is live there.</span></div>'
      +'<div class="cp-foot"></div>';
    const f=p.querySelector('.cp-foot');
    const go=el('button','cp-go','⤓ free worktree + checkout here'); go.onclick=()=>doFree(branch, f);
    const cx=el('button','cp-cancel','cancel'); cx.onclick=hideFree;
    const bar=el('div','cp-actions'); bar.append(go, cx); f.appendChild(bar);
    p.classList.add('on'); placeFree();
  }
  async function doFree(branch, f){
    f.innerHTML='<span class="cp-note">freeing worktree · checking out…</span>';
    let r;
    try{ r=await (await fetch('/checkout',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch, force:true})})).json(); }
    catch(e){ f.innerHTML='<span class="cp-warn">checkout failed — server unreachable</span>'; return; }
    if(!r || !r.ok){ f.innerHTML='<span class="cp-warn">checkout failed: '+esc((r&&lastLine(r.err))||'see server')+'</span>'; return; }
    toast('⤓ freed + checked out <b>'+esc(branch.split('/').pop())+'</b> in your tree');
    hideFree();
  }
  document.addEventListener('mousedown',e=>{ if(coPop && !coPop.contains(e.target) && !(e.target.closest&&e.target.closest('.checkouthere'))) hideFree(); });
  document.addEventListener('scroll', hideFree, true);

  // ---- prep for push (squash UNPUSHED commits → one, then oxfmt) -------------
  let prepPop=null, prepAnchor=null;
  function prepEl(){
    if(!prepPop){ prepPop=el('div'); prepPop.id='preppop';
      prepPop.addEventListener('mousedown',e=>e.stopPropagation());
      document.body.appendChild(prepPop); }
    return prepPop;
  }
  function hidePrep(){ if(prepPop) prepPop.classList.remove('on'); }
  function placePrep(){ if(!prepPop||!prepAnchor) return; const r=prepAnchor.getBoundingClientRect();
    prepPop.style.left=Math.max(8, Math.min(r.left, innerWidth-prepPop.offsetWidth-8))+'px';
    prepPop.style.top =Math.min(r.bottom+6, innerHeight-prepPop.offsetHeight-8)+'px'; }
  function showPrep(anchor){
    const branch=branchOf(); if(!branch) return;
    prepAnchor=anchor; const p=prepEl(); const desc=descendantsOf(branch);
    p.innerHTML='<div class="pp-h">prep <b>'+esc(branch.split('/').pop())+'</b> for push</div>'
      +'<ul class="pp-steps"><li>squash <b>unpushed</b> commits → one (voiced message)</li>'
      +'<li>run oxfmt, fold formatting into that commit</li></ul>'
      +'<div class="pp-note">only unpushed history is rewritten — a plain push works, no force-push.</div>'
      +(desc.length?'<div class="cp-warn"><span class="cp-orphan">⚠ reparents '+desc.length+' descendant'+(desc.length>1?'s':'')+' ('+desc.map(d=>esc(d.split('/').pop())).join(', ')+') — they’ll need a restack.</span></div>':'')
      +'<div class="cp-foot"></div>';
    const f=p.querySelector('.cp-foot');
    const go=el('button','cp-go','prep & format'); go.onclick=()=>doPrep(branch, desc, f);
    const cx=el('button','cp-cancel','cancel'); cx.onclick=hidePrep;
    const bar=el('div','cp-actions'); bar.append(go, cx); f.appendChild(bar);
    p.classList.add('on'); placePrep();
  }
  async function doPrep(branch, desc, f){
    f.innerHTML='<span class="cp-note">drafting message · squashing · oxfmt…</span>';
    let r;
    try{ r=await (await fetch('/prep',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch})})).json(); }
    catch(e){ f.innerHTML='<span class="cp-warn">prep failed — server unreachable</span>'; return; }
    if(!r || !r.ok){ f.innerHTML='<span class="cp-warn">prep failed: '+esc((r&&r.err)||'see server')+'</span>'; return; }
    const fmtnote = r.formatted ? (' · oxfmt fixed '+r.formatted+' file'+(r.formatted>1?'s':'')) : ' · already formatted';
    toast('⇡ prepped <b>'+esc(branch.split('/').pop())+'</b> → '+esc(r.header)+(r.voiced?'':' (fallback msg)'));
    f.innerHTML='<div class="cp-done">✓ '+esc(r.sha||'')+' '+esc(r.header)+fmtnote+(r.voiced?'':' · <em>fallback message</em>')+'</div>'
      +'<div class="cp-note">ready to push (no force needed).</div>';
    if(desc.length){
      const proj=(typeof MODEL!=='undefined' && MODEL && MODEL.project) || '';
      const hb=el('button','cp-go','⤳ hand off restack to Claude'); hb.onclick=()=>doRestack(proj, hb, desc.length);
      f.appendChild(hb);
    }
  }
  document.addEventListener('mousedown',e=>{ if(prepPop && !prepPop.contains(e.target) && !(e.target.closest&&e.target.closest('.prepbtn'))) hidePrep(); });
  document.addEventListener('scroll', hidePrep, true);

  // ---- fork-staleness badge (behind origin/main) -----------------------------
  // a branch whose fork point lags origin/main shows "↺ N behind". When it's a
  // root off main AND unpublished, the badge is a live button: one click rebases
  // it onto fresh origin/main (safe — no force-push, no parent to detach). When
  // it's published or stacked, the badge is inert and explains why on hover.
  // styled via .syncbadge in styles.css to match the sibling toolbar buttons.
  async function doSync(btn, branch){
    const t=btn.textContent; btn.textContent='rebasing…'; btn.disabled=true;
    try{
      const r=await fetch('/sync',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch})}).then(x=>x.json());
      if(r.ok){ toast('↺ synced <b>'+esc(branch.split('/').pop())+'</b> onto fresh origin/main'); btn.remove(); }
      else { toast('↺ sync failed: '+esc(lastLine(r.err))); btn.textContent=t; btn.disabled=false; }
    }catch(e){ toast('↺ sync failed — server unreachable'); btn.textContent=t; btn.disabled=false; }
  }
  async function syncBadge(sub, branch){
    let s;
    try{ s=await (await fetch('/sync?branch='+encodeURIComponent(branch))).json(); }
    catch(e){ return; }
    if(!s || !s.behind) return;   // up to date with origin/main → no badge
    const b=el('button','syncbadge'+(s.syncable?' syncable':''),'↺ '+s.behind+' behind');
    if(s.syncable){
      b.title='rebase onto fresh origin/main — unpublished root branch, no force-push';
      b.onclick=()=>doSync(b, branch);
    } else {
      b.disabled=true;
      b.title=s.why||'fork point is behind origin/main';
    }
    sub.appendChild(b);
  }

  // ---- inject into the toolbar ----------------------------------------------
  function inject(sub){
    if(typeof LIVE!=='undefined' && !LIVE) return;   // actions need the live repo
    if(sub.dataset.bbar) return; sub.dataset.bbar='1';
    const ci=el('button','commitsbtn','⎇ commits'); ci.title='show this branch’s commits';
    ci.onclick=()=>{ (pop && pop.classList.contains('on')) ? hidePop() : showCommits(ci); };
    const co=el('button','checkouthere','⤓ check out here'); co.title='git checkout this branch in your working tree';
    co.onclick=()=>doCheckout(co);
    const pp=el('button','prepbtn','⇡ prep for push'); pp.title='squash unpushed commits into one + oxfmt, ready to push';
    pp.onclick=()=>{ (prepPop && prepPop.classList.contains('on')) ? hidePrep() : showPrep(pp); };
    sub.append(ci, co, pp);   // after "bless all remaining" (which carries margin-left:auto → right group)
    const branch=branchOf(); if(branch) syncBadge(sub, branch);   // async; appends iff behind origin/main
  }
  function scan(n){ if(n.nodeType!==1) return;
    if(n.matches&&n.matches('.sub2')) inject(n);
    if(n.querySelectorAll) n.querySelectorAll('.sub2').forEach(inject); }
  new MutationObserver(ms=>{ for(const m of ms) m.addedNodes.forEach(scan); }).observe(document.body,{childList:true,subtree:true});
  document.querySelectorAll('.sub2').forEach(inject);
})();
