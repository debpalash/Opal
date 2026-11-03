// Bounded metadata recognition shared by the page script and its tests.
(() => {
  const clean = value => typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g,' ').replace(/\s+/g,' ').trim().slice(0,512) : '';
  const type = value => (Array.isArray(value)?value:[value]).map(v=>clean(v).split(/[\/#]/).pop().toLowerCase());
  const yearOf = value => {const n=Number(String(value||'').match(/(?:18|19|20|21)\d{2}/)?.[0]);return n||null};
  const publisherSite = url => {try{return ['marvel.com','dc.com','imagecomics.com','darkhorse.com'].includes(new URL(url).hostname.toLowerCase().replace(/^www\./,''))}catch{return false}};
  function name(value) {
    let title=clean(value).replace(/\s*\|.*$/,'').replace(/\s+[-–—]\s+(?:Marvel|DC|Image Comics|Dark Horse).*$/i,'');
    const year=yearOf(title.match(/\((\d{4})(?:[^)]*)\)/)?.[1]);
    const issue=title.match(/(?:#|\bissue\s+)(\d+(?:\.\d+)?)/i)?.[1] ?? null;
    const series=title.replace(/\s*\(\d{4}[^)]*\).*$/,'').replace(/\s*(?:#|\bissue\s+)\d+(?:\.\d+)?.*$/i,'').trim();
    return {series,title,year,issue:issue===null?null:Number(issue)};
  }
  function publisher(url) {
    let u;try{u=new URL(url)}catch{return null}
    if(!/^https?:$/.test(u.protocol))return null;
    const host=u.hostname.toLowerCase().replace(/^www\./,'');
    let path;try{path=decodeURIComponent(u.pathname)}catch{return null}
    if(host==='marvel.com') {
      const m=path.match(/^\/comics\/(issue|series)\/\d+\/([^/]+)(?:\/variant)?\/?$/i);if(!m)return null;
      let raw=m[2].replace(/_variant$/i,'');const bits=raw.match(/^(.*)_(\d{4})_(\d+(?:\.\d+)?)$/);
      const volume=m[1]==='series'?raw.match(/^(.*)_(\d{4})_(?:present|\d{4})$/i):null;
      const result=volume?{series:volume[1].replace(/_/g,' '),title:`${volume[1].replace(/_/g,' ')} (${volume[2]})`,year:Number(volume[2]),issue:null}:bits?{series:bits[1].replace(/_/g,' '),title:'',year:Number(bits[2]),issue:Number(bits[3])}:name(raw.replace(/_/g,' '));
      if(!result.title)result.title=`${result.series} (${result.year}) #${result.issue}`;
      return {...result,publisher:'Marvel',kind:m[1]==='issue'?'comic_issue':'comic_series'};
    }
    const publishers={'dc.com':'DC','imagecomics.com':'Image Comics','darkhorse.com':'Dark Horse'};
    if(publishers[host] && /^(?:\/comics\/(?:releases\/)?[^/]+|\/Comics\/[^/]+)(?:\/|$)/.test(path)) return {publisher:publishers[host],kind:null};
    return null;
  }
  function detect(input) {
    const known=publisher(input.url);const nodes=[];const queue=(input.structured||[]).slice(0,16);
    for(let visited=0;queue.length && visited<256;visited++) {
      let value=queue.shift();if(typeof value==='string'){if(value.length>131072)continue;try{value=JSON.parse(value)}catch{continue}}
      if(Array.isArray(value)){queue.push(...value.slice(0,64));continue}
      if(!value||typeof value!=='object')continue;
      nodes.push(value);for(const key of ['@graph','mainEntity','mainEntityOfPage'])if(value[key])queue.push(value[key]);
    }
    const comic=nodes.find(n=>type(n['@type']).some(t=>t==='comicissue'||t==='comicseries'));
    const book=nodes.find(n=>type(n['@type']).includes('book')&&/comic|graphic novel|manga/i.test(clean(Array.isArray(n.genre)?n.genre.join(' '):n.genre)));
    const structured=comic||book;
    const ogType=clean(input.ogType).toLowerCase();
    const explicit=/^(comic|comicbook|comic\.issue|comic\.series)$/.test(ogType);
    if(!known?.series&&!explicit&&nodes.some(n=>type(n['@type']).some(t=>['itemlist','collectionpage','searchresultspage'].includes(t))))return null;
    if(!known?.series&&!explicit&&nodes.some(n=>type(n['@type']).some(t=>['article','newsarticle','blogposting'].includes(t))))return null;
    if(!known&&!structured&&!explicit)return null;
    const heading=name(input.heading||input.ogTitle||input.title);
    let parent=structured?.partOfSeries||structured?.isPartOf;
    if(Array.isArray(parent))parent=parent[0];
    if(parent?.['@id']&&!parent.name)parent=nodes.find(n=>n['@id']===parent['@id'])||parent;
    const fallback=known?.series?known:null;
    const named=name(structured?.name||structured?.headline||((heading.year||heading.issue!==null)?heading.title:fallback?.title||heading.title));
    const parentName=name(parent?.name);
    const series=clean(parentName.series||named.series||fallback?.series).slice(0,255);
    if(!series||/^\d+$/.test(series))return null;
    const kind=type(structured?.['@type']).includes('comicseries')||known?.kind==='comic_series'||ogType==='comic.series'?'comic_series':'comic_issue';
    const rawIssue=structured?.issueNumber??named.issue??fallback?.issue;
    const issue=rawIssue===null||rawIssue===undefined?null:Number(rawIssue);
    if(issue!==null&&(!Number.isFinite(issue)||issue<0||issue>100000))return null;
    if(!structured&&!explicit&&!known?.series&&kind==='comic_issue'&&issue===null)return null;
    const year=named.year||parentName.year||fallback?.year||yearOf(parent?.startDate)||yearOf(structured?.datePublished);
    // Wait out SPA transitions instead of handing off an old heading/schema
    // under a newly selected publisher issue URL.
    if(fallback?.year&&year!==fallback.year)return null;
    if(fallback?.kind==='comic_issue'&&fallback.issue!==null&&issue!==null&&fallback.issue!==issue)return null;
    const publisherName=clean(structured?.publisher?.name||structured?.publisher||known?.publisher).slice(0,64);
    return {kind,series,title:clean(named.title||fallback?.title||series),year,issue,publisher:publisherName,confidence:structured?95:known?90:85,signals:[...(known?['publisher_url']:[]),...(structured?['structured_comic']:[]),...(heading.issue!==null?['issue_heading']:[]),...(explicit?['comic_meta']:[])]};
  }
  function snapshot(document,url) {
    const meta=key=>document.querySelector(`meta[property="${key}"],meta[name="${key}"]`)?.content||'';
    const structured=Array.from(document.querySelectorAll('script[type="application/ld+json"]')).slice(0,16).map(n=>(n.textContent||'').slice(0,131073));
    return {url,title:document.title,heading:document.querySelector('main h1,article h1,h1')?.textContent||'',ogTitle:meta('og:title'),ogType:meta('og:type'),structured};
  }
  function command(message,senderURL) {
    try {
      const url=new URL(message.url),sender=new URL(senderURL);
      if(!/^https?:$/.test(url.protocol)||url.origin!==sender.origin||url.pathname!==sender.pathname||url.search!==sender.search)return null;
      if(!['comic_issue','comic_series'].includes(message.kind)||!Number.isInteger(message.confidence)||message.confidence<80||message.confidence>100)return null;
      const series=clean(message.series);if(!series||series.length>255||message.series!==series)return null;
      const year=message.year??null,issue=message.issue??null;
      if(year!==null&&(!Number.isInteger(year)||year<1800||year>2199))return null;
      if(issue!==null&&(typeof issue!=='number'||!Number.isFinite(issue)||issue<0||issue>100000))return null;
      return {what:'read-comic',url:sender.href,kind:message.kind,series,title:clean(message.title)||series,year,issue,publisher:clean(message.publisher).slice(0,64),confidence:message.confidence};
    }catch{return null}
  }
  globalThis.OpalComicDetection=Object.freeze({detect,snapshot,command,publisher,publisherSite});
})();
