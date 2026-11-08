'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const read=name=>fs.readFileSync(`assets/browser-integration/${name}.js`,'utf8');
const event=()=>({addListener(fn){this.fn=fn}});
async function background(){
 const sent=[];const api={webRequest:{onSendHeaders:event(),onHeadersReceived:event()},tabs:{onRemoved:event(),onUpdated:event(),async get(){return {url:'https://www.youtube.com/watch?v=abcdefghijk'}}},runtime:{onMessage:event(),async sendNativeMessage(app,message){sent.push({app,message});return {ok:true}}}};
 vm.runInNewContext(read('background'),{browser:api,URL,Map});
 const request=(id,url,headers=[])=>api.webRequest.onSendHeaders.fn({requestId:id,tabId:9,url,requestHeaders:headers});
 request('v','https://r1.googlevideo.com/videoplayback?clen=1024',[{name:'Cookie',value:'session=one; other=two'},{name:'Accept',value:'video/*, */*'},{name:'Range',value:'bytes=0-99'}]);
 await api.webRequest.onHeadersReceived.fn({requestId:'v',tabId:9,statusCode:206,responseHeaders:[{name:'Content-Type',value:'video/mp4'}]});
 request('a','https://r2.googlevideo.com/videoplayback?clen=512');
 await api.webRequest.onHeadersReceived.fn({requestId:'a',tabId:9,statusCode:206,responseHeaders:[{name:'Content-Type',value:'audio/mp4'}]});
 const sender={tab:{id:9},frameId:0,url:'https://www.youtube.com/watch?v=abcdefghijk'};
 const message={what:'play-youtube',url:sender.url,time:91.25,muted:true,volume:0.4};
 assert.equal((await api.runtime.onMessage.fn(message,sender)).ok,true);
 assert.equal(sent[0].app,'opal.browser');assert.equal(sent[0].message.time,91.25);
 assert.deepEqual(Array.from(sent[0].message.video.headers,h=>h.name),['Cookie','Accept']);
 assert.equal(sent[0].message.video.headers[1].value,'video/*, */*');
 assert.equal((await api.runtime.onMessage.fn(message,{...sender,url:'https://youtube.com.evil.test/watch?v=abcdefghijk'})).ok,false);
 assert.equal((await api.runtime.onMessage.fn(message,{...sender,frameId:1})).ok,false);
 assert.equal((await api.runtime.onMessage.fn({...message,url:'https://www.youtube.com/watch?v=11111111111'},sender)).ok,false);
 api.tabs.onUpdated.fn(9,{url:'https://www.youtube.com/watch?v=11111111111'});
 await api.runtime.onMessage.fn(message,sender);assert.equal(sent.at(-1).message.video,null);
 assert.equal((await api.runtime.onMessage.fn({what:'play-youtube',url:'https://example.com/'},{...sender,url:'https://example.com/'})).ok,false);
}
// REGRESSION: macOS 15 WebKit rejects webRequest in MV3 backgrounds; one bad
// listener used to abort background.js before runtime.onMessage registered.
async function backgroundWithoutWebRequest(){
 const throwing={addListener(){throw new Error('Non-persistent background content cannot listen to `webRequest` events.')}};
 for(const webRequest of [undefined,{onSendHeaders:throwing,onHeadersReceived:throwing}]){
  const sent=[];const api={webRequest,tabs:{onRemoved:event(),onUpdated:event()},runtime:{onMessage:event(),async sendNativeMessage(app,message){sent.push(message);return {ok:true}}}};
  vm.runInNewContext(read('background'),{browser:api,URL,Map});
  const sender={tab:{id:3},frameId:0,url:'https://www.youtube.com/watch?v=abcdefghijk'};
  assert.equal((await api.runtime.onMessage.fn({what:'play-youtube',url:sender.url,time:4},sender)).ok,true);
  assert.equal(sent[0].video,null);assert.equal(sent[0].time,4);
 }
}
async function content(site = 'https://www.youtube.com/watch?v=abcdefghijk'){
 let sent,pause=0,observer;const buttons=[];
 const host={classList:{contains(){return false}},append(b){b.isConnected=true;b.parentElement=this;buttons.push(b)}};
 const video={closest(){return host},currentTime:91.25,duration:Infinity,playbackRate:1.5,volume:0.4,muted:true,paused:false,videoHeight:1080,pause(){pause++}};
 const win={};win.top=win;
 const document={documentElement:{},title:'Owned video',querySelector(){return null},querySelectorAll(){return [video]},createElement(){return {dataset:{},style:{},addEventListener(kind,fn){this[kind]=fn}}}};
 vm.runInNewContext(read('content'),{window:win,document,navigator:{userAgent:'Owned browser'},location:new URL(site),URL,WeakMap,Number,Error,MutationObserver:class{constructor(fn){observer=fn}observe(){}},requestAnimationFrame(fn){fn()},setTimeout(){},fetch:async()=>({ok:false}),browser:{runtime:{async sendMessage(message){sent=message;return {ok:true}}}}});
 if(new URL(site).hostname==='example.com'){assert.equal(observer,undefined);assert.equal(buttons.length,0);return;}
 assert.equal(buttons.length,1);observer();assert.equal(buttons.length,1);
 await buttons[0].click({isTrusted:false});assert.equal(sent,undefined);
 await buttons[0].click({isTrusted:true,preventDefault(){},stopPropagation(){}});
 assert.equal(sent.time,91.25);assert.equal(sent.duration,0);assert.equal(sent.rate,1.5);assert.equal(sent.volume,0.4);assert.equal(sent.muted,true);assert.equal(pause,1);
 buttons[0].isConnected=false;observer();assert.equal(buttons.length,2);
}
(async()=>{await background();await backgroundWithoutWebRequest();await content();await content('https://example.com/');console.log('Browser integration: header capture, sender validation, SPA reset, trusted handoff and reinjection passed')})().catch(error=>{console.error(error);process.exitCode=1});
