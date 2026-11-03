// Runs in an isolated WebKit content world. No browsing URLs leave the view.
(() => {
  const policy = __OPAL_POLICY__;
  let bytes = 0, ads = 0, trackers = 0;
  const send = () => {
    if (!(bytes || ads || trackers)) return;
    window.webkit.messageHandlers.opalPrivacy.postMessage({bytes, ads, trackers});
    bytes = ads = trackers = 0;
  };
  const hostMatches = (host, names) => names.some(name => host === name || host.endsWith('.' + name));
  // Count errors only for domains covered by the installed native block rules.
  // This is an observed subset, not a claim to count every blocked request.
  addEventListener('error', event => {
    const target = event.target;
    if (!target || target === window) return;
    try {
      const host = new URL(target.currentSrc || target.src || target.href, location.href).hostname;
      if (policy.block_ads && hostMatches(host, policy.ad_domains)) ads++;
      else if (policy.block_trackers && hostMatches(host, policy.tracker_domains)) trackers++;
    } catch (_) {}
  }, true);
  if (typeof PerformanceObserver === 'function') {
    for (const type of ['resource', 'navigation']) {
      if (type === 'navigation' && window !== window.top) continue;
      try {
        const observer = new PerformanceObserver(list => {
          for (const entry of list.getEntries()) {
            const size = Number(entry.transferSize);
            if (Number.isFinite(size) && size > 0) bytes += size;
          }
        });
        observer.observe({type, buffered: true});
      } catch (_) {}
    }
  }
  setInterval(send, 3000);
  addEventListener('pagehide', send);
})();
