#!/usr/bin/env node
// Dashboard UI tests: evaluate web/index.html's inline script under a stub DOM.
//
// Covers the §17.4 error surfacing (the renderer regression suite) plus Part A's
// banner/resume flow (T11) and the two-tab case (T12).
//
//     node tests/ui.test.js
//
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HTML = path.join(__dirname, '..', 'web', 'index.html');
const js = /<script>([\s\S]*)<\/script>/.exec(fs.readFileSync(HTML, 'utf8'))[1];

let fails = 0;
const ok = (cond, label) => {
  console.log((cond ? '    PASS ' : '    FAIL ') + label);
  if (!cond) fails++;
};

// --- a DOM small enough to reason about, honest enough to catch mistakes ----
class Elem {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.className = '';
    this._text = null; this._html = ''; this.style = {}; this.dataset = {};
    this.hidden = false; this._value = ''; this.checked = false;
    this.classList = {
      add: c => { if (!this.classList.contains(c)) this.className = (this.className + ' ' + c).trim(); },
      remove: c => { this.className = this.className.split(/\s+/).filter(x => x !== c && x).join(' '); },
      toggle: c => this.classList.contains(c) ? this.classList.remove(c) : this.classList.add(c),
      contains: c => this.className.split(/\s+/).includes(c),
    };
  }
  appendChild(c) { this.children.push(c); return c; }
  removeChild(c) { this.children = this.children.filter(x => x !== c); }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() {
    const own = (this._text != null) ? this._text : String(this._html || '').replace(/<[^>]*>/g, '');
    return own + this.children.map(c => c.textContent).join('');
  }
  set innerHTML(v) { this._html = String(v); }
  get innerHTML() { return this._html; }
  // A real <select> only displays a value an <option> carries, so the tests
  // assert on options as well; `value` itself stays a plain property here.
  get options() { return this.children.filter(c => c.tagName === 'option'); }
  addEventListener() {} removeEventListener() {} focus() {} blur() {}
  setAttribute() {} removeAttribute() {} getAttribute() { return null; }
  querySelector() { return null; } querySelectorAll() { return []; }
  closest() { return null; } contains() { return false; }
  scrollIntoView() {} insertBefore(c) { return this.appendChild(c); }
}

// One dashboard tab: its own DOM, its own routes, its own page instance.
function newTab() {
  const byId = {};
  const routes = {};
  const posts = [];
  const document = {
    createElement: t => new Elem(t),
    createTextNode: t => { const e = new Elem('#text'); e.textContent = t; return e; },
    getElementById: id => (byId[id] = byId[id] || new Elem('div')),
    querySelector: () => null, querySelectorAll: () => [],
    body: new Elem('body'), addEventListener() {},
  };
  const ctx = {
    document, console, setTimeout, clearTimeout, setInterval, clearInterval,
    JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Error, Promise,
    fetch: (url, opts = {}) => {
      const method = (opts.method || 'GET').toUpperCase();
      const p = String(url).split('?')[0];
      if (method === 'POST') posts.push({path: p, body: opts.body ? JSON.parse(opts.body) : null});
      const route = routes[method + ' ' + p] !== undefined ? routes[method + ' ' + p] : routes[p];
      const r = typeof route === 'function' ? route() : route;
      const status = (r && r.status) || 200;
      const body = r === undefined ? {} : (r && 'json' in r ? r.json : r);
      return Promise.resolve({ok: status < 300, status, json: () => Promise.resolve(body)});
    },
    EventSource: function () { return {addEventListener() {}, close() {}}; },
    location: {origin: 'http://x', protocol: 'http:', host: 'x'},
    localStorage: {getItem: () => null, setItem: () => {}, removeItem: () => {}},
    navigator: {userAgent: 'node'}, window: undefined, requestAnimationFrame: () => {},
    URLSearchParams, URL, TextEncoder, TextDecoder,
    encodeURIComponent, decodeURIComponent, parseInt, parseFloat, isNaN,
    Image: function () {}, Blob: function () {}, FileReader: function () {},
    AbortController: function () { this.abort = () => {}; this.signal = {}; },
    confirm: () => true, prompt: () => '', alert: () => {},
  };
  ctx.window = ctx; ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(js, ctx, {filename: 'index.html'});
  return {ctx, byId, routes, posts};
}
const tick = () => new Promise(r => setTimeout(r, 0));
const find = (node, cls, acc = []) => {
  if ((node.className || '').split(/\s+/).includes(cls)) acc.push(node);
  (node.children || []).forEach(c => find(c, cls, acc));
  return acc;
};

