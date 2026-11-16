'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require.resolve('../tools/site_search.cjs'), 'utf8');
function setup(handle) {
  let tokenReads = 0;
  const c = { require, window: {}, URL, AbortController,
    setTimeout: (fn, ms) => ms < 30000 ? setTimeout(fn, 0) : 0, clearTimeout,
    fetch: async (url, opt) => {
      if (url === '/api/auth/session') return { json: async () => ({ accessToken: 'fake-' + ++tokenReads }) };
      const u = new URL(url);
      assert.equal(u.host, 'api.mathsecr.com');
      const [status, body] = await handle(u, opt);
      return { status, ok: status < 400, text: async () => JSON.stringify(body) };
    } };
  vm.createContext(c);
  vm.runInContext(source.slice(0, source.lastIndexOf('const args = parseArgs(')) + '\nthis.load = loadItems; eval(PAGE_LIB);', c);
  return [c.load, c.window.__subi];
}
const cellsReply = (ids) => [200, { data: { cells: ids.map((id, i) => ({ id, questionNumber: i + 1 })) } }];
const searchReply = (ids) => [200, { data: { cellsByChapter: [{ cells: ids.map(id => ({ id, myDbInfos: [{ title: 'A' }] })) }] }, pagination: { totalItems: ids.length } }];
async function search(api, items, options) {
  const id = api.startSearch({ items, options });
  for (let i = 0; i < 1000; i++) {
    const s = api.status(id);
    if (s.done) return JSON.parse(api.chunk(id, 0, s.len));
    await new Promise(r => setTimeout(r, 2));
  }
  assert.fail('mock search timed out');
}
test('book pass keeps original filters', async () => {
  const [, api] = setup((u) => {
    if (u.pathname.endsWith('/folders')) return [200, { data: { id: 1 } }];
    if (u.pathname.endsWith('/mydbs')) return [200, { data: [{ id: 7, title: 'A' }] }];
    return searchReply(u.searchParams.get('myDbIds') && !u.searchParams.get('dbFolderIds') ? [1, 2] : [1]);
  });
  const { items } = await search(api, [{ key: 'a', queries: [['a']] }, { key: 'b', queries: [['b']] }], { scope: { dbFolderIds: [9] } });
  assert.deepEqual(items.map(r => r.candidates.map(c => c.id)), [[1], [1]]);
});
test('manual formula is validated and reaches query', async () => {
  const calls = [];
  const [load, api] = setup(u => { calls.push(...u.searchParams.getAll('textIncludes')); return searchReply([]); });
  await search(api, load([{ text: '42', formulas: ['  x^{19}+9  '] }]), { autoScope: false });
  assert.deepEqual(calls, ['x^{19}+9']);
  assert.throws(() => load([{ formulas: [42] }]), /formulas/);
});
test('all failures are an error, successful zero is not', async () => {
  const [, api] = setup(u => u.searchParams.get('textIncludes') === 'bad' ? [503, {}] : searchReply([]));
  const { items } = await search(api, [{ key: 'bad', queries: [['bad']] }, { key: 'empty', queries: [['empty']] }], { autoScope: false });
  assert.match(items[0].error, /503/);
  assert.equal(items[1].error, null);
});
test('failed second append returns paper ID and confirmed batch count', async () => {
  let ids = [];
  const [, api] = setup((u, opt) => {
    if (opt.method === 'GET') return cellsReply(ids);
    const body = JSON.parse(opt.body);
    if (body.afterNumber) return [400, {}];
    ids = body.cellIds;
    return [200, {}];
  });
  const result = await api.addCells(12, Array.from({ length: 51 }, (_, i) => i + 100));
  assert.equal(result.paperId, 12);
  assert.equal(result.completedBatches, 1);
  assert.equal(result.completedCells, 50);
  assert.match(result.error, /400/);
});
test('append confirmed by readback after 5xx is not duplicated', async () => {
  const ids = []; let writes = 0, reads = 0;
  const [, api] = setup((u, opt) => {
    if (opt.method === 'GET') { reads++; return cellsReply(ids); }
    writes++;
    ids.push(...JSON.parse(opt.body).cellIds);
    return [503, {}];
  });
  assert.equal((await api.addCells(12, [8, 9])).orderOk, true);
  assert.equal(writes, 1);
  assert.ok(reads >= 2);
});
test('ambiguous create is never retried by title', async () => {
  let writes = 0;
  const [, api] = setup(() => { writes++; return [503, {}]; });
  await assert.rejects(api.createPaper('test', 1), /확인/);
  assert.equal(writes, 1);
});
test('first POST 401 refreshes token once and commits only once', async () => {
  let attempts = 0, commits = 0;
  const [, api] = setup((u, opt) => {
    assert.equal(opt.method, 'POST');
    assert.equal(opt.headers.Authorization, 'Bearer fake-' + (attempts + 1));
    if (++attempts === 1) return [401, {}];
    commits++;
    return [200, { data: { id: 12 } }];
  });
  assert.equal(await api.createPaper('mock', 1), 12);
  assert.equal(attempts, 2);
  assert.equal(commits, 1);
});
