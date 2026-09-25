#!/usr/bin/env node
// §8.4: the node unit table for describeTool.
//
// Pure by design — no daemon, no fake pi, no DOM, no dependencies. The function
// lives in web/index.html (the page is a single file that install.sh copies to
// $STATE/web/), so the test pulls the block marked `describeTool:start/end`
// straight out of the page and evaluates it here.
//
//     node tests/describeTool.test.js
//
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HTML = path.join(__dirname, '..', 'web', 'index.html');
const html = fs.readFileSync(HTML, 'utf8');
const m = /\/\/ --- describeTool:start ---([\s\S]*?)\/\/ --- describeTool:end ---/
  .exec(html);
if (!m) {
  console.error('FATAL: no describeTool:start/end block in ' + HTML);
  process.exit(2);
}
const sandbox = {console};
vm.createContext(sandbox);
vm.runInContext(m[1] + `
;globalThis.api = {describeTool, toolPreparing, toolTag, toolMcp,
                   toolShortCommand, toolEllipsise};`, sandbox);
const {describeTool, toolPreparing, toolTag, toolMcp} = sandbox.api;

let pass = 0;
const failures = [];
function is(label, actual, expected) {
  if (actual === expected) pass++;
  else failures.push(`${label}\n     got: ${JSON.stringify(actual)}` +
                     `\n     exp: ${JSON.stringify(expected)}`);
}
const d = describeTool;

// --- bash: the model's own description wins (Tier 2), else the command ------
is('bash: args.description wins', d('bash', {description: 'Count the fleet routers', command: 'x'}), 'Count the fleet routers');
is('bash: strips a leading cd', d('bash', {command: 'cd /home/nuc/assistant && ls -la'}), 'Running ls -la');
is('bash: spec example', d('bash', {command: 'ls /home/nuc/assistant'}), 'Running ls /home/nuc/assistant');
is('bash: first command of a pipe', d('bash', {command: 'ls -la | head -20'}), 'Running ls -la');
is('bash: first command of &&', d('bash', {command: 'echo a && echo b'}), 'Running echo a');
is('bash: first command of ;', d('bash', {command: 'pwd; ls'}), 'Running pwd');
is('bash: first line of a script', d('bash', {command: 'pwd\nls'}), 'Running pwd');
is('bash: empty command', d('bash', {command: ''}), 'Running a command');
is('bash: missing command', d('bash', {}), 'Running a command');
is('bash: null args', d('bash', null), 'Running a command');
is('bash: cd with no follow-up', d('bash', {command: 'cd /tmp'}), 'Running cd /tmp');
is('bash: 60-char ellipsis', d('bash', {command: 'x'.repeat(200)}).length, 'Running '.length + 60);

// --- read / write / edit: basename ------------------------------------------
is('read: basename', d('read', {file_path: '/home/nuc/assistant/notes.md'}), 'Reading notes.md');
is('read: args.path too', d('read', {path: '/tmp/a/b.txt'}), 'Reading b.txt');
is('write', d('write', {file_path: '/tmp/x/y.txt'}), 'Writing y.txt');
is('edit', d('edit', {file_path: 'a/b/c.py'}), 'Editing c.py');
is('read: no path', d('read', {}), 'Reading');
is('read: null args', d('read', null), 'Reading');

// --- grep / find / ls -------------------------------------------------------
is('grep', d('grep', {pattern: 'TODO'}), 'Searching files for “TODO”');
is('find', d('find', {pattern: '*.jsonl'}), 'Finding files named “*.jsonl”');
is('grep: non-string pattern', d('grep', {pattern: 42}), 'Searching files for “42”');
is('grep: no pattern', d('grep', {}), 'Searching files for');
is('ls', d('ls', {path: '/home/nuc'}), 'Listing /home/nuc');
is('ls: no path', d('ls', {}), 'Listing .');

// --- memos ------------------------------------------------------------------
is('memos: search', d('mcp__memos__search_memos', {query: 'ssh access'}), 'Searching memos for “ssh access”');
is('memos: search, non-string query', d('mcp__memos__search_memos', {query: 5}), 'Searching memos for “5”');
is('memos: search, no query', d('mcp__memos__search_memos', {}), 'Searching memos for');
is('memos: get', d('mcp__memos__get_memo', {id: 'RAXygvuunzETWwGhBnNSoZ'}), 'Opening memo RAXygvuu…');
is('memos: get, no id', d('mcp__memos__get_memo', {}), 'Opening memo');

// --- other MCP tools --------------------------------------------------------
is('mcp generic: server + first string arg', d('mcp__gmail__list_labels', {q: 'inbox'}), 'List labels (gmail): inbox');
is('mcp generic: no args', d('mcp__gmail__list_labels', {}), 'List labels (gmail)');
is('mcp generic: two-word tool', d('mcp__github__list_pull_requests', {state: 'open'}), 'List pull requests (github): open');
is('mcp: server with an underscore', toolMcp('mcp__my_server__do_thing').server, 'my_server');

// --- anything else ----------------------------------------------------------
is('fallback: words + arg', d('web_search', {query: 'weather'}), 'Web search: weather');
is('fallback: words only', d('some_tool', null), 'Some tool');
is('fallback: no name', d(undefined, undefined), 'Tool');
is('fallback: object arg preview', d('my_tool', {other: 'value'}), 'My tool: value');
is('fallback: arg ellipsised', d('my_tool', {query: 'y'.repeat(100)}).endsWith('…'), true);

// --- streaming label and the right-hand tag ---------------------------------
is('preparing: plain tool', toolPreparing('bash'), 'Preparing Bash…');
is('preparing: mcp tool', toolPreparing('mcp__memos__search_memos'), 'Preparing Search memos…');
is('preparing: never throws', typeof toolPreparing(undefined), 'string');
is('tag: plain', toolTag('bash'), 'bash');
is('tag: mcp server only', toolTag('mcp__memos__search_memos'), 'mcp memos');

// --- odds and ends ----------------------------------------------------------
is('ellipsise: short untouched', sandbox.api.toolEllipsise('abc', 60), 'abc');
is('ellipsise: null', sandbox.api.toolEllipsise(null, 60), '');
is('describeTool never throws on junk args', typeof d('read', 7), 'string');
is('describeTool never throws on array args', typeof d('ls', []), 'string');

if (failures.length) {
  console.error(`\n${failures.length} FAILED, ${pass} passed:\n`);
  for (const f of failures) console.error('  ✗ ' + f + '\n');
  process.exit(1);
}
console.log(`ok — ${pass} describeTool cases passed`);