const BASE_ROUTES = (state) => ({
  '/state': () => ({json: state}),
  '/models': {models: [{provider: 'anthropic', id: 'claude-opus-4'}]},
  '/messages': {messages: []},
  '/session': {messages: []},
  '/sessions': {sessions: [
    {name: 'old.jsonl', dir: 'archive', title: 'Old session', active: false, mtime: 1},
    {name: 'live.jsonl', dir: 'sessions', title: 'Live', active: true, mtime: 2},
  ]},
});

// ===== §17.4: a failed run is visible ======================================
console.log('=== snapshot reload: errored assistant message is visible');
{
  const tab = newTab();
  const logEl = tab.byId['log'];
  const ERR = "Cannot find module '/x/dist/bundle/chunks/openai-completions-EKZT2IH2.js'";
  tab.ctx.renderSnapshot([
    {role: 'user', content: [{type: 'text', text: 'hello'}]},
    {role: 'assistant', content: [], stopReason: 'error', errorMessage: ERR},
  ], false);
  let errs = find(logEl, 'err');
  ok(errs.length === 1, 'exactly one .bubble.err rendered (got ' + errs.length + ')');
  ok(errs.length && errs[0].textContent.includes('agent error'), 'bubble has the ⚠ agent error heading');
  ok(errs.length && errs[0].textContent.includes('openai-completions-EKZT2IH2.js'), 'bubble carries the errorMessage text');
  ok(find(logEl, 'assistant').length === 1, 'an assistant message row exists for the empty-content error');
  ok(!logEl.textContent.includes('undefined'), 'no "undefined" leaked into the transcript');

  console.log('=== live stream: message_end with stopReason error');
  logEl.children = []; logEl.innerHTML = ''; logEl._text = null;
  tab.ctx.onEvent({data: JSON.stringify({type: 'agent_start'})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'message_start', message: {role: 'assistant', content: []}})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'message_update', assistantMessageEvent: {type: 'text_delta', delta: 'partial '}})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'message_end', message: {role: 'assistant', content: [], stopReason: 'error', errorMessage: ERR}})});
  errs = find(logEl, 'err');
  ok(errs.length === 1, 'live error bubble rendered (got ' + errs.length + ')');
  ok(logEl.textContent.includes('partial'), 'the partial text that streamed before the failure is kept');
  ok(errs.length && errs[0].textContent.includes('openai-completions-EKZT2IH2.js'), 'live bubble carries the errorMessage');

  console.log('=== regression: a healthy turn renders no error bubble');
  logEl.children = []; logEl.innerHTML = ''; logEl._text = null;
  tab.ctx.onEvent({data: JSON.stringify({type: 'agent_start'})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'message_start', message: {role: 'assistant', content: []}})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'message_update', assistantMessageEvent: {type: 'text_delta', delta: 'All good.'}})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'message_end', message: {role: 'assistant', content: [{type: 'text', text: 'All good.'}], stopReason: 'stop'}})});
  tab.ctx.onEvent({data: JSON.stringify({type: 'agent_settled'})});
  ok(find(logEl, 'err').length === 0, 'no error bubble on a successful run');
  ok(logEl.textContent.includes('All good.'), 'the answer still renders');
}

