const api = globalThis.browser;
const pending = new Map(), streams = new Map();
const isYouTube = url => {try{return /(^|\.)youtube\.com$/i.test(new URL(url).hostname)}catch{return false}};
const videoId = url => {try{const u=new URL(url);return u.searchParams.get('v')||u.pathname.match(/^\/(?:shorts|live|embed)\/([\w-]{11})/)?.[1]||''}catch{return ''}};
const useful = headers => (headers||[]).filter(h=>h.value && !/^(host|connection|content-length|range|accept-encoding|proxy-authorization)$/i.test(h.name));
function sent(d){
 if(d.tabId<0)return;
 let u;try{u=new URL(d.url)}catch{return}
 if(!/(^|\.)googlevideo\.com$/i.test(u.hostname)||u.pathname!='/videoplayback')return;
 pending.set(d.requestId,{url:d.url,headers:useful(d.requestHeaders),tabId:d.tabId});
 if(pending.size>128)pending.delete(pending.keys().next().value);
}
// macOS 15 WebKit refuses webRequest in non-persistent (MV3) backgrounds; keep
// favicons, comic handoff and plain YouTube handoff working without capture.
function listen(){
try{api.webRequest.onSendHeaders.addListener(sent,{urls:['https://*.googlevideo.com/*']},['requestHeaders','extraHeaders'])}
catch{api.webRequest.onSendHeaders.addListener(sent,{urls:['https://*.googlevideo.com/*']},['requestHeaders'])}
api.webRequest.onHeadersReceived.addListener(async d=>{
 const item=pending.get(d.requestId);pending.delete(d.requestId);if(!item||d.statusCode<200||d.statusCode>=300)return;
 const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
 if(!/^(video|audio)\//i.test(mime))return;
 try{
  const tab=await api.tabs.get(d.tabId);if(!isYouTube(tab.url))return;
  const state=streams.get(d.tabId)||{};state[mime.startsWith('audio/')?'audio':'video']={...item,page:tab.url,mime};streams.set(d.tabId,state);
 }catch{}
},{urls:['https://*.googlevideo.com/*']},['responseHeaders']);
}
try{if(api.webRequest)listen()}catch{}
api.tabs.onRemoved.addListener(id=>streams.delete(id));
api.tabs.onUpdated.addListener((id,change)=>{if(change.url)streams.delete(id)});
api.runtime.onMessage.addListener(async (message,sender)=>{
 if(!sender.tab || sender.frameId!==0)return {ok:false};
 if(message.what==='read-comic'){
  const command=globalThis.OpalComicDetection?.command(message,sender.url);
  return command?api.runtime.sendNativeMessage('opal.browser',command):{ok:false};
 }
 if(message.what==='favicon')return api.runtime.sendNativeMessage('opal.browser',{what:'favicon',url:sender.url,data:message.data});
 if(message.what!=='play-youtube'||!isYouTube(sender.url)||videoId(sender.url)!==videoId(message.url)||videoId(message.url).length!==11)return {ok:false};
 const state=streams.get(sender.tab.id)||{};
 const capture=part=>part&&videoId(part.page)===videoId(message.url)?{url:part.url,headers:part.headers,mime:part.mime}:null;
 return api.runtime.sendNativeMessage('opal.browser',{...message,video:capture(state.video),audio:capture(state.audio)});
});
