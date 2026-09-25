#!/usr/bin/env node
// §8.4 (L2/L3): the tool rows, exercised against a stub DOM.
//
// This is not the fake-pi harness — there is no daemon and no stream. It loads
// the two pure-ish blocks out of web/index.html and drives the row events in
// the order pi really delivers them, which is where L2 (parallel calls sharing
// one pointer) and L3 (live and reloaded rendering differently) actually live.
//
//     node tests/toolRows.test.js
//
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// --- the smallest DOM that the row code touches -----------------------------
function makeEl(tag) {
  const e = {
    tagName: tag, className: '', children: [], dataset: {}, parent: null,
    _text: '',
    appendChild(c) { c.parent = e; e.children.push(c); return c; },
    get textContent() {
      return e.children.length ? e.children.map(c => c.textContent).join('') : e._text;
    },
    set textContent(v) { e._text = String(v); e.children = []; },
    set innerHTML(v) { if (v !== '') throw new Error('stub innerHTML'); e.children = []; e._text = ''; },
    querySelector(sel) {
      const cls = sel.replace(/^\./, '');
      for (const c of e.children) {
        if (c.className.split(/\s+/).includes(cls)) return c;
        const deep = c.querySelector(sel);
        if (deep) return deep;
      }
      return null;
    },
    classList: {
      add: c => { if (!e.classList.contains(c)) e.className = (e.className + ' ' + c).trim(); },
      remove: c => { e.className = e.className.split(/\s+/).filter(x => x !== c && x).join(' '); },
      contains: c => e.className.split(/\s+/).includes(c),
    },
  };
  return e;
}
const document = {createElement: makeEl};
function el(tag, cls, text) {
  const e = makeEl(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

// --- load the page's own code ----------------------------------------------
const html = fs.readFileSync(path.join(__dirname, '..', 'web', 'index.html'), 'utf8');
function block(name) {
  const re = new RegExp(`// --- ${name}:start ---([\\s\\S]*?)// --- ${name}:end ---`);
  const m = re.exec(html);
  if (!m) { console.error(`FATAL: no ${name}:start/end block in web/index.html`); process.exit(2); }
  return m[1];
}
const sandbox = {console, document, el};
vm.createContext(sandbox);
vm.runInContext(block('describeTool') + block('toolRows') + `
;globalThis.api = {newToolRow, bindToolRow, setToolArgs, finishTool, resetToolRows,
                   settleToolRows, toolResultText,
                   // live bindings: resetToolRows() swaps the Map's identity
                   get toolRows() { return toolRows; },
                   get unboundTools() { return unboundTools; }};`, sandbox);
const api = sandbox.api;

let pass = 0;
const failures = [];
function is(label, actual, expected) {
  const a = JSON.stringify(actual), x = JSON.stringify(expected);
  if (a === x) pass++;
  else failures.push(`${label}\n     got: ${a}\n     exp: ${x}`);
}
// What the user sees: the summary text of every row, in order.
function summaries(root) {
  return root.map(r => ({
    desc: r.querySelector('.desc').textContent,
    tag: r.querySelector('.name').textContent,
    state: ['running', 'done', 'error'].find(c => r.classList.contains(c)),
    result: r._result,
  }));
}
function outcomes(root) {
  return root.map(r => ['running', 'done', 'error'].find(c => r.classList.contains(c)));
}

// --- L2: three parallel calls, results arriving in reverse order ------------
{
  api.resetToolRows();
  const rows = [];
  // one assistant message carrying three toolCall blocks
  rows.push(api.newToolRow('bash', 'c1'));
  rows.push(api.newToolRow('mcp__memos__search_memos', 'c2'));
  rows.push(api.newToolRow('read', 'c3'));
  // args land at toolcall_end / tool_execution_start
  api.setToolArgs(rows[0], {command: 'cd /tmp && ls -la'});
  api.setToolArgs(rows[1], {query: 'ssh access'});
  api.setToolArgs(rows[2], {file_path: '/home/nuc/notes.md'});
  is('L2: every row summarises its own call', summaries(rows).map(s => s.desc),
     ['Running ls -la', 'Searching memos for “ssh access”', 'Reading notes.md']);
  is('L2: rows are still pulsing while executing', outcomes(rows), ['running', 'running', 'running']);
  // results come back c3, c1, c2
  api.finishTool(api.toolRows.get('c3'), 'notes body', false);
  api.finishTool(api.toolRows.get('c1'), 'total 12', false);
  api.finishTool(api.toolRows.get('c2'), '4 memos matched', false);
  is('L2: each row keeps its own result',
     rows.map(r => r._result), ['total 12', '4 memos matched', 'notes body']);
  is('L2: none keeps pulsing', outcomes(rows), ['done', 'done', 'done']);
  api.settleToolRows();
  is('L2: settle is idempotent', outcomes(rows), ['done', 'done', 'done']);
}

// --- L2: a call whose toolcall_start carried no id --------------------------
{
  api.resetToolRows();
  const a = api.newToolRow('bash', '');      // id arrives later (openai-style)
  const b = api.newToolRow('bash', '');
  api.bindToolRow('x1', 'bash');             // binds the oldest unbound row
  api.setToolArgs(api.toolRows.get('x1'), {command: 'pwd'});
  is('L2: an unbound row binds to the first id it is offered',
     api.toolRows.get('x1') === a, true);
  is('L2: its args arrive normally', a._args.command, 'pwd');
  is('L2: the second unbound row stays unbound', b._args, undefined);
  api.finishTool(a, 'out', false);
  is('L2: the bound row takes the result', a._result, 'out');
  is('L2: the stray row is untouched', b._result, '');
}

// --- §8.2: an error marks only its own row ---------------------------------
{
  api.resetToolRows();
  const ok = api.newToolRow('bash', 'e1');
  const bad = api.newToolRow('read', 'e2');
  api.setToolArgs(ok, {command: 'ls'});
  api.setToolArgs(bad, {file_path: '/nope.txt'});
  api.finishTool(ok, 'fine', false);
  api.finishTool(bad, 'ENOENT: no such file or directory\nsecond line', true);
  is('error: only that row is red', outcomes([ok, bad]), ['done', 'error']);
  is('error: the summary is the first line of the error',
     bad.querySelector('.desc').textContent, 'ENOENT: no such file or directory');
  is('error: the call is still in the expanded view',
     bad.querySelector('.out').children.length, 2);
  is('error: the result keeps every line', bad._result.split('\n').length, 2);
}

// --- L3/L6: live and reloaded agree ----------------------------------------
{
  // (a) live: rows created by the stream, results by tool_execution_end
  api.resetToolRows();
  const live = [api.newToolRow('bash', 's1'), api.newToolRow('grep', 's2')];
  api.setToolArgs(live[0], {command: 'rg TODO'});
  api.setToolArgs(live[1], {pattern: 'TODO'});
  api.finishTool(api.toolRows.get('s1'), 'a\nb', false);
  api.finishTool(api.toolRows.get('s2'), '3 hits', false);

  // (b) reloaded: the daemon's transcript shape — an assistant message with
  //     toolCall blocks, then separate toolResult messages carrying toolCallId
  api.resetToolRows();
  const snap = [];
  for (const c of [{name: 'bash', id: 's1', arguments: {command: 'rg TODO'}},
                   {name: 'grep', id: 's2', arguments: {pattern: 'TODO'}}]) {
    const r = api.newToolRow(c.name, c.id);
    api.setToolArgs(r, c.arguments);
    r.classList.remove('running'); r.classList.add('done');
    snap.push(r);
  }
  for (const m of [{toolCallId: 's1', content: [{type: 'text', text: 'a\nb'}], isError: false},
                   {toolCallId: 's2', content: [{type: 'text', text: '3 hits'}], isError: false}]) {
    const row = api.toolRows.get(m.toolCallId);
    api.finishTool(row, api.toolResultText({content: m.content}), m.isError);
  }
  is('L3: live and reloaded rows match, summaries included', summaries(snap), summaries(live));
  is('L3: and so do the results', snap.map(r => r._result), live.map(r => r._result));
}

// --- L6: a result with no call on screen (truncated snapshot) --------------
{
  api.resetToolRows();
  const txt = api.toolResultText({content: [{type: 'text', text: 'orphan output'}]});
  const row = api.newToolRow('bash', null);
  row.querySelector('.desc').textContent = 'Running ls';
  api.finishTool(row, txt, false);
  is('L6: an orphaned result still renders', row._result, 'orphan output');
  is('L6: as a normal, finished row', outcomes([row]), ['done']);
}
{
  api.resetToolRows();
  const long = 'x'.repeat(5000);
  is('result cap matches the daemon (2048 + ellipsis)',
     api.toolResultText({content: [{type: 'text', text: long}]}).length, 2049);
  is('non-text result blocks are ignored',
     api.toolResultText({content: [{type: 'image', data: 'zzz'}]}), '');
}

if (failures.length) {
  console.error(`\n${failures.length} FAILED, ${pass} passed:\n`);
  for (const f of failures) console.error('  ✗ ' + f + '\n');
  process.exit(1);
}
console.log(`ok — ${pass} tool-row cases passed`);