// ===== T11: the banner button resumes ======================================
(async () => {
  console.log('=== T11: banner → confirm → POST → live (B2 included)');
  const state = {model: {provider: 'anthropic', id: 'claude-opus-4'},
                 sessionName: 'live session', isStreaming: false};
  const tab = newTab();
  Object.assign(tab.routes, BASE_ROUTES(state));
  tab.routes['POST /opensession'] = () => ({
    json: {ok: true, newFile: '/s/old.jsonl', unarchived: true},
  });
  await tick();

  await tab.ctx.openSession({name: 'old.jsonl', dir: 'archive', title: 'Old session'});
  await tick();
  ok(tab.byId['banner'].hidden === false, 'viewing shows the banner');
  ok(tab.byId['foot'].hidden === true, 'and hides the composer');
  ok(vm.runInContext('viewing !== null', tab.ctx) === true, 'viewing is set');

  // the switch leaves pi on AGENT_MODEL, which /models does not even offer
  state.model = {provider: 'deepseek', id: 'deepseek-flash'};
  await tab.byId['bannerResume'].onclick();
  await tick();
  const post = tab.posts.find(p => p.path === '/opensession');
  ok(!!post, 'POSTed to /opensession');
  ok(JSON.stringify(post && post.body), JSON.stringify({file: 'old.jsonl', dir: 'archive'}),
     'with the file and dir that were being viewed');
  ok(tab.byId['banner'].hidden === true, 'banner hidden again');
  ok(tab.byId['foot'].hidden === false, 'composer is back');
  ok(vm.runInContext('viewing === null', tab.ctx) === true, 'viewing cleared');
  const key = 'deepseek|deepseek-flash';
  ok(tab.byId['modelSel'].options.some(o => o.value === key),
     'the dropdown gains an option for the model /state reports (B2)');
  ok(tab.byId['modelSel'].value === key, 'and selects it (B2)');

  console.log('=== T11b: a failed resume stays in view mode');
  const tab2 = newTab();
  Object.assign(tab2.routes, BASE_ROUTES(state));
  tab2.routes['POST /opensession'] = {status: 409, json: {error: 'a session with that file name already exists in sessions/'}};
  await tick();
  await tab2.ctx.openSession({name: 'old.jsonl', dir: 'archive', title: 'Old session'});
  await tab2.byId['bannerResume'].onclick();
  await tick();
  ok(tab2.byId['banner'].hidden === false, 'still in view mode');
  ok(vm.runInContext('viewing !== null', tab2.ctx) === true, 'viewing kept, so the user can retry');

  console.log('=== T11c: an old daemon without the endpoint says so');
  const tab3 = newTab();
  Object.assign(tab3.routes, BASE_ROUTES(state));
  tab3.routes['POST /opensession'] = {status: 404, json: {error: 'not found'}};
  await tick();
  await tab3.ctx.openSession({name: 'old.jsonl', dir: 'archive', title: 'Old session'});
  await tab3.byId['bannerResume'].onclick();
  await tick();
  ok(tab3.byId['banner'].hidden === false, 'stays in view mode');
  ok(tab3.byId['sbNote'].textContent.includes('daemon restart'), 'and says a restart is needed');

  // ===== T12: two tabs, one of them resumes what the other is viewing ======
  console.log('=== T12: another tab resumes the transcript this one is viewing (B7)');
  const stateA = {model: {provider: 'anthropic', id: 'claude-opus-4'},
                  sessionName: 'live session', isStreaming: false};
  const A = newTab();
  Object.assign(A.routes, BASE_ROUTES(stateA));
  await tick();
  await A.ctx.openSession({name: 'old.jsonl', dir: 'archive', title: 'Old session'});
  ok(A.byId['banner'].hidden === false, 'A is viewing');

  const B = newTab();
  Object.assign(B.routes, BASE_ROUTES(stateA));
  B.routes['POST /opensession'] = {json: {ok: true, newFile: '/s/sessions/old.jsonl', unarchived: true}};
  await tick();
  await B.ctx.openSession({name: 'old.jsonl', dir: 'archive', title: 'Old session'});
  await B.byId['bannerResume'].onclick();
  await tick();

  // B's switch arrives on A's stream
  A.ctx.onEvent({data: JSON.stringify({type: 'session_switched', newFile: '/s/sessions/old.jsonl'})});
  await tick();
  ok(A.byId['banner'].hidden === true, 'A left view mode (B7)');
  ok(A.byId['foot'].hidden === false, 'A shows the composer again');
  ok(vm.runInContext('viewing === null', A.ctx) === true, 'A cleared viewing');

  console.log('=== T12b: an unrelated switch does not disturb a viewer');
  const C = newTab();
  Object.assign(C.routes, BASE_ROUTES(stateA));
  await tick();
  await C.ctx.openSession({name: 'old.jsonl', dir: 'archive', title: 'Old session'});
  C.ctx.onEvent({data: JSON.stringify({type: 'session_switched', newFile: '/s/sessions/something-else.jsonl'})});
  await tick();
  ok(C.byId['banner'].hidden === false, 'C keeps viewing its own transcript');
  ok(vm.runInContext('viewing !== null', C.ctx) === true, 'and keeps viewing state');

  console.log('=== B5: an un-archived session is not listed under Archived twice');
  const D = newTab();
  Object.assign(D.routes, BASE_ROUTES(stateA));
  D.routes['/sessions'] = {sessions: [
    {name: 'old.jsonl', dir: 'archive', title: 'Old session', active: true, mtime: 3},
  ]};
  await tick();
  const groups = D.byId['sessList'].children.filter(c => (c.className || '').includes('sb-group'));
  const labels = groups.map(g => g.textContent);
  ok(!labels.includes('Archived'), 'an active archive-flagged file is not shown as Archived');
  ok(labels.includes('Running'), 'it is shown as Running instead');

  console.log();
  if (fails) { console.log(fails + ' FAILURES'); process.exit(1); }
  console.log('ALL PASS');
})();
