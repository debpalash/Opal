const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const policy = {block_ads:true,block_trackers:true,ad_domains:['ads.example'],tracker_domains:['tracker.example']};
const source = fs.readFileSync('src/services/browser_security.js','utf8').replace('__OPAL_POLICY__',JSON.stringify(policy));
function fixture(frame = false) {
  const listeners = new Map(), observers = new Map(), messages = [];
  let flush;
  const sandbox = {
    location:{href:'https://owned.example/'},URL,Number,
    addEventListener(name,fn){listeners.set(name,fn)},
    setInterval(fn){flush=fn},
    PerformanceObserver:class {constructor(fn){this.fn=fn}observe({type}){observers.set(type,this.fn)}},
    webkit:{messageHandlers:{opalPrivacy:{postMessage(data){messages.push({...data})}}}},
  };
  sandbox.window=sandbox;sandbox.top=frame?{}:sandbox;
  vm.runInNewContext(source,sandbox);
  return {listeners,observers,messages,flush:()=>flush()};
}
const f=fixture();
f.flush();assert.equal(f.messages.length,0);
f.observers.get('resource')({getEntries:()=>[{transferSize:400},{transferSize:0},{transferSize:NaN}]});
f.observers.get('navigation')({getEntries:()=>[{transferSize:800}]});
f.listeners.get('error')({target:{src:'https://sub.ads.example/pixel'}});
f.listeners.get('error')({target:{src:'https://tracker.example/event'}});
f.listeners.get('error')({target:{src:'https://ads.example.evil/image'}});
f.listeners.get('error')({target:{src:'https://unrelated.example/missing'}});
f.flush();
assert.deepEqual(f.messages,[{bytes:1200,ads:1,trackers:1}]);
assert.deepEqual(Object.keys(f.messages[0]).sort(),['ads','bytes','trackers']);
f.flush();assert.equal(f.messages.length,1,'do not count the same entries a second time');
const child=fixture(true);assert.equal(child.observers.has('navigation'),false,'parent accounts for frame navigation');
child.observers.get('resource')({getEntries:()=>[{transferSize:90}]});
child.listeners.get('pagehide')();assert.deepEqual(child.messages,[{bytes:90,ads:0,trackers:0}]);
console.log('PASS: measured transfer sizes, exact host matching, no duplicate deltas or cross-frame navigation, numeric-only messages');
