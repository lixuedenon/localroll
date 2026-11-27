// apps/desktop/lib/services/remote_page.dart
import 'dart:convert';

import '../l10n/l10n.dart';

/// The words the page uses (this PC's language).
const List<String> remoteWords = [
  'pcfiles.title', 'pcfiles.search_hint', 'pcfiles.search_inside_hint', 'pcfiles.inside', 'pcfiles.k_photo', 'pcfiles.k_video',
  'pcfiles.k_text', 'pcfiles.when', 'pcfiles.all', 'pcfiles.week', 'pcfiles.month', 'pcfiles.year', 'pcfiles.last_year',
  'pcfiles.where', 'pcfiles.everywhere', 'pcfiles.size', 'pcfiles.sort', 'pcfiles.newest', 'pcfiles.oldest', 'pcfiles.by_name',
  'pcfiles.biggest', 'pcfiles.loading', 'pcfiles.empty', 'remote.count', 'remote.open', 'remote.save', 'remote.failed',
  'remote.copyin', 'remote.rename', 'remote.move', 'remote.delete', 'remote.delete_q', 'remote.cancel', 'remote.ok', 'remote.done',
  'remote.tab_files', 'remote.tab_pc', 'remote.shot', 'remote.clip_get', 'remote.clip_set', 'remote.clip_send', 'remote.vol_down',
  'remote.mute', 'remote.vol_up', 'remote.lock', 'remote.sleep', 'remote.shutdown', 'remote.restart', 'remote.off_q', 'remote.off_soon',
  'remote.off_cancel', 'remote.copy_phone', 'remote.had', 'remote.taken', 'remote.new_name', 'remote.move_to', 'remote.sleep_q',
  'remote.clip_empty', 'remote.copied', 'remote.tab_tasks', 'remote.select', 'remote.convert', 'remote.compress', 'remote.merge',
  'remote.print', 'remote.aipack', 'remote.started', 'remote.no_tasks', 'remote.made', 'remote.pick_printer', 'remote.no_printer',
  'remote.need_two_pdfs', 'remote.rec_start', 'remote.rec_stop', 'remote.selected', 'remote.no_convert', 'remote.small',
];

/// The page a phone shows for "Other files on this PC" (the phone only
/// shows it; everything is done here). Opening / saving a file is asked of
/// the Keepnear app on the phone (window.Keepnear), which fetches it.
String remotePage() {
  final w = jsonEncode({for (final k in remoteWords) k: tr(k)});
  return _html.replaceFirst('__WORDS__', w);
}

