import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import test from 'node:test';
function fixture(file) {
  const nodes = new Map(), requests = [];
  const node = () => ({value:'', textContent:'', children:[], disabled:false, addEventListener(){}, append(...items){this.children.push(...items)}, replaceChildren(){this.children=[]}});
  const $ = id => { if (!nodes.has(id)) nodes.set(id,node()); return nodes.get(id); };
  const context = vm.createContext({$, document:{createElement:node}, BASE:'', URLSearchParams, Date, console, toast(){}, api:async()=>({}), apiFormMutation:async(...args)=>{requests.push(args); return {}}, networkFetch:async(...args)=>{requests.push(args); return {ok:true,json:async()=>({})}}, openStreamUrl(){}, openHls(){}});
  vm.runInContext(readFileSync(new URL('../web/js/'+file,import.meta.url),'utf8'),context);
  return {context,$,requests,run:code=>vm.runInContext(code,context)};
}
test('Recall renders untrusted text and plays opaque moment ids', async()=>{
  const f=fixture('recall.js'); f.$('recall-query').value='heist';
  f.context.api=async()=>({docs:[],moments:[{id:7,title:'<img onerror=evil()>',snippet:'plan',clock:'1:20'}]});
  await f.run('searchRecall()');
  const row=f.$('recall-results').children[0];
  assert.equal(row.children[0].children[0].textContent,'<img onerror=evil()>');
  await row.children[1].onclick();
  assert.equal(f.requests[0][0],'/recall/play');
  assert.equal(f.requests[0][1].moment,7);
});
test('Recall ignores an older search finishing after a newer one',async()=>{
  const f=fixture('recall.js'); let resolve;
  f.context.api=()=>new Promise(r=>{resolve=r}); f.$('recall-query').value='old'; const pending=f.run('searchRecall()');
  f.$('recall-query').value=''; await f.run('searchRecall()'); resolve({docs:[{id:1,title:'stale'}]}); await pending;
  assert.equal(f.$('recall-results').children.length,0);
});
test('Continuum rejects cross-origin session paths and stops retired sessions',async()=>{
  const f=fixture('continuum.js');
  assert.throws(()=>f.run("continuumEndpoint({url:'https://evil/steal/direct'}, 'stop')"));
  f.run("continuumSession={url:'/api/stream/abc/123.def/direct'}"); await f.run('stopContinuum()');
  assert.equal(f.requests[0][0],'/api/stream/abc/123.def/stop');
  assert.equal(f.requests[0][1].method,'POST');
  await f.run('stopContinuum()'); assert.equal(f.requests.length,1);
});
test('Profile PIN errors stay in the picker without dropping the browser session',async()=>{
  const f=fixture('profiles.js'); f.$('profile-choice').value='kid'; f.$('profile-pin').value='0000';
  f.context.networkFetch=async()=>({ok:false,status:401,json:async()=>({error:'pin required',pin_of:'owner'})});
  await f.$('profile-form').onsubmit({preventDefault(){}});
  assert.equal(f.$('profile-status').textContent,'Enter the owner profile PIN.');
  assert.equal(f.$('profile-switch').disabled,false);
});
test('Continuum overlapping starts retain the latest request through player reset',async()=>{
  const f=fixture('continuum.js'), pending=[], opened=[];
  f.context.apiFormMutation=()=>new Promise(resolve=>pending.push(resolve));
  f.context.openStreamUrl=url=>{opened.push(url); void f.run('stopContinuum()');};
  const first=f.run('playContinuum()'); await Promise.resolve(); await Promise.resolve();
  const second=f.run('playContinuum()'); await Promise.resolve(); await Promise.resolve();
  assert.equal(pending.length,2);
  pending[0]({url:'/api/stream/aaa/123.def/direct',mode:'direct',title:'old',start:0,offset:0});
  await first;
  pending[1]({url:'/api/stream/bbb/123.def/direct',mode:'direct',title:'new',start:0,offset:0});
  await second;
  assert.deepEqual(opened,['/api/stream/bbb/123.def/direct']);
  assert.ok(f.requests.some(r=>r[0]==='/api/stream/aaa/123.def/stop'));
});
test('Continuum same-tick starts create only the latest stream',async()=>{
  const f=fixture('continuum.js'), pending=[], opened=[];
  f.context.apiFormMutation=()=>new Promise(resolve=>pending.push(resolve));
  f.context.openStreamUrl=url=>{opened.push(url); void f.run('stopContinuum()');};
  const first=f.run('playContinuum()');
  const second=f.run('playContinuum()');
  for(let i=0;i<8;i++) await Promise.resolve();
  assert.equal(pending.length,1,'obsolete request must exit before creating a stream');
  pending[0]({url:'/api/stream/bbb/123.def/direct',mode:'direct',title:'new',start:0,offset:0});
  await Promise.all([first,second]);
  assert.deepEqual(opened,['/api/stream/bbb/123.def/direct']);
});

test('Commons repeatedly playing and closing clips releases every stream',async()=>{
  const f=fixture('continuum.js');
  vm.runInContext(readFileSync(new URL('../web/js/commons.js',import.meta.url),'utf8'),f.context);
  f.context.api=async()=>({moments:[{id:'clip',title:'Example',start:0,end:2,profile:'owner'}]});
  let slots=0, serial=0;
  f.context.apiFormMutation=async path=>{assert.equal(path,'/moments/play'); assert.ok(slots<2); slots++; return {url:`/api/stream/${++serial}/123.def/direct`,title:'Example'};};
  f.context.networkFetch=async path=>{assert.ok(path.endsWith('/stop')); slots--; return {ok:true};};
  f.context.openStreamUrl=()=>{void f.run('stopContinuum()');};
  await f.run('loadMoments()');
  for(let i=0;i<5;i++) {
    await f.$('moment-list').children[0].children[1].onclick();
    assert.equal(slots,1);
    await f.run('stopContinuum()');
    assert.equal(slots,0);
  }
});
