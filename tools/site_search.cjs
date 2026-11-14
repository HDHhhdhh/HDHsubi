#!/usr/bin/env node
// 수학비서(mathsecr.com) fast search / paper builder.
//
// Runs the site's own JSON API (api.mathsecr.com) from inside the logged-in
// Aside Browser tab, so the session/cookies are the user's own. One process:
//   node tools/site_search.cjs search --in items.json --out result.json
//   node tools/site_search.cjs create-paper --title "이름" --cells 1,2,3
//   node tools/site_search.cjs add-cells --paper 123 --cells 4,5
//   node tools/site_search.cjs paper-cells --paper 123
// See tools/USAGE.md. No dependencies beyond Node 18+ and the Aside CLI.

'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const path = require('node:path');

const SITE = 'https://www.mathsecr.com';
const DEFAULT_FOLDER = 194543; // subi contract: 생성 폴더194543 고정
const MARK = '@@SUBI@@';
// Owner rule 1571040637506297917, recorded in every search/paper output so the
// judging step applies it: same stem => same problem, even if the 객관식 choices
// are missing (school prints strip them) or differ, and regardless of the
// closing phrase (구하시오 / 값은?). Add it without further verification.
const STEM_RULE = 'same-stem=same-problem; ignore missing/different choices and 구하시오/값은? phrasing; add without extra verification (owner 1571040637506297917)';

// ---------------------------------------------------------------- CLI args
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
      out[k] = v;
    } else out._.push(a);
  }
  return out;
}
const csvInts = (v) => (v == null || v === true ? [] : String(v).split(/[,\s|]+/).filter(Boolean).map(Number));

// ---------------------------------------------------------------- Aside MCP
function defaultAsideExe() {
  if (process.env.ASIDE_EXE) return process.env.ASIDE_EXE;
  if (process.platform === 'win32' && process.env.LOCALAPPDATA) {
    return path.join(process.env.LOCALAPPDATA, 'Aside', 'CLI', 'current', 'aside.exe');
  }
  return 'aside';
}

