// Deterministic request/timer races against the complete production scripts.
// Run: node --test tests/test_web_lifecycle.mjs
// To confirm regressions against a previous revision: OPAL_WEB_REVISION=HEAD node --test ...
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import test from 'node:test';
import {performance} from 'node:perf_hooks';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = file => process.env.OPAL_WEB_REVISION
  ? execFileSync('git', ['show', `${process.env.OPAL_WEB_REVISION}:web/js/${file}`], {cwd:root, encoding:'utf8'})
  : readFileSync(new URL(`../web/js/${file}`, import.meta.url), 'utf8');
const flush = async () => { for (let i = 0; i < 12; ++i) await Promise.resolve(); };

function fixture(...files){
  class Element {
    constructor(){
      this.listeners = new Map(); this.dataset = {}; this.attributes = new Map();
      this.style = {removeProperty(){}, setProperty(){}};
      this.textContent = ''; this.value = ''; this.hidden = false; this._html = '';
      const classes = new Set();
      this.classList = {
        add: value => classes.add(value), remove: value => classes.delete(value),
        contains: value => classes.has(value),
        toggle(value, force){
          if (force ?? !classes.has(value)) { classes.add(value); return true; }
          classes.delete(value); return false;
        },
      };
    }
    get innerHTML(){ return this._html; }
    set innerHTML(value){ this._html = value; this.textContent = ''; }
    addEventListener(name, fn){ this.listeners.set(name, fn); }
    querySelectorAll(){ return []; }
    querySelector(){ return new Element(); }
    setAttribute(name, value){ this.attributes.set(name, value); }
    removeAttribute(name){ this.attributes.delete(name); }
    replaceChildren(...children){ this.children = children; }
    toggleAttribute(name, value){ value ? this.setAttribute(name, '') : this.removeAttribute(name); }
    focus(){}
    insertAdjacentHTML(){}
  }
  const elements = new Map(), requests = [], timers = new Map(), sources = [], rendered = [], network = [], observers = [];
  let nextTimer = 0;
  const $ = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
  const request = path => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    requests.push({path, resolve, reject, taken:false}); return promise;
  };
  const window = new Element();
  window.navigator = {};
  const context = vm.createContext({
    $, Element, BASE:'http://fixture.invalid', AUTHENTICATED:true,
    api:request, apiMutation:request, esc:String, lastHtml:{},
    URL, URLSearchParams, console, rendered, network, performance,
    requestAnimationFrame:fn => { fn(); return 1; },
    PerformanceObserver:class {
      constructor(callback){ this.callback = callback; observers.push(this); }
      observe(options){ this.type = options.type; }
    },
    setNetworkState: state => network.push(state),
    setTimeout(fn, ms){ const id = ++nextTimer; timers.set(id, {fn, ms}); return id; },
    clearTimeout:id => timers.delete(id),
    setInterval(){ throw new Error('Unexpected interval in this lifecycle fixture'); }, clearInterval(){},
    EventSource:class {
      constructor(url){ this.url = url; this.closed = false; sources.push(this); }
      close(){ this.closed = true; }
    },
    document:{getElementById:$, querySelectorAll:() => [], createElement:() => new Element(), addEventListener(){}, body:new Element()},
    location:{origin:'http://fixture.invalid', hash:'', hostname:'fixture.invalid'},
    localStorage:{getItem:() => '', removeItem(){}}, history:{},
    navigator:{onLine:true}, window,
    matchMedia:() => ({matches:false, addEventListener(){}}),
    fetch: async () => ({json:async () => ({})}),
    toast(){},
  });
  for (const file of files) vm.runInContext(source(file), context, {filename:file});
  const run = code => vm.runInContext(code, context);
  const take = path => {
    const found = requests.find(r => !r.taken && r.path === path);
    assert.ok(found, `Missing request ${path}; pending: ${requests.filter(r => !r.taken).map(r => r.path)}`);
    found.taken = true; return found;
  };
  return {$, run, take, requests, timers, sources, rendered, network, observers, window};
}

test('web performance budget produces a measured pass and failure', () => {
  const f = fixture('core.js');
  f.run('webPerf.shellReady()');
  const event = f.observers.find(observer => observer.type === 'event');
  const longTask = f.observers.find(observer => observer.type === 'longtask');
  event.callback({getEntries:() => [20, 30, 40, 50, 60].map(duration => ({duration}))});
  longTask.callback({getEntries:() => [{duration:80}]});
  assert.equal(f.run('webPerf.summary().within_budget'), true);
  event.callback({getEntries:() => [{duration:180}]});
  assert.equal(f.run('webPerf.summary().within_budget'), false);
});

