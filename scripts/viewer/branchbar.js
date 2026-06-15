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
        +(c.date?'<span class="cp-date">'+esc(c.date)+'</span>':'')+'</li>').join('')+'</ul>';
    place();
  }
  document.addEventListener('mousedown',e=>{ if(pop && !pop.contains(e.target) && !(e.target.closest&&e.target.closest('.commitsbtn'))) hidePop(); });
  document.addEventListener('scroll', hidePop, true);

  // ---- checkout --------------------------------------------------------------
  async function doCheckout(btn){
    const branch=branchOf(); if(!branch) return;
    const t=btn.textContent; btn.textContent='checking out…'; btn.disabled=true;
    try{
      const r=await fetch('/checkout',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({branch})}).then(x=>x.json());
      toast(r.ok ? '⤓ checked out <b>'+esc(branch.split('/').pop())+'</b> in your tree'
                 : '⤓ checkout failed: '+esc(lastLine(r.err)));
    }catch(e){ toast('⤓ checkout failed — server unreachable'); }
    btn.textContent=t; btn.disabled=false;
  }

  // ---- inject into the toolbar ----------------------------------------------
  function inject(sub){
    if(typeof LIVE!=='undefined' && !LIVE) return;   // actions need the live repo
    if(sub.dataset.bbar) return; sub.dataset.bbar='1';
    const ci=el('button','commitsbtn','⎇ commits'); ci.title='show this branch’s commits';
    ci.onclick=()=>{ (pop && pop.classList.contains('on')) ? hidePop() : showCommits(ci); };
    const co=el('button','checkouthere','⤓ check out here'); co.title='git checkout this branch in your working tree';
    co.onclick=()=>doCheckout(co);
    sub.append(ci, co);   // after "bless all remaining" (which carries margin-left:auto → right group)
  }
  function scan(n){ if(n.nodeType!==1) return;
    if(n.matches&&n.matches('.sub2')) inject(n);
    if(n.querySelectorAll) n.querySelectorAll('.sub2').forEach(inject); }
  new MutationObserver(ms=>{ for(const m of ms) m.addedNodes.forEach(scan); }).observe(document.body,{childList:true,subtree:true});
  document.querySelectorAll('.sub2').forEach(inject);
})();