class Aside {
  constructor(exe) { this.exe = exe; this.id = 1; this.pending = new Map(); this.buf = ''; this.stderr = ''; }
  async start() {
    this.proc = spawn(this.exe, ['--host', 'local', 'mcp'], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc.stdout.setEncoding('utf8');
    this.proc.stdout.on('data', (d) => {
      this.buf += d;
      let i;
      while ((i = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, i).trim();
        this.buf = this.buf.slice(i + 1);
        if (!line) continue;
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.id != null && this.pending.has(m.id)) { this.pending.get(m.id)(m); this.pending.delete(m.id); }
      }
    });
    this.proc.stderr.setEncoding('utf8');
    this.proc.stderr.on('data', (d) => { this.stderr = (this.stderr + d).slice(-4000); });
    this.exited = new Promise((res) => this.proc.on('exit', (code) => { res(code); for (const r of this.pending.values()) r({ error: { message: `aside mcp exited ${code}: ${this.stderr.slice(-500)}` } }); this.pending.clear(); }));
    const init = await this.send('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'hdhsubi-site-search', version: '1' } }, 30000);
    if (init.error) throw new Error('aside initialize failed: ' + JSON.stringify(init.error));
    this.proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} }) + '\n');
  }
  send(method, params, timeoutMs = 130000) {
    return new Promise((resolve, reject) => {
      const id = this.id++;
      const t = setTimeout(() => { this.pending.delete(id); reject(new Error('timeout ' + method)); }, timeoutMs);
      this.pending.set(id, (m) => { clearTimeout(t); resolve(m); });
      this.proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  // Runs code in the persistent Aside REPL. Code is wrapped in a block so
  // const/let never collide across calls; values marked with MARK are returned.
  async repl(code, title = 'HDHsubi site_search') {
    const m = await this.send('tools/call', { name: 'repl', arguments: { title, code: '{\n' + code + '\n}' } });
    if (m.error) throw new Error('repl error: ' + JSON.stringify(m.error));
    const text = (m.result.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
    if (m.result.isError) throw new Error('repl failed: ' + text.slice(0, 1500));
    const vals = text.split('\n').filter((l) => l.startsWith(MARK)).map((l) => JSON.parse(l.slice(MARK.length)));
    return vals.length ? vals[vals.length - 1] : undefined;
  }
  async close() { try { this.proc.stdin.end(); } catch {} setTimeout(() => { try { this.proc.kill(); } catch {} }, 1500).unref(); }
}

// ---------------------------------------------------------------- in-page library
// Evaluated inside the mathsecr.com tab. Uses the page's own session token
// (next-auth /api/auth/session -> accessToken) like the site's axios client.
const PAGE_LIB = String.raw`(() => {
  const VERSION = 8;
  if (window.__subi && window.__subi.v === VERSION) return 'ready';
  const API = 'https://api.mathsecr.com';
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const S = { v: VERSION, tok: null, jobs: {}, requests: 0 };
  async function token(force) {
    if (!S.tok || force) {
      const r = await fetch('/api/auth/session', { credentials: 'include' });
      const j = await r.json().catch(() => null);
      S.tok = (j && j.accessToken) || null;
    }
    if (!S.tok) { const e = new Error('NOT_LOGGED_IN: no session token'); e.code = 'NOT_LOGGED_IN'; throw e; }
    return S.tok;
  }
  async function req(method, p, params, body) {
    const u = new URL(API + p);
    for (const [k, v] of Object.entries(params || {})) if (v != null) for (const x of [].concat(v)) u.searchParams.append(k, String(x));
    for (let attempt = 0; attempt < 4; attempt++) {
      S.requests++;
      const headers = { Accept: 'application/json', Authorization: 'Bearer ' + (await token(attempt > 0 && S.last401)), 'X-User-Type': 'educator' };
      if (body != null) headers['Content-Type'] = 'application/json';
      const ac = new AbortController();
      const timer = setTimeout(() => ac.abort(), 30000);
      let r;
      try { r = await fetch(u, { method, credentials: 'include', headers, body: body != null ? JSON.stringify(body) : undefined, signal: ac.signal }); }
      finally { clearTimeout(timer); }
      S.last401 = r.status === 401;
      if (r.status === 401 && attempt === 0) continue;
      if ((r.status === 429 || r.status >= 500) && attempt < 3) { await sleep(1000 * (attempt + 1)); continue; }
      const t = await r.text();
      let j = null; try { j = t ? JSON.parse(t) : null; } catch {}
      if (!r.ok) { const e = new Error('HTTP ' + r.status + ' ' + method + ' ' + p + ' ' + t.slice(0, 300)); e.status = r.status; e.body = j; throw e; }
      return j;
    }
  }
  // Concurrency-only limiter. The tab runs in the background, where Chrome
  // throttles setTimeout (down to once a minute), so pacing must not rely on
  // timers: at most conc requests are in flight and the next starts when one
  // finishes.
  function limiter(conc) {
    let active = 0; const q = [];
    const pump = () => {
      while (active < conc && q.length) {
        active++;
        const { fn, res, rej } = q.shift();
        Promise.resolve().then(fn).then(res, rej).finally(() => { active--; pump(); });
      }
    };
    return (fn) => new Promise((res, rej) => { q.push({ fn, res, rej }); pump(); });
  }
  // Owner rule 1571040637506297917: the stem decides. Missing or different
  // 객관식 choices and the closing phrase (구하시오 / 값은? / 몇 개인가) are not
  // compared, so choices are cut off and closing words are stop words.
  const STOP = new Set(['함수','다음','조건','구하시오','구하여라','구하면','구하는','구할','구한','대하여','대한','하자','이다','이때','있다','있는','하는','같은','같이','그림','그림과','서로','다른','것은','것만을','옳은','고른','보기','실수','상수','모든','한다','하여','만족','라고','하고','이고','이며','값','값을','값은','값이','값의','때','단','얼마','얼마인가','인가','개인가','몇','다음중','있는대로']);
  // Cut 객관식 choices: from the first circled number, or from a choice run like
  // "(1) .. (2) .. (3)" at the end of the text.
  function stemOnly(text) {
    let s = String(text || '');
    const i = s.search(/[\u2460-\u2464]/);
    if (i >= 0) s = s.slice(0, i);
    const m = s.match(/\(1\)[^()]{0,40}\(2\)[^()]{0,40}\(3\)[\s\S]*$/);
    if (m) s = s.slice(0, m.index);
    return s;
  }
  const JOSA = ['에서는','에서','에게','까지','부터','으로','이다','이고','이며','하고','하여','하자','에는','와의','과의','은','는','이','가','을','를','의','에','와','과','도','로','만','인'];
  function autoTerms(text) {
    const out = [];
    for (let w of stemOnly(text).match(/[가-힣]+/g) || []) {
      for (const j of JOSA) if (w.length - j.length >= 2 && w.endsWith(j)) { w = w.slice(0, -j.length); break; }
      if (w.length < 2 || STOP.has(w) || out.includes(w)) continue;
      out.push(w);
    }
    return out;
  }
  function scopeParams(scope) {
    const p = { curriculumId: scope.curriculumId || 2, source: 'mypaper', isSoftMode: true, problemBankScope: 'include' };
    for (const k of ['dbFolderIds','myDbIds','myPaperIds','paperFolderIds','chapterTreeIds','excludeDbFolderIds','excludeDbIds','answerTypes'])
      if (scope[k] && [].concat(scope[k]).length) p[k] = [].concat(scope[k]).join('|');
    for (const k of ['sourceStartYear','sourceEndYear','minDifficulty','maxDifficulty']) if (scope[k] != null) p[k] = scope[k];
    if (scope.textExcludes) p.textExcludes = [].concat(scope.textExcludes);
    return p;
  }
  function slim(c, group) {
    return {
      id: c.id, imagePath: c.imagePath,
      sources: (c.sources || []).map((s) => s.combinedTitle),
      chapter: group && group.chapters && group.chapters[0] ? group.chapters[0].chapter.join(' > ') : null,
      books: [...new Set((c.myDbInfos || []).map((x) => x.title).filter(Boolean))],
      isAnswer: c.isAnswer, isExplanation: c.isExplanation,
    };
  }
  async function query(lim, scope, terms, limit, maxPages, maxTotal) {
    const base = { ...scopeParams(scope), textIncludes: terms, limit };
    const cells = []; let total = 0, cursor = null, pages = 0;
    do {
      const j = await lim(() => req('GET', '/bms/api/v1/question-cells', cursor ? { ...base, cursor } : base));
      total = (j && j.pagination && j.pagination.totalItems) || 0;
      for (const g of (j && j.data && j.data.cellsByChapter) || []) for (const c of g.cells || []) if (c) cells.push(slim(c, g));
      cursor = j && j.pagination ? j.pagination.cursor : null;
      pages++;
    } while (limit > 1 && cursor && pages < maxPages && cells.length < total && total <= maxTotal);
    return { total, cells };
  }
  // Server cost grows with the hit count: a broad single word (e.g. 정수,
  // 4000+ hits) takes seconds, a 3-word AND takes ~0.5s. So the first pass
  // only sends 3+ word ANDs (longer words first, plus consecutive windows);
  // pairs are a fallback for items the first pass did not hit.
  function uniq(list) {
    const seen = new Set(); const out = [];
    for (const q of list) if (q) { const k = [...q].sort().join('\u0001'); if (!seen.has(k)) { seen.add(k); out.push(q); } }
    return out;
  }
  function firstPass(t) {
    const r = t.map((w, i) => ({ w, i })).sort((a, b) => b.w.length - a.w.length || a.i - b.i).map((x) => x.w);
    const pick = (...ix) => ix.every((i) => i < r.length) ? ix.map((i) => r[i]) : null;
    const list = [pick(0,1,2), pick(0,1,3), pick(0,2,3), pick(1,2,3), pick(0,1,2,3), pick(0,1,2,3,4), pick(0,1,4), pick(2,3,4)];
    for (let i = 0; i + 3 <= t.length; i += 2) list.push(t.slice(i, i + 3));
    if (t.length === 2) list.push(t.slice());
    if (r[0] && r[1] && r[1].length >= 3) list.push([r[0], r[1]]);
    return uniq(list);
  }
  function fallbackPass(t) {
    const r = t.map((w, i) => ({ w, i })).sort((a, b) => b.w.length - a.w.length || a.i - b.i).map((x) => x.w);
    const pick = (...ix) => ix.every((i) => i < r.length) ? ix.map((i) => r[i]) : null;
    const list = [pick(0,1), pick(0,2), pick(1,2), pick(0,3), pick(1,3), pick(2,3)];
    return uniq(list); // single words return 0 from the server; never sent
  }
  async function runItem(item, opt, lim, stage) {
    const scope = stage && stage.scope ? { ...stage.scope } : { ...opt.scope, ...(item.scope || {}) };
    const res = { key: item.key, terms: null, queries: [], all: [], error: null };
    try {
      const terms = item.queries ? null : (item.terms || autoTerms(item.text)).slice(0, opt.maxTerms);
      res.terms = terms;
      const runAll = (qs) => Promise.all(qs.map((q) => query(lim, scope, q, 48, opt.maxPages, opt.maxTotal).then((r) => ({ q, ...r }), (e) => ({ q, total: 0, cells: [], error: String(e && e.message || e) }))));
      let runs = await runAll(item.queries || firstPass(terms));
      if (terms && ((stage && stage.fallback) || !runs.some((r) => r.total > 0 && r.total <= opt.maxTotal))) runs = runs.concat(await runAll(fallbackPass(terms)));
      const byId = new Map();
      for (const r of runs) {
        const used = r.total > 0 && r.total <= opt.maxTotal;
        res.queries.push({ terms: r.q, total: r.total, used, ...(r.error ? { error: r.error } : {}) });
        if (!used) continue;
        const w = r.q.length / Math.log2(2 + r.total);
        for (const c of r.cells) {
          const e = byId.get(c.id) || { ...c, score: 0, hits: 0 };
          e.score += w; e.hits++; byId.set(c.id, e);
        }
      }
      res.all = [...byId.values()].sort((a, b) => b.score - a.score || b.hits - a.hits).slice(0, 80);
    } catch (e) { res.error = String(e && e.message || e); if (e && e.code === 'NOT_LOGGED_IN') throw e; }
    return res;
  }
  // title -> [myDb id] over the whole 나만의 DB folder tree (cached per tab).
  async function dbCatalog(lim) {
    if (S.catalog) return S.catalog;
    const tree = (await req('GET', '/bms/api/v1/folders', { folderType: 'mydb' })).data;
    const ids = []; const walk = (n) => { ids.push(n.id); (n.children || []).forEach(walk); }; walk(tree);
    const lists = await Promise.all(ids.map((id) => lim(() => req('GET', '/bms/api/v1/mydbs', { needPaging: false, folderId: id, order: 'created_at:desc' }))
      .then((j) => (Array.isArray(j && j.data) ? j.data : []), () => [])));
    const map = {};
    for (const d of lists.flat()) (map[d.title] = map[d.title] || []).push(d.id);
    S.catalog = map;
    return map;
  }
  // Books (myDb titles) that show up in the top candidates of many items:
  // school prints usually take most problems from one or two books.
  function dominantBooks(results, n) {
    const cnt = {};
    for (const r of results) {
      if (!r) continue;
      const seen = new Set();
      for (const c of r.all.slice(0, 5)) for (const b of c.books || []) seen.add(b);
      for (const b of seen) cnt[b] = (cnt[b] || 0) + 1;
    }
    const need = Math.max(2, Math.ceil(n * 0.2));
    return Object.entries(cnt).filter(([, v]) => v >= need).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([t, v]) => ({ title: t, items: v }));
  }
  function startSearch(spec) {
    const id = 'j' + Date.now().toString(36);
    const opt = { top: 10, maxTerms: 8, maxTotal: 300, maxPages: 3, concurrency: 6, scope: {}, ...spec.options };
    const job = { id, done: false, error: null, total: spec.items.length, finished: 0, startedAt: Date.now(), results: new Array(spec.items.length), requests0: S.requests };
    S.jobs[id] = job;
    const lim = limiter(opt.concurrency);
    // Stages: (1) probe the first few items over the given scope; (2) if a
    // dominant book shows up, search every item inside that book (small scope =
    // fast, so pair queries are affordable); (3) items still without a hit in
    // the book get the normal search. Final score = stage1 + 2 x book stage.
    const items = spec.items, n = items.length;
    const s1 = new Array(n), s2 = new Array(n);
    const auto = opt.autoScope !== false && !(opt.scope.myDbIds && opt.scope.myDbIds.length);
    const tick = () => { job.finished++; };
    (async () => {
      try {
        await token(false);
        const probe = auto ? Math.min(n, opt.probe || 6) : n;
        job.total = n;
        await Promise.all(items.slice(0, probe).map((it, i) => runItem(it, opt, lim).then((r) => { s1[i] = r; tick(); })));
        job.books = auto ? dominantBooks(s1, probe) : [];
        if (job.books.length) {
          const cat = await dbCatalog(lim);
          job.bookDbIds = [...new Set(job.books.flatMap((b) => cat[b.title] || []))];
        }
        if (job.bookDbIds && job.bookDbIds.length) {
          job.total += n;
          const st = { scope: { curriculumId: opt.scope.curriculumId, myDbIds: job.bookDbIds }, fallback: true };
          await Promise.all(items.map((it, i) => runItem(it, opt, lim, st).then((r) => { s2[i] = r; tick(); })));
        }
        const rest = items.map((it, i) => i).filter((i) => !s1[i] && !(s2[i] && s2[i].all.length));
        job.total += rest.length;
        await Promise.all(rest.map((i) => runItem(items[i], opt, lim).then((r) => { s1[i] = r; tick(); })));
        job.results = items.map((it, i) => {
          const a = s1[i], b = s2[i];
          const byId = new Map();
          for (const [r, w] of [[a, 1], [b, 2]]) if (r) for (const c of r.all) {
            const e = byId.get(c.id) || { ...c, score: 0, hits: 0 };
            if (byId.has(c.id)) { e.score += c.score * w; e.hits += c.hits; } else { e.score = c.score * w; }
            byId.set(c.id, e);
          }
          const candidates = [...byId.values()].sort((x, y) => y.score - x.score || y.hits - x.hits).slice(0, opt.top)
            .map((c) => ({ ...c, score: Math.round(c.score * 1000) / 1000 }));
          return { key: it.key, terms: (a || b).terms, queries: [...(a ? a.queries : []), ...(b ? b.queries.map((q) => ({ ...q, book: true })) : [])],
            error: [a && a.error, b && b.error].filter(Boolean).join('; ') || null, candidates };
        });
      } catch (e) { job.error = String(e && e.message || e); }
      job.ms = Date.now() - job.startedAt; job.requests = S.requests - job.requests0; job.done = true;
      job.json = JSON.stringify({ ms: job.ms, requests: job.requests, options: opt, books: job.books || [], bookDbIds: job.bookDbIds || [], error: job.error, items: job.results });
    })();
    return id;
  }
  function status(id) { const j = S.jobs[id]; return j ? { done: j.done, finished: j.finished, total: j.total, error: j.error, ms: Date.now() - j.startedAt, len: j.json ? j.json.length : 0 } : null; }
  function chunk(id, from, size) { return S.jobs[id].json.slice(from, from + size); }
  function drop(id) { delete S.jobs[id]; }
  async function listCells(paperId, curriculumId) {
    const cells = []; let cursor = null;
    do {
      const j = await req('GET', '/bms/api/v1/my-papers/' + paperId + '/cells', { curriculumId: curriculumId || 2, limit: 200, ...(cursor ? { cursor } : {}) });
      for (const c of (j.data && j.data.cells) || []) cells.push({ id: c.id, n: c.questionNumber });
      cursor = j.pagination && j.pagination.cursor;
      if (!j.data || !(j.data.cells || []).length) break;
    } while (cursor);
    return cells;
  }
  async function createPaper(title, folderId) {
    const j = await req('POST', '/bms/api/v1/my-papers', null, { title, folderId: Number(folderId), category: 'paper' });
    return j.data.id;
  }
  async function addCells(paperId, ids, curriculumId) {
    const before = await listCells(paperId, curriculumId);
    let after = before.length;
    for (let i = 0; i < ids.length; i += 50) {
      const batch = ids.slice(i, i + 50);
      await req('POST', '/bms/api/v1/my-papers/' + paperId + '/cells', { action: 'add', curriculumId: curriculumId || 2 }, { cellIds: batch, afterNumber: after });
      after += batch.length;
    }
    const now = await listCells(paperId, curriculumId);
    const tail = now.slice(before.length).map((c) => c.id);
    return { before: before.length, count: now.length, orderOk: JSON.stringify(tail) === JSON.stringify(ids), cells: now.map((c) => c.id) };
  }
  function pageState() {
    const t = (document.body && document.body.innerText) || '';
    return { url: location.href, deviceLimit: /기기/.test(t) && /(초과|제한|최대)/.test(t) && /로그아웃|다른 기기/.test(t) };
  }
  window.__subi = { v: VERSION, autoTerms, startSearch, status, chunk, drop, listCells, createPaper, addCells, pageState, token };
  return 'loaded';
})()`;

// ---------------------------------------------------------------- session wrapper
async function openSession(args) {
  const aside = new Aside(args.aside || defaultAsideExe());
  await aside.start();
  const lib = JSON.stringify(PAGE_LIB);
  const st = await aside.repl(`
globalThis.__subiPage = await openTab(${JSON.stringify(SITE + '/home')});
const p = globalThis.__subiPage;
await p.evaluate(${lib});
const s = await p.evaluate(() => window.__subi.pageState());
let tok = null; try { tok = !!(await p.evaluate(() => window.__subi.token(true))); } catch (e) { tok = String(e.message || e); }
console.log(${JSON.stringify(MARK)} + JSON.stringify({ ...s, tok, pwd }));`, 'HDHsubi site_search: open own tab');
  if (!st || st.tok !== true || /\/(login|signin)/.test(st.url)) {
    await closeSession(aside);
    throw new Error('STOP: not logged in or login page shown (' + JSON.stringify(st) + '). Log in by hand; this tool never logs in.');
  }
  if (st.deviceLimit) {
    await closeSession(aside);
    throw new Error('STOP: device-limit prompt detected on ' + st.url + '. Resolve by hand; this tool never dismisses it.');
  }
  aside.pwd = st.pwd;
  return aside;
}
async function closeSession(aside) {
  try { await aside.repl(`if (globalThis.__subiPage) { await closeTab(globalThis.__subiPage); globalThis.__subiPage = null; }`, 'HDHsubi site_search: close own tab'); } catch {}
  await aside.close();
}
const pageCall = (aside, expr, title) => aside.repl(`const v = await globalThis.__subiPage.evaluate(${expr}); console.log(${JSON.stringify(MARK)} + JSON.stringify(v === undefined ? null : v));`, title);

// ---------------------------------------------------------------- commands
function loadItems(raw) {
  const arr = Array.isArray(raw) ? raw : raw.items;
  if (!Array.isArray(arr)) throw new Error('items file must be an array or {items:[...]}');
  return arr.map((x, i) => ({
    key: String(x.key ?? x.id ?? x.number ?? i + 1),
    text: x.text, terms: x.terms, queries: x.queries, scope: x.scope,
    expect: x.expect ?? x.site_cell_id ?? null,
  }));
}

async function cmdSearch(args) {
  if (!args.in) throw new Error('--in items.json required');
  const items = loadItems(JSON.parse(await fs.readFile(args.in, 'utf8')));
  const scope = {};
  if (args['scope-folder']) scope.dbFolderIds = csvInts(args['scope-folder']);
  if (args['db-ids']) scope.myDbIds = csvInts(args['db-ids']);
  if (args['paper-ids']) scope.myPaperIds = csvInts(args['paper-ids']);
  if (args.chapters) scope.chapterTreeIds = csvInts(args.chapters);
  if (args.years) { const [a, b] = String(args.years).split('-').map(Number); scope.sourceStartYear = a; scope.sourceEndYear = b || a; }
  const options = {
    scope,
    top: 3 * Number(args.top || 15), maxTerms: Number(args['max-terms'] || 8), maxTotal: Number(args['max-total'] || 300),
    maxPages: Number(args['max-pages'] || 3), concurrency: Number(args.concurrency || 6),
    autoScope: !args['no-auto-scope'], probe: Number(args.probe || 6),
  };
  const t0 = Date.now();
  const aside = await openSession(args);
  let result;
  try {
    const spec = { items: items.map(({ expect, ...it }) => it), options };
    const id = await pageCall(aside, `(s) => window.__subi.startSearch(s), ${JSON.stringify(spec)}`, 'HDHsubi site_search: start search job');
    let st;
    for (;;) {
      await new Promise((r) => setTimeout(r, 1500));
      st = await pageCall(aside, `(id) => window.__subi.status(id), ${JSON.stringify(id)}`, 'HDHsubi site_search: job status');
      if (!args.quiet) process.stderr.write(`\r${st.finished}/${st.total} items, ${Math.round(st.ms / 1000)}s   `);
      if (st.done) break;
    }
    if (!args.quiet) process.stderr.write('\n');
    let json = '';
    for (let from = 0; from < st.len; from += 200000) json += await pageCall(aside, `([id, f]) => window.__subi.chunk(id, f, 200000), ${JSON.stringify([id, from])}`, 'HDHsubi site_search: fetch results');
    await pageCall(aside, `(id) => window.__subi.drop(id), ${JSON.stringify(id)}`, 'HDHsubi site_search: drop job');
    result = JSON.parse(json);
    if (result.error) throw new Error('search job failed: ' + result.error);
    rerankByNeighbors(result.items);
    for (const it of result.items) it.candidates = it.candidates.slice(0, Number(args.top || 15));
    result.options.top = Number(args.top || 15);
    if (args.images) await downloadImages(aside, result, args.images, Number(args['images-top'] || 8));
  } finally { await closeSession(aside); }
  result.wallMs = Date.now() - t0;
  result.rule = STEM_RULE;
  // expected-cell check (sources.json style input with site_cell_id)
  const exp = items.filter((it) => it.expect);
  if (exp.length) {
    const ranks = exp.map((it) => {
      const r = result.items.find((x) => x.key === it.key);
      const ix = r ? r.candidates.findIndex((c) => c.id === Number(it.expect)) : -1;
      return { key: it.key, expect: Number(it.expect), rank: ix >= 0 ? ix + 1 : null };
    });
    result.expected = { total: ranks.length, found: ranks.filter((r) => r.rank).length, top1: ranks.filter((r) => r.rank === 1).length, ranks };
  }
  const out = JSON.stringify(result, null, 1);
  if (args.out) await fs.writeFile(args.out, out); else process.stdout.write(out + '\n');
  const summary = { items: result.items.length, ms: result.ms, wallMs: result.wallMs, requests: result.requests, books: (result.books || []).map((b) => b.title), errors: result.items.filter((x) => x.error).length, expected: result.expected && { total: result.expected.total, found: result.expected.found, top1: result.expected.top1 } };
  process.stderr.write(JSON.stringify(summary) + '\n');
}

// Prints follow the book order, and a book's cells get consecutive ids. Text
// queries often tie (formulas are not indexed), so a candidate whose id sits
// next to the best-scoring candidates of the neighbouring items (i-2..i+2) gets
// a small bonus (at most 20% of the item's top score). Re-ranking only; no
// candidate is dropped.
function rerankByNeighbors(items) {
  const best = items.map((it) => {
    const top = it.candidates[0] ? it.candidates[0].score : 0;
    return it.candidates.filter((c) => c.score >= top * 0.999).map((c) => c.id);
  });
  for (const [i, it] of items.entries()) {
    if (!it.candidates.length) continue;
    const top = it.candidates[0].score;
    const near = [i - 2, i - 1, i + 1, i + 2].filter((k) => k >= 0 && k < items.length).flatMap((k) => best[k]);
    for (const c of it.candidates) {
      const d = near.length ? Math.min(...near.map((id) => (id === c.id ? Infinity : Math.abs(c.id - id)))) : Infinity;
      c.neighbor = Number.isFinite(d) ? Math.round(top * 0.2 * Math.exp(-d / 300) * 1000) / 1000 : 0;
    }
    it.candidates.sort((x, y) => (y.score + y.neighbor) - (x.score + x.neighbor));
  }
}

async function downloadImages(aside, result, dir, topN) {
  await fs.mkdir(dir, { recursive: true });
  const want = [];
  for (const it of result.items) for (const c of it.candidates.slice(0, topN)) if (c.imagePath && !want.some((w) => w.id === c.id)) want.push({ id: c.id, url: c.imagePath });
  const sub = 'subi-img-' + Date.now().toString(36);
  for (let i = 0; i < want.length; i += 40) {
    const batch = want.slice(i, i + 40);
    await aside.repl(`
await fs.mkdir(pwd + '/${sub}', { recursive: true });
const list = ${JSON.stringify(batch)};
await Promise.all(list.map(async (w) => { const r = await fetch(w.url); if (r.status === 200) await fs.writeFile(pwd + '/${sub}/' + w.id + '.png', new Uint8Array(await r.arrayBuffer())); }));
console.log(${JSON.stringify(MARK)} + 'null');`, 'HDHsubi site_search: download candidate images');
  }
  const local = new Map();
  for (const w of want) {
    const src = path.join(aside.pwd, sub, w.id + '.png');
    try { await fs.copyFile(src, path.join(dir, w.id + '.png')); local.set(w.id, path.join(dir, w.id + '.png')); } catch {}
  }
  for (const it of result.items) for (const c of it.candidates) if (local.has(c.id)) c.image = local.get(c.id);
  await fs.rm(path.join(aside.pwd, sub), { recursive: true, force: true }).catch(() => {});
}

async function readCells(args) {
  if (args['cells-file']) {
    const raw = JSON.parse(await fs.readFile(args['cells-file'], 'utf8'));
    return (Array.isArray(raw) ? raw : raw.cells).map((x) => Number(typeof x === 'object' ? x.id ?? x.site_cell_id : x)).filter(Boolean);
  }
  return csvInts(args.cells);
}

async function cmdCreatePaper(args) {
  if (!args.title || args.title === true) throw new Error('--title required');
  const ids = await readCells(args);
  const aside = await openSession(args);
  try {
    const paperId = await pageCall(aside, `([t, f]) => window.__subi.createPaper(t, f), ${JSON.stringify([String(args.title), Number(args.folder || DEFAULT_FOLDER)])}`, 'HDHsubi site_search: create paper');
    let add = null;
    if (ids.length) add = await pageCall(aside, `([p, ids]) => window.__subi.addCells(p, ids), ${JSON.stringify([paperId, ids])}`, 'HDHsubi site_search: add cells');
    const out = { paperId, url: `${SITE}/mypaper/${paperId}`, rule: STEM_RULE, title: String(args.title), folderId: Number(args.folder || DEFAULT_FOLDER), requested: ids.length, ...(add || {}) };
    process.stdout.write(JSON.stringify(out, null, 1) + '\n');
    if (add && !add.orderOk) process.exitCode = 2;
  } finally { await closeSession(aside); }
}

async function cmdAddCells(args) {
  const ids = await readCells(args);
  if (!args.paper || !ids.length) throw new Error('--paper and --cells/--cells-file required');
  const aside = await openSession(args);
  try {
    const add = await pageCall(aside, `([p, ids]) => window.__subi.addCells(p, ids), ${JSON.stringify([Number(args.paper), ids])}`, 'HDHsubi site_search: add cells');
    process.stdout.write(JSON.stringify({ paperId: Number(args.paper), url: `${SITE}/mypaper/${args.paper}`, ...add }, null, 1) + '\n');
    if (!add.orderOk) process.exitCode = 2;
  } finally { await closeSession(aside); }
}

async function cmdPaperCells(args) {
  if (!args.paper) throw new Error('--paper required');
  const aside = await openSession(args);
  try {
    const cells = await pageCall(aside, `(p) => window.__subi.listCells(p), ${JSON.stringify(Number(args.paper))}`, 'HDHsubi site_search: list paper cells');
    process.stdout.write(JSON.stringify({ paperId: Number(args.paper), count: cells.length, cells: cells.map((c) => c.id) }) + '\n');
  } finally { await closeSession(aside); }
}

const USAGE = `usage:
  node tools/site_search.cjs search --in items.json [--out result.json] [--scope-folder 81500] [--years 2025-2026]
         [--top 15] [--images DIR] [--images-top 8] [--concurrency 6] [--max-total 300] [--probe 6] [--no-auto-scope]
  node tools/site_search.cjs create-paper --title NAME [--folder ${DEFAULT_FOLDER}] [--cells 1,2,3 | --cells-file f.json]
  node tools/site_search.cjs add-cells --paper ID --cells 1,2,3
  node tools/site_search.cjs paper-cells --paper ID`;

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];
const table = { search: cmdSearch, 'create-paper': cmdCreatePaper, 'add-cells': cmdAddCells, 'paper-cells': cmdPaperCells };
if (!table[cmd]) { console.error(USAGE); process.exit(1); }
table[cmd](args).catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