test('anime paging uses the shared browse loader and renders rich cards', async () => {
  const f = fixture('media.js');
  f.run(`
    currentPage = 'anime';
    $('anime-more').style.display = '';
    renderAnimeResults([{name:'Frieren', poster:'https://img.invalid/f.jpg', type:'TV',
      year:2023, score:9.3, episodes:28, overview:'Journey'}]);
  `);
  assert.match(f.$('anime-results').innerHTML, /<img/);
  assert.match(f.$('anime-results').innerHTML, /2023/);
  assert.match(f.$('anime-results').innerHTML, /9\.3/);

  const action = f.$('anime-more').onclick();
  f.take('/anime/more').resolve({ok:true});
  await flush();
  const timer = [...f.timers.values()][0];
  assert.ok(timer, 'paging should wait briefly for the worker result');
  timer.fn();
  await flush();
  f.take('/anime').resolve({loading_more:false, has_more:false, results:[], episodes:[]});
  await action;
  assert.equal(f.$('anime-more').disabled, false);
});

test('late show metadata cannot overwrite a different show or start its seasons', async () => {
  const f = fixture('catalog.js');
  const old = f.run("openShow(1, 'Old show', '')");
  const latest = f.run("openShow(2, 'New show', '')");
  f.take('/tv?id=2').resolve({first_air_date:'2026-01-01', seasons:[], overview:'New overview'});
  await latest;
  f.take('/tv?id=1').resolve({first_air_date:'1990-01-01', seasons:[{season_number:1}], overview:'Old overview'});
  await old;
  assert.equal(f.$('show-overview').textContent, 'New overview');
  assert.match(f.$('show-meta').textContent, /2026/);
  assert.equal(f.requests.filter(r => r.path.includes('&season=')).length, 0);
  assert.equal(f.requests.filter(r => r.path === '/tv/recent?id=1').length, 0);
});

test('season selection owns its rows even when previous season resolves last', async () => {
  const f = fixture('catalog.js');
  const show = f.run("openShow(7, 'The Show', '')");
  f.take('/tv?id=7').resolve({seasons:[]}); await show;
  const old = f.run('loadSeason(1)'), latest = f.run('loadSeason(2)');
  f.take('/tv?id=7&season=2').resolve({episodes:[{episode_number:4, name:'New episode'}]});
  f.take('/library/watched?kind=tv&id=7&season=2').resolve({episodes:[4]});
  await latest;
  f.take('/tv?id=7&season=1').resolve({episodes:[{episode_number:9, name:'Old episode'}]});
  f.take('/library/watched?kind=tv&id=7&season=1').resolve({episodes:[]}); await old;
  assert.match(f.$('episodes').innerHTML, /New episode/);
  assert.doesNotMatch(f.$('episodes').innerHTML, /Old episode/);
  assert.match(f.$('episodes').innerHTML, /data-show="7"/);
  assert.match(f.$('episodes').innerHTML, /the show s02e04/);
});

test('a dismissed detail request cannot populate hidden metadata', async () => {
  const f = fixture('catalog.js');
  const request = f.run("openShow(1, 'Closed show', '')");
  f.$('show-back').onclick();
  f.take('/tv?id=1').resolve({seasons:[], overview:'Too late'}); await request;
  assert.equal(f.$('show-page').classList.contains('on'), false);
  assert.equal(f.$('show-overview').textContent, '');
  assert.equal(f.requests.length, 1);
});

test('old movie errors cannot replace a newly loaded movie detail', async () => {
  const f = fixture('catalog.js');
  const old = f.run("openMovie(1, 'Old')"), latest = f.run("openMovie(2, 'New')");
  f.take('/movie?id=2').resolve({title:'New movie', runtime:99}); await latest;
  f.take('/movie?id=1').reject(new Error('Late timeout')); await old;
  assert.equal(f.$('show-meta').textContent, '99 min');
  assert.equal(f.$('show-title').textContent, 'New movie');
});

test('old latest-episode responses cannot cross show boundaries', async () => {
  const f = fixture('catalog.js');
  const first = f.run("openShow(1, 'Old show', '')");
  f.take('/tv?id=1').resolve({seasons:[]}); await first;
  const second = f.run("openShow(2, 'New show', '')");
  f.take('/tv?id=2').resolve({seasons:[]}); await second;
  f.take('/tv/recent?id=2').resolve({found:true, season:2, episode:4, label:'S02E04 · New', watched:false});
  await flush();
  f.take('/tv/recent?id=1').resolve({found:true, season:1, episode:9, label:'S01E09 · Old', watched:false});
  await flush();
  assert.match(f.$('show-latest').innerHTML, /new show s02e04/);
  assert.doesNotMatch(f.$('show-latest').innerHTML, /s01e09/);
});

test('a stale episode control cannot mark the newly selected show watched', async () => {
  const f = fixture('catalog.js');
  f.run("openShow(1, 'Old show', '')");
  const generation = f.run("typeof detailsGeneration === 'number' ? detailsGeneration : 0");
  f.run("openShow(2, 'New show', '')");
  const button = {dataset:{action:'watched', show:'1', details:String(generation), season:'1', episode:'4', value:'true'}};
  const handler = f.$('episodes').listeners.get('click');
  // Do not await a possible buggy mutation: its presence is the failure.
  handler({target:{closest:() => button}});
  assert.equal(f.requests.filter(r => r.path.startsWith('/library/action')).length, 0);
});

