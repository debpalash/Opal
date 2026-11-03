(() => {
  if (window.top !== window) return;
  const api = globalThis.browser;
  const youtube = () => /(^|\.)youtube\.com$/i.test(location.hostname);
  const media = new WeakMap();
  let scheduled = false;
  async function favicon() {
    try {
      const advertised = document.querySelector('link[rel~="icon"]')?.href;
      let url = new URL(advertised || '/favicon.ico', location.href);
      if (url.origin !== location.origin) url = new URL('/favicon.ico', location.href);
      const response = await fetch(url.href, {credentials:'same-origin'});
      if (!response.ok) return;
      if (Number(response.headers.get('content-length')) > 65536) return;
      const reader = response.body.getReader(); const chunks = []; let total = 0;
      for (;;) { const {done,value} = await reader.read(); if(done)break; total+=value.length;if(total>65536){await reader.cancel();return}chunks.push(value); }
      let raw='';for(const chunk of chunks)for(const byte of chunk)raw+=String.fromCharCode(byte);
      await api.runtime.sendMessage({what:'favicon',data:btoa(raw)});
    } catch (_) {}
  }
  function enhance() {
    scheduled = false;
    if (!youtube()) return;
    for (const video of document.querySelectorAll('video')) {
      const host = video.closest('.html5-video-player');
      if (!host) continue;
      const existing = media.get(video);
      if (existing?.isConnected && existing.parentElement === host) {existing.hidden=host.classList.contains('ad-showing');continue;}
      const button = document.createElement('button');
      button.type='button';button.dataset.opalPlay='true';button.textContent='Play in Opal';
      button.title='Continue this video in Opal from the current position';
      button.style.cssText='position:absolute;top:12px;left:12px;z-index:2147483646;padding:9px 13px;border-radius:8px;border:1px solid currentColor;background:var(--yt-spec-raised-background,Canvas);color:var(--yt-spec-text-primary,CanvasText);font:600 13px system-ui;cursor:pointer;box-shadow:0 2px 10px #0004;opacity:.96';
      host.append(button);media.set(video,button);button.hidden=host.classList.contains('ad-showing');
      button.addEventListener('click',async event => {
        if (!event.isTrusted) return;
        event.preventDefault();event.stopPropagation();button.disabled=true;button.textContent='Opening in Opal…';
        try {
          const reply = await api.runtime.sendMessage({what:'play-youtube',url:location.href,title:document.title,time:video.currentTime,duration:Number.isFinite(video.duration)?video.duration:0,rate:video.playbackRate,volume:video.volume,muted:video.muted,paused:video.paused,height:video.videoHeight,userAgent:navigator.userAgent});
          if (!reply?.ok) throw new Error(reply?.error || 'handoff failed');
          video.pause();button.textContent='Opened in Opal';
        } catch (_) {button.textContent='Try Play in Opal again';}
        setTimeout(()=>{button.disabled=false;button.textContent='Play in Opal'},2200);
      });
    }
  }
  if (youtube()) {
    const observer = new MutationObserver(()=>{if(!scheduled){scheduled=true;requestAnimationFrame(enhance)}});
    observer.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});
    enhance();
  }
  void favicon();
})();