const String _html = r'''<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover">
<style>
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;background:#F3F6FC;color:#16213E}
header{position:sticky;top:0;background:#F3F6FC;padding:10px 12px 6px;z-index:2}
input[type=search]{width:100%;padding:10px 12px;border:1px solid #D8E0EE;border-radius:10px;font-size:15px;background:#fff}
.row{display:flex;gap:6px;overflow-x:auto;padding:8px 0 2px;scrollbar-width:none}
.row::-webkit-scrollbar{display:none}
.chip{flex:none;padding:6px 12px;border-radius:16px;border:1px solid #D8E0EE;background:#fff;font-size:13px;white-space:nowrap}
.chip.on{background:#2F6BFF;color:#fff;border-color:#2F6BFF}
select{flex:none;padding:6px 8px;border-radius:16px;border:1px solid #D8E0EE;background:#fff;font-size:13px;color:#16213E}
label.in{display:flex;align-items:center;gap:6px;font-size:13px;color:#6B7A99;margin-top:6px}
.count{font-size:12px;color:#6B7A99;padding:4px 14px}
ul{list-style:none;margin:0;padding:0 8px 40px}
li{display:flex;align-items:center;gap:10px;background:#fff;margin:6px 0;padding:8px;border-radius:12px}
.t{width:52px;height:52px;flex:none;border-radius:8px;background:#EFF3FA;display:flex;align-items:center;justify-content:center;font-size:24px;overflow:hidden}
.t img{width:100%;height:100%;object-fit:cover}
.m{flex:1;min-width:0}
.n{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.s{font-size:11px;color:#6B7A99;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.b{flex:none;border:none;background:#EFF3FA;color:#2F6BFF;border-radius:16px;padding:7px 12px;font-size:13px}
.empty{text-align:center;color:#6B7A99;padding:40px 0}
.tabs{display:flex;gap:6px;margin-bottom:8px}
.tab{flex:1;text-align:center;padding:8px;border-radius:10px;background:#fff;border:1px solid #D8E0EE;font-size:14px}
.tab.on{background:#2F6BFF;color:#fff;border-color:#2F6BFF}
.dots{flex:none;border:none;background:none;font-size:22px;color:#6B7A99;padding:4px 8px}
#pc{display:none;padding:8px 12px 40px}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}
.grid button,.wide{border:none;background:#fff;border-radius:14px;padding:16px 6px;font-size:14px;color:#16213E;box-shadow:0 2px 8px rgba(29,59,138,.08)}
.grid button span{display:block;font-size:26px;margin-bottom:6px}
.wide{width:100%;margin-top:8px;background:#2F6BFF;color:#fff;padding:12px}
textarea{width:100%;min-height:70px;border:1px solid #D8E0EE;border-radius:10px;padding:10px;font-size:15px}
.sec{font-size:13px;color:#6B7A99;margin:14px 2px 8px}
#mask{position:fixed;inset:0;background:rgba(10,20,40,.35);display:none;z-index:5}
#sheet{position:fixed;left:0;right:0;bottom:0;background:#fff;border-radius:16px 16px 0 0;padding:14px 14px 28px;display:none;z-index:6;max-height:80vh;overflow:auto}
#sheet .h{font-weight:600;margin:2px 4px 10px;word-break:break-all}
#sheet .p{font-size:13px;color:#6B7A99;margin:0 4px 10px;white-space:pre-wrap;word-break:break-all}
#sheet button{display:block;width:100%;text-align:left;border:none;background:#F3F6FC;border-radius:10px;padding:13px 14px;margin:6px 0;font-size:15px;color:#16213E}
#sheet button.red{color:#E5484D}
#sheet button.blue{background:#2F6BFF;color:#fff;text-align:center}
#sheet input{width:100%;padding:11px;border:1px solid #D8E0EE;border-radius:10px;font-size:15px;margin:4px 0 6px}
.ck{flex:none;width:22px;height:22px;border-radius:50%;border:2px solid #C5D0E6;display:none}
.sel .ck{display:block}.ck.on{background:#2F6BFF;border-color:#2F6BFF}
.cl{display:flex;align-items:center;justify-content:space-between}
.cl button{border:none;background:none;color:#2F6BFF;font-size:13px;padding:4px 14px}
#bar{position:fixed;left:0;right:0;bottom:0;background:#fff;box-shadow:0 -2px 10px rgba(29,59,138,.12);padding:8px 6px 22px;display:none;z-index:4}
#bar .bt{display:flex;gap:6px;overflow-x:auto}
#bar button{flex:none;border:none;background:#EFF3FA;color:#16213E;border-radius:16px;padding:9px 13px;font-size:13px}
#bar .n{font-size:12px;color:#6B7A99;margin:0 6px 6px}
#tasks{display:none;padding:8px 12px 40px}
.task{background:#fff;border-radius:12px;padding:10px 12px;margin:6px 0}
.task .bar2{height:5px;background:#EFF3FA;border-radius:3px;margin-top:6px;overflow:hidden}
.task .bar2 div{height:100%;background:#2F6BFF}
.toast{position:fixed;z-index:9;left:50%;bottom:24px;transform:translateX(-50%);background:#16213E;color:#fff;padding:8px 14px;border-radius:16px;font-size:13px;display:none}
</style></head><body>
<header>
<div class="tabs"><div class="tab on" id="tf"></div><div class="tab" id="tt"></div><div class="tab" id="tp"></div></div>
<div id="fh">
<input id="q" type="search">
<label class="in" id="inl" style="display:none"><input type="checkbox" id="inside"><span id="int"></span></label>
<div class="row" id="kinds"></div>
<div class="row">
<select id="when"></select><select id="place"></select><select id="size"></select><select id="sort"></select>
</div>
</div>
</header>
<div id="files"><div class="cl"><div class="count" id="count"></div><button id="selb"></button></div>
<ul id="list"></ul></div>
<div id="pc">
<div class="grid">
<button id="b_shot"><span>📸</span></button><button id="b_clip"><span>📋</span></button><button id="b_lock"><span>🔒</span></button>
<button id="b_vd"><span>🔉</span></button><button id="b_mute"><span>🔇</span></button><button id="b_vu"><span>🔊</span></button>
<button id="b_sleep"><span>🌙</span></button><button id="b_restart"><span>🔄</span></button><button id="b_off"><span>⏻</span></button>
<button id="b_rec"><span>⏺️</span></button>
</div>
<div class="sec" id="cs"></div>
<textarea id="clip"></textarea>
<button class="wide" id="b_send"></button>
</div>
<div id="tasks"><div class="sec" id="th1"></div><div id="tl"></div><div class="sec" id="th2"></div><ul id="ml" style="padding:0"></ul></div>
<div id="bar"><div class="n" id="bn"></div><div class="bt">
<button id="a_conv"></button><button id="a_comp"></button><button id="a_merge"></button><button id="a_print"></button><button id="a_ai"></button></div></div>
<div id="mask"></div><div id="sheet"></div>
<div class="toast" id="toast"></div>
<script>
const W=__WORDS__;
const t=k=>W[k]||k;
const st={kinds:new Set(),when:'',place:'',size:'',sort:'',q:'',inside:false,offset:0,total:0,busy:false,gen:0};
const $=id=>document.getElementById(id);
const icon={photo:'🖼️',video:'🎬',pdf:'📕',word:'📘',excel:'📗',ppt:'📙',text:'📄'};
function fill(sel,items){sel.innerHTML='';for(const [v,l] of items){const o=document.createElement('option');o.value=v;o.textContent=l;sel.appendChild(o);}}
function bytes(n){if(n<1024)return n+' B';const u=['KB','MB','GB','TB'];let i=-1;do{n/=1024;i++}while(n>=1024&&i<3);return n.toFixed(n<10?1:0)+' '+u[i];}
function day(ms){if(!ms)return '';const d=new Date(ms);return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');}
function toast(s){const e=$('toast');e.textContent=s;e.style.display='block';setTimeout(()=>e.style.display='none',2500);}
function ask(cmd,f){const m=JSON.stringify({cmd,path:f.path,name:f.name,kind:f.kind,size:f.size});
  if(window.Keepnear){Keepnear.postMessage(m);}else{location.href='file?p='+encodeURIComponent(f.path);}}
function row(f){
  const li=document.createElement('li');
  const ck=document.createElement('div');ck.className='ck'+(chosen.has(f.path)?' on':'');li.appendChild(ck);
  const th=document.createElement('div');th.className='t';
  if(f.kind==='photo'||f.kind==='video'||f.kind==='pdf'){const i=document.createElement('img');i.loading='lazy';i.src='thumb?p='+encodeURIComponent(f.path);i.onerror=()=>{th.textContent=icon[f.kind]||'📄';};th.appendChild(i);}else{th.textContent=icon[f.kind]||'📄';}
  const m=document.createElement('div');m.className='m';
  const n=document.createElement('div');n.className='n';n.textContent=f.name;
  const s=document.createElement('div');s.className='s';s.textContent=[day(f.taken||f.modified),bytes(f.size),f.path.substring(0,f.path.length-f.name.length-1)].filter(x=>x).join(' · ');
  m.appendChild(n);m.appendChild(s);
  const b=document.createElement('button');b.className='dots';b.textContent='⋯';b.onclick=e=>{e.stopPropagation();more(f);};
  li.appendChild(th);li.appendChild(m);li.appendChild(b);
  li.onclick=()=>{if(selecting){chosen.has(f.path)?chosen.delete(f.path):chosen.add(f.path);ck.classList.toggle('on');barShow();}else ask('open',f);};
  return li;
}
async function load(more){
  if(st.busy)return; if(more&&st.offset>=st.total)return;
  st.busy=true;const gen=++st.gen;
  if(!more){st.offset=0;$('list').innerHTML='';$('count').textContent=t('pcfiles.loading');}
  const p=new URLSearchParams({kinds:[...st.kinds].join(','),when:st.when,place:st.place,size:st.size,sort:st.sort,q:st.q,inside:st.inside?'1':'0',offset:String(st.offset),limit:'100'});
  try{
    const r=await fetch('files?'+p.toString());const j=await r.json();
    if(gen!==st.gen)return;
    st.total=j.total;st.offset+=j.files.length;
    places=j.places;
    if(!more){fill($('place'),[['',t('pcfiles.where')+': '+t('pcfiles.everywhere')],...j.places.map(x=>[x.path,t('pcfiles.where')+': '+x.name])]);$('place').value=st.place;
      $('inl').style.display=j.source==='windowsSearch'?'flex':'none';}
    for(const f of j.files)$('list').appendChild(row(f));
    $('count').textContent=t('remote.count').replace('{count}',j.total);
    if(j.total===0)$('list').innerHTML='<div class="empty">'+t('pcfiles.empty')+'</div>';
  }catch(e){$('count').textContent=t('remote.failed');}
  finally{st.busy=false;}
}
function init(){
  $('q').placeholder=t('pcfiles.search_hint');$('int').textContent=t('pcfiles.inside');
  const kinds=[['photo',t('pcfiles.k_photo')],['video',t('pcfiles.k_video')],['pdf','PDF'],['word','Word'],['excel','Excel'],['ppt','PowerPoint'],['text',t('pcfiles.k_text')]];
  for(const [k,l] of kinds){const c=document.createElement('span');c.className='chip';c.textContent=l;c.onclick=()=>{st.kinds.has(k)?st.kinds.delete(k):st.kinds.add(k);c.classList.toggle('on');load(false);};$('kinds').appendChild(c);}
  const w=t('pcfiles.when')+': ';fill($('when'),[['',w+t('pcfiles.all')],['week',w+t('pcfiles.week')],['month',w+t('pcfiles.month')],['year',w+t('pcfiles.year')],['last_year',w+t('pcfiles.last_year')]]);
  const z=t('pcfiles.size')+': ';fill($('size'),[['',z+t('pcfiles.all')],['small',z+'< 1 MB'],['medium',z+'1–100 MB'],['big',z+'100 MB–1 GB'],['huge',z+'> 1 GB']]);
  const o=t('pcfiles.sort')+': ';fill($('sort'),[['',o+t('pcfiles.newest')],['oldest',o+t('pcfiles.oldest')],['name',o+t('pcfiles.by_name')],['biggest',o+t('pcfiles.biggest')]]);
  fill($('place'),[['',t('pcfiles.where')+': '+t('pcfiles.everywhere')]]);
  for(const id of ['when','place','size','sort'])$(id).onchange=e=>{st[id]=e.target.value;load(false);};
  let timer;$('q').oninput=e=>{clearTimeout(timer);timer=setTimeout(()=>{st.q=e.target.value.trim();load(false);},450);};
  $('inside').onchange=e=>{st.inside=e.target.checked;$('q').placeholder=t(st.inside?'pcfiles.search_inside_hint':'pcfiles.search_hint');if(st.q)load(false);};
  window.addEventListener('scroll',()=>{if(window.innerHeight+window.scrollY>document.body.offsetHeight-600)load(true);});
  load(false);
}
function sheet(title,note,items){
  const sh=$('sheet');sh.innerHTML='';
  if(title){const h=document.createElement('div');h.className='h';h.textContent=title;sh.appendChild(h);}
  if(note){const p=document.createElement('div');p.className='p';p.textContent=note;sh.appendChild(p);}
  for(const it of items){
    if(it.input){const i=document.createElement('input');i.id='sin';i.value=it.input;sh.appendChild(i);setTimeout(()=>{i.focus();i.select();},50);continue;}
    const b=document.createElement('button');b.textContent=it.label;if(it.cls)b.className=it.cls;
    b.onclick=()=>{const v=$('sin')?$('sin').value:null;close();it.go&&it.go(v);};sh.appendChild(b);}
  const c=document.createElement('button');c.textContent=t('remote.cancel');c.onclick=close;sh.appendChild(c);
  $('mask').style.display='block';sh.style.display='block';
}
function close(){$('mask').style.display='none';$('sheet').style.display='none';}
async function act(params){
  try{const r=await fetch('act?'+new URLSearchParams(params).toString());return await r.json();}catch(e){return {ok:false};}
}
let places=[];
function more(f){
  sheet(f.name,null,[
    {label:t('remote.open'),go:()=>ask('open',f)},
    {label:t('remote.save'),go:()=>ask('save',f)},
    {label:t('remote.copyin'),go:async()=>{const r=await act({do:'copyin',p:f.path});toast(r.ok?(r.had?t('remote.had'):t('remote.done')):t('remote.failed'));}},
    {label:t('remote.rename'),go:()=>sheet(t('remote.new_name'),null,[{input:f.name},{label:t('remote.ok'),cls:'blue',go:async v=>{
        if(!v||v===f.name)return;const r=await act({do:'rename',p:f.path,name:v});toast(r.ok?t('remote.done'):(r.error==='taken'?t('remote.taken'):t('remote.failed')));if(r.ok)load(false);}}])},
    {label:t('remote.move'),go:()=>sheet(t('remote.move_to'),null,places.map(x=>({label:x.name,go:async()=>{
        const r=await act({do:'move',p:f.path,to:x.path});toast(r.ok?t('remote.done'):t('remote.failed'));if(r.ok)load(false);}})))},
    {label:t('remote.delete'),cls:'red',go:()=>sheet(f.name,t('remote.delete_q'),[{label:t('remote.delete'),cls:'red',go:async()=>{
        const r=await act({do:'delete',p:f.path});toast(r.ok?t('remote.done'):t('remote.failed'));if(r.ok)load(false);}}])},
  ]);
}
let cur='f',timer2=null;
function tab(w){cur=w;$('tf').classList.toggle('on',w==='f');$('tt').classList.toggle('on',w==='t');$('tp').classList.toggle('on',w==='p');
  $('fh').style.display=w==='f'?'block':'none';$('files').style.display=w==='f'?'block':'none';$('tasks').style.display=w==='t'?'block':'none';$('pc').style.display=w==='p'?'block':'none';
  barShow();clearInterval(timer2);if(w==='t'){tasks();timer2=setInterval(tasks,2000);}if(w==='p')recState();}
let selecting=false;const chosen=new Set();
function barShow(){$('bar').style.display=(cur==='f'&&selecting)?'block':'none';$('bn').textContent=t('remote.selected').replace('{count}',chosen.size);
  $('selb').textContent=selecting?t('remote.cancel'):t('remote.select');document.body.classList.toggle('sel',selecting);$('list').classList.toggle('sel',selecting);}
function ps(){return JSON.stringify([...chosen]);}
async function tool(params){const r=await act(params);toast(r.ok?t('remote.started'):(r.error==='two_pdfs'?t('remote.need_two_pdfs'):t('remote.failed')));if(r.ok){selecting=false;chosen.clear();barShow();load(false);}}
function initTools(){
  $('selb').onclick=()=>{selecting=!selecting;chosen.clear();barShow();load(false);};
  $('a_conv').textContent=t('remote.convert');$('a_comp').textContent=t('remote.compress');$('a_merge').textContent=t('remote.merge');$('a_print').textContent=t('remote.print');$('a_ai').textContent=t('remote.aipack');
  $('a_conv').onclick=async()=>{if(!chosen.size)return;const r=await (await fetch('tools?'+new URLSearchParams({ps:ps()}))).json();
    if(!r.convert.length){toast(t('remote.no_convert'));return;}
    sheet(t('remote.convert'),null,r.convert.map(c=>({label:c.label+(c.best?' ★':'')+(c.use?'  · '+c.use:''),go:()=>tool({do:'convert',ps:ps(),to:c.to})})));};
  $('a_comp').onclick=()=>{if(chosen.size)tool({do:'compress',ps:ps()});};
  $('a_merge').onclick=()=>{if(chosen.size)tool({do:'merge',ps:ps()});};
  $('a_ai').onclick=()=>{if(chosen.size)tool({do:'aipack',ps:ps()});};
  $('a_print').onclick=async()=>{if(!chosen.size)return;const r=await (await fetch('tools?'+new URLSearchParams({ps:ps()}))).json();
    if(!r.printers.length){toast(t('remote.no_printer'));return;}
    sheet(t('remote.pick_printer'),null,r.printers.map(p=>({label:p.name+(p.default?' ★':''),go:()=>tool({do:'print',ps:ps(),printer:p.name})})));};
  $('th1').textContent=t('remote.tab_tasks');$('th2').textContent=t('remote.made');
}
async function tasks(){
  try{const r=await (await fetch('tasks')).json();
    const tl=$('tl');tl.innerHTML='';
    if(!r.tasks.length)tl.innerHTML='<div class="empty">'+t('remote.no_tasks')+'</div>';
    for(const x of r.tasks){const d=document.createElement('div');d.className='task';
      const icon=x.state==='done'?'✅ ':x.state==='failed'||x.state==='cancelled'?'⚠️ ':'⏳ ';
      d.textContent=icon+x.title;const b=document.createElement('div');b.className='bar2';const i=document.createElement('div');
      i.style.width=Math.round((x.state==='done'?1:x.progress)*100)+'%';b.appendChild(i);d.appendChild(b);tl.appendChild(d);}
    const ml=$('ml');ml.innerHTML='';for(const f of r.made){const li=row(f);ml.appendChild(li);}
  }catch(e){}
}
async function recState(){const r=await act({do:'rec_state'});recOn=!!r.recording;recLabel();}
let recOn=false;function recLabel(){const b=$('b_rec');b.lastChild.textContent=t(recOn?'remote.rec_stop':'remote.rec_start');}
function initPc(){
  $('tf').textContent=t('remote.tab_files');$('tt').textContent=t('remote.tab_tasks');$('tp').textContent=t('remote.tab_pc');
  $('tf').onclick=()=>tab('f');$('tt').onclick=()=>tab('t');$('tp').onclick=()=>tab('p');
  $('b_rec').appendChild(document.createTextNode(t('remote.rec_start')));
  $('b_rec').onclick=async()=>{const r=await act({do:recOn?'rec_stop':'rec_start'});if(r.ok){recOn=!recOn;recLabel();toast(t('remote.done'));}else toast(t('remote.failed'));};
  const lab=(id,k)=>{$(id).appendChild(document.createTextNode(t(k)));};
  lab('b_shot','remote.shot');lab('b_clip','remote.clip_get');lab('b_lock','remote.lock');lab('b_vd','remote.vol_down');lab('b_mute','remote.mute');lab('b_vu','remote.vol_up');
  lab('b_sleep','remote.sleep');lab('b_restart','remote.restart');lab('b_off','remote.shutdown');
  $('cs').textContent=t('remote.clip_set');$('b_send').textContent=t('remote.clip_send');
  $('b_shot').onclick=()=>{if(window.Keepnear)Keepnear.postMessage(JSON.stringify({cmd:'shot'}));else location.href='shot';};
  $('b_clip').onclick=async()=>{const r=await act({do:'clip_get'});if(!r.ok){toast(t('remote.failed'));return;}
    if(!r.text){toast(t('remote.clip_empty'));return;}
    sheet(t('remote.clip_get'),r.text,[{label:t('remote.copy_phone'),cls:'blue',go:()=>{if(window.Keepnear)Keepnear.postMessage(JSON.stringify({cmd:'copy',text:r.text}));toast(t('remote.copied'));}}]);};
  $('b_send').onclick=async()=>{const v=$('clip').value;if(!v)return;const r=await act({do:'clip_set',text:v});toast(r.ok?t('remote.done'):t('remote.failed'));};
  $('b_lock').onclick=async()=>{const r=await act({do:'lock'});toast(r.ok?t('remote.done'):t('remote.failed'));};
  $('b_vd').onclick=()=>act({do:'vol_down'});$('b_vu').onclick=()=>act({do:'vol_up'});$('b_mute').onclick=()=>act({do:'mute'});
  $('b_sleep').onclick=()=>sheet(t('remote.sleep'),t('remote.sleep_q'),[{label:t('remote.sleep'),cls:'blue',go:async()=>{const r=await act({do:'sleep'});toast(r.ok?t('remote.done'):t('remote.failed'));}}]);
  const off=(what,k)=>sheet(t(k),t('remote.off_q'),[{label:t(k),cls:'red',go:async()=>{const r=await act({do:what});
    if(r.ok)sheet(t('remote.off_soon'),null,[{label:t('remote.off_cancel'),cls:'blue',go:async()=>{const c=await act({do:'cancel'});toast(c.ok?t('remote.done'):t('remote.failed'));}}]);else toast(t('remote.failed'));}}]);
  $('b_off').onclick=()=>off('shutdown','remote.shutdown');$('b_restart').onclick=()=>off('restart','remote.restart');
}
$('mask').onclick=close;
window.keepnearToast=toast;
initPc();
initTools();
barShow();
init();
</script></body></html>''';