test('a watched mutation finishing after navigation cannot refresh the next show', async () => {
  const f = fixture('catalog.js');
  const show = f.run("openShow(1, 'Old show', '')");
  f.take('/tv?id=1').resolve({seasons:[]}); await show;
  const generation = f.run("typeof detailsGeneration === 'number' ? detailsGeneration : 0");
  const button = {dataset:{action:'watched', show:'1', details:String(generation), season:'1', episode:'4', value:'true'}};
  const mutation = f.$('episodes').listeners.get('click')({target:{closest:() => button}});
  const request = f.take('/library/action?action=watched&kind=tv&id=1&season=1&episode=4&value=true');
  f.run("openShow(2, 'New show', '')");
  const count = f.requests.length;
  request.resolve({ok:true}); await mutation;
  assert.equal(f.requests.length, count);
});

function statusFixture(){
  const f = fixture('now-playing.js');
  f.run('applyStatus = status => rendered.push(status)');
  return f;
}

test('fatal playback status exposes one retry through the typed action route', async () => {
  const f = fixture('now-playing.js');
  f.run(`
    $('i-pp').firstElementChild = new Element();
    applyStatus({active:true,title:'Broken media',error:'Decoder unavailable',retryable:true,
      pos:0,dur:0,vol:100,paused:true,loading:false,buffering:false});
  `);
  assert.equal(f.$('np-error').hidden, false);
  assert.equal(f.$('np-error-text').textContent, 'Decoder unavailable');
  assert.equal(f.$('np-retry').disabled, false);

  const retry = f.$('np-retry').onclick();
  assert.equal(f.$('np-retry').disabled, true);
  f.take('/player/action?action=retry').resolve({ok:true});
  await retry;
  assert.equal(f.$('np-retry').disabled, false);
  assert.equal(f.$('np-retry').textContent, 'Try again');

  f.run(`applyStatus({active:true,title:'Recovered',error:'',retryable:false,
    pos:1,dur:10,vol:100,paused:false,loading:false,buffering:false})`);
  assert.equal(f.$('np-error').hidden, true);
});

test('fallback polling has at most one in-flight request', async () => {
  const f = statusFixture();
  f.run('startStatus()'); f.sources[0].onerror();
  f.run('poll()'); f.run('poll()');
  assert.equal(f.requests.length, 1);
  f.take('/status').resolve({title:'Playing'}); await flush();
  assert.equal(f.timers.size, 1);
  assert.equal(f.rendered.length, 1);
});

test('restarting SSE cancels the old fallback timer and stale source events', async () => {
  const f = statusFixture();
  f.run('startStatus()'); f.sources[0].onerror();
  f.take('/status').resolve({title:'Old status'}); await flush();
  f.run('startStatus()');
  assert.equal(f.timers.size, 0);
  f.sources[0].onerror();
  f.sources[0].onmessage({data:'{"title":"Stale event"}'});
  assert.equal(f.sources[1].closed, false);
  assert.equal(f.requests.length, 1);
  assert.equal(f.rendered.length, 1);
});

test('late fallback responses cannot paint or schedule alongside a new SSE stream', async () => {
  const f = statusFixture();
  f.run('startStatus()'); f.sources[0].onerror();
  f.run('startStatus()');
  f.sources[1].onmessage({data:'{"title":"Current stream"}'});
  f.take('/status').resolve({title:'Stale fallback'}); await flush();
  assert.deepEqual(f.rendered.map(d => d.title), ['Current stream']);
  assert.equal(f.timers.size, 0);
  assert.equal(f.network.at(-1), true);
});

test('sign-out invalidates in-flight status work and cannot restart the stream', async () => {
  const f = statusFixture();
  f.run('startStatus()'); f.sources[0].onerror();
  f.run('AUTHENTICATED = false; stopStatus()');
  f.take('/status').resolve({title:'Private old session'}); await flush();
  f.run('startStatus()');
  assert.equal(f.rendered.length, 0);
  assert.equal(f.timers.size, 0);
  assert.equal(f.sources.length, 1);
});

test('authentication and online recovery invoke the owned status lifecycle', () => {
  const f = fixture('core.js');
  f.run(`
    var starts = 0, stops = 0, pageStops = 0;
    function startStatus(){ ++starts; }
    function stopStatus(){ ++stops; }
    function poll(){ throw new Error('Online recovery bypassed the SSE lifecycle'); }
    stopPageWork = () => { ++pageStops; };
    showAuth = () => {};
    AUTHENTICATED = true;
  `);
  f.window.listeners.get('online')();
  assert.equal(f.run('starts'), 1);
  f.run('unpair()');
  assert.equal(f.run('stops'), 1);
  assert.equal(f.run('pageStops'), 1);
  f.window.listeners.get('online')();
  assert.equal(f.run('starts'), 1);
});
