// apps/desktop/lib/services/remote_page.dart
import 'dart:convert';

import '../l10n/l10n.dart';

/// The words the page uses (this PC's language).
const List<String> remoteWords = [
  'pcfiles.title', 'pcfiles.search_hint', 'pcfiles.search_inside_hint', 'pcfiles.inside', 'pcfiles.k_photo', 'pcfiles.k_video',
  'pcfiles.k_text', 'pcfiles.when', 'pcfiles.all', 'pcfiles.week', 'pcfiles.month', 'pcfiles.year', 'pcfiles.last_year',
  'pcfiles.where', 'pcfiles.everywhere', 'pcfiles.size', 'pcfiles.sort', 'pcfiles.newest', 'pcfiles.oldest', 'pcfiles.by_name',
  'pcfiles.biggest', 'pcfiles.loading', 'pcfiles.empty', 'remote.count', 'remote.open', 'remote.save', 'remote.failed',
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
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#16213E;color:#fff;padding:8px 14px;border-radius:16px;font-size:13px;display:none}
</style></head><body>
<header>
<input id="q" type="search">
<label class="in" id="inl" style="display:none"><input type="checkbox" id="inside"><span id="int"></span></label>
<div class="row" id="kinds"></div>
<div class="row">
<select id="when"></select><select id="place"></select><select id="size"></select><select id="sort"></select>
</div>
</header>
<div class="count" id="count"></div>
<ul id="list"></ul>
<div class="toast" id="toast"></div>
<script>
const W=__WORDS__;
const t=k=>W[k]||k;
const st={kinds:new Set(),when:'',place:'',size:'',sort:'',q:'',inside:false,offset:0,total:0,busy:false,gen:0};
const $=id=>document.getElementById(id);
const icon={photo:'🖼️',video:'🎬',pdf:'📕',word:'📘',excel:'📗',ppt:'📙',text:'📄'};
function fill(sel,items){sel.innerHTML='';for(const [v,l] of items){const o=document.createElement('option');o.value=v;o.textContent=l;sel.appendChild(o);}}
function bytes(n){if(n<1024)return n+' B';const u=['KB','MB','GB','TB'];let i=-1;do{n/=1024;i++}while(n>=1024&&i<3);return n.toFixed(n<10?1:0)+' '+u[i];}
function day(ms){const d=new Date(ms);return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');}
function toast(s){const e=$('toast');e.textContent=s;e.style.display='block';setTimeout(()=>e.style.display='none',2500);}
function ask(cmd,f){const m=JSON.stringify({cmd,path:f.path,name:f.name,kind:f.kind,size:f.size});
  if(window.Keepnear){Keepnear.postMessage(m);}else{location.href='file?p='+encodeURIComponent(f.path);}}
function row(f){
  const li=document.createElement('li');
  const th=document.createElement('div');th.className='t';
  if(f.kind==='photo'||f.kind==='video'||f.kind==='pdf'){const i=document.createElement('img');i.loading='lazy';i.src='thumb?p='+encodeURIComponent(f.path);i.onerror=()=>{th.textContent=icon[f.kind]||'📄';};th.appendChild(i);}else{th.textContent=icon[f.kind]||'📄';}
  const m=document.createElement('div');m.className='m';
  const n=document.createElement('div');n.className='n';n.textContent=f.name;
  const s=document.createElement('div');s.className='s';s.textContent=day(f.taken||f.modified)+' · '+bytes(f.size)+' · '+f.path.substring(0,f.path.length-f.name.length-1);
  m.appendChild(n);m.appendChild(s);
  const b=document.createElement('button');b.className='b';b.textContent=t('remote.save');b.onclick=e=>{e.stopPropagation();ask('save',f);};
  li.appendChild(th);li.appendChild(m);li.appendChild(b);
  li.onclick=()=>ask('open',f);
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
window.keepnearToast=toast;
init();
</script></body></html>''';
