'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');
const { parsePrintName, recordMembership, ADAPTER } = require('../tools/mathbank_membership.cjs');

// Minimal copy of the MathBank tables this tool touches (DDL as in MathBank core), plus FK parents as stubs.
const SCHEMA = `
CREATE TABLE assets(id TEXT PRIMARY KEY); CREATE TABLE exams(id TEXT PRIMARY KEY); CREATE TABLE imports(id TEXT PRIMARY KEY);
CREATE TABLE raw_payloads(id TEXT PRIMARY KEY); CREATE TABLE solutions(id TEXT PRIMARY KEY, problem_id TEXT, UNIQUE(id, problem_id));
CREATE TABLE source_bindings(id TEXT PRIMARY KEY, source_id TEXT, UNIQUE(id, source_id));
CREATE TABLE subjects(id TEXT PRIMARY KEY, curriculum_version_id TEXT NOT NULL, code TEXT NOT NULL, label TEXT NOT NULL);
CREATE TABLE schools(id TEXT PRIMARY KEY, name TEXT NOT NULL, aliases_json TEXT NOT NULL);
CREATE TABLE sources (
  id TEXT PRIMARY KEY NOT NULL,
  source_sha256 TEXT NOT NULL UNIQUE CHECK(length(source_sha256) = 64 AND source_sha256 NOT GLOB '*[^0-9a-f]*'),
  original_asset_id TEXT REFERENCES assets(id), kind TEXT NOT NULL CHECK(kind IN ('exam','worksheet','variant','textbook','other')),
  title TEXT NOT NULL, school_id TEXT REFERENCES schools(id), source_subject_text TEXT, source_subject_id TEXT REFERENCES subjects(id),
  year INTEGER, term INTEGER, grade INTEGER, exam_id TEXT REFERENCES exams(id),
  binding_status TEXT NOT NULL CHECK(binding_status IN ('claimed','verified','conflict')),
  source_metadata_json TEXT NOT NULL CHECK(json_valid(source_metadata_json)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
) STRICT;
CREATE TABLE problem_revisions(id TEXT PRIMARY KEY, problem_id TEXT NOT NULL, body_text TEXT, UNIQUE(id, problem_id));
CREATE TABLE problems (
  id TEXT PRIMARY KEY NOT NULL, current_revision_id TEXT NOT NULL, status TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  FOREIGN KEY(current_revision_id, id) REFERENCES problem_revisions(id, problem_id) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE problem_occurrences (
  id TEXT PRIMARY KEY NOT NULL, problem_id TEXT NOT NULL REFERENCES problems(id), source_id TEXT NOT NULL REFERENCES sources(id),
  display_number TEXT, original_ordinal INTEGER, item_code TEXT, source_kind_raw TEXT, original_revision_label TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE(id, source_id), UNIQUE(id, problem_id)
) STRICT;
CREATE TABLE evidence (
  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('source','provided_solution','authoring','generation_receipt','adoption_receipt','user_confirmation')),
  import_id TEXT REFERENCES imports(id), payload_id TEXT REFERENCES raw_payloads(id), asset_id TEXT REFERENCES assets(id),
  json_pointer TEXT, actor TEXT, details_json TEXT NOT NULL CHECK(json_valid(details_json)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
) STRICT;
CREATE TABLE external_identities (
  id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL REFERENCES sources(id),
  namespace TEXT NOT NULL CHECK(namespace IN ('public_item','renderer_local','exam_question','workroom_item','variant')),
  scope_key TEXT NOT NULL, external_id TEXT NOT NULL, problem_id TEXT REFERENCES problems(id), occurrence_id TEXT, binding_id TEXT,
  state TEXT NOT NULL CHECK(state IN ('resolved','unresolved','conflict')), evidence_id TEXT NOT NULL REFERENCES evidence(id),
  UNIQUE(source_id, namespace, scope_key, external_id),
  FOREIGN KEY(occurrence_id, source_id) REFERENCES problem_occurrences(id, source_id),
  FOREIGN KEY(occurrence_id, problem_id) REFERENCES problem_occurrences(id, problem_id)
) STRICT;
CREATE TABLE problem_neighbors(problem_id TEXT NOT NULL, neighbor_id TEXT NOT NULL, score REAL NOT NULL, PRIMARY KEY(problem_id, neighbor_id)) STRICT, WITHOUT ROWID;
CREATE TRIGGER neighbors_occurrence_insert AFTER INSERT ON problem_occurrences
BEGIN
  DELETE FROM problem_neighbors WHERE problem_id=NEW.problem_id OR neighbor_id=NEW.problem_id;
END;`;

const HEX = (c) => c.repeat(64);
function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mb-membership-'));
  const file = path.join(dir, 'MathBankData', 'mathbank.sqlite');
  fs.mkdirSync(path.dirname(file));
  const db = new DatabaseSync(file);
  db.exec(SCHEMA);
  db.exec(`INSERT INTO subjects VALUES ('s-c2','2022_revised','common_math_2','공통수학2'), ('s-calc1','2022_revised','calculus_1','미적분Ⅰ');
    INSERT INTO schools VALUES ('sch-hs','행신고','["행신고등학교"]'), ('sch-jy','주엽고','["주엽"]');
    INSERT INTO evidence(id,kind,details_json) VALUES ('ev0','source','{}');
    INSERT INTO sources(id,source_sha256,kind,title,binding_status,source_metadata_json) VALUES ('exam1','${HEX('a')}','exam','교육청 고1','verified','{}');`);
  // cells 101..103 -> p1..p3; 104 -> two problems (ambiguous); 105 not in MathBank
  const add = (cell, pid, n) => {
    db.exec(`INSERT INTO problem_revisions VALUES ('r-${pid}','${pid}','본문 ${pid}'); INSERT INTO problems(id,current_revision_id,status) VALUES ('${pid}','r-${pid}','ready');
      INSERT INTO problem_occurrences(id,problem_id,source_id,display_number,original_ordinal) VALUES ('o-${pid}','${pid}','exam1','${n}',${n});
      INSERT INTO external_identities(id,source_id,namespace,scope_key,external_id,problem_id,occurrence_id,state,evidence_id)
        VALUES ('x-${pid}','exam1','workroom_item','mathsecr','${cell}','${pid}','o-${pid}','resolved','ev0');`);
  };
  add(101, 'p1', 1); add(102, 'p2', 2); add(103, 'p3', 3); add(104, 'p4a', 4);
  db.exec(`INSERT INTO sources(id,source_sha256,kind,title,binding_status,source_metadata_json) VALUES ('exam2','${HEX('b')}','exam','교육청 고2','verified','{}');
    INSERT INTO problem_revisions VALUES ('r-p4b','p4b','x'); INSERT INTO problems(id,current_revision_id,status) VALUES ('p4b','r-p4b','ready');
    INSERT INTO external_identities(id,source_id,namespace,scope_key,external_id,problem_id,state,evidence_id) VALUES ('x-p4b','exam2','workroom_item','mathsecr','104','p4b','resolved','ev0');
    INSERT INTO problem_neighbors VALUES ('p1','p3',0.9), ('p3','p1',0.9), ('p3','p4a',0.5);`);
  db.close();
  return { dir, file, out: path.join(dir, 'out') };
}
const q = (file, sql, ...a) => { const db = new DatabaseSync(file, { readOnly: true }); try { return db.prepare(sql).all(...a); } finally { db.close(); } };
const base = (fx, over) => ({ db: fx.file, outDir: fx.out, name: '26 행신 공수2 기말 프린트2', paperId: 2261630, lockWaitMs: 0, ...over });

test('parses school print names in both word orders', () => {
  assert.deepEqual(parsePrintName('26 행신 공수2 기말 프린트2'), { school: '행신', year: 2026, subject: '공통수학2', exam: '기말', part: 2, extra: [] });
  assert.deepEqual(parsePrintName('주엽 26 미적1 기말 프린트'), { school: '주엽', year: 2026, subject: '미적분Ⅰ', exam: '기말', part: null, extra: [] });
});

test('links matched items in print order and lists unmatched ones without linking', async () => {
  const fx = fixture();
  const r = await recordMembership(base(fx, { cells: [103, 105, 101, 104] }));
  assert.equal(r.status, 'recorded');
  assert.equal(r.matched, 2);
  assert.deepEqual(r.unmatched.map((u) => [u.position, u.cell, u.reason]), [[2, 105, 'not_in_mathbank'], [4, 104, 'ambiguous']]);
  assert.equal(r.readback.ok, true);
  assert.equal(r.writer_lock_released, true);
  assert.equal(fs.existsSync(path.join(path.dirname(fx.file), 'index.lock')), false);
  assert.deepEqual(q(fx.file, 'SELECT original_ordinal o, item_code c, problem_id p, source_kind_raw k FROM problem_occurrences WHERE source_id=? ORDER BY 1', r.source_id).map((x) => ({ ...x })),
    [{ o: 1, c: '103', p: 'p3', k: 'print_usage' }, { o: 3, c: '101', p: 'p1', k: 'print_usage' }]);
  const [s] = q(fx.file, 'SELECT * FROM sources WHERE id=?', r.source_id);
  assert.deepEqual([s.kind, s.title, s.school_id, s.source_subject_id, s.year, s.grade], ['worksheet', '26 행신 공수2 기말 프린트2', 'sch-hs', 's-c2', 2026, 1]);
  const meta = JSON.parse(s.source_metadata_json);
  assert.equal(meta.adapter, ADAPTER);
  assert.deepEqual(meta.usage_label_v1, { label: '26 행신 공수2 기말 프린트', year: 2026, semester: null, period: '기말', part: 2 });
  const pm = meta.print_membership_v1;
  assert.deepEqual([pm.school, pm.exam, pm.part, pm.site.paper_id, pm.counts], ['행신', '기말', 2, 2261630, { total: 4, matched: 2, unmatched: 2 }]);
  assert.deepEqual(pm.positions.map((x) => [x.position, x.status, x.problem_id]), [[1, 'matched', 'p3'], [2, 'unmatched', null], [3, 'matched', 'p1'], [4, 'unmatched', null]]);
  // Backup holds the neighbor rows the DB trigger invalidates; the matched problems are untouched.
  const backup = JSON.parse(fs.readFileSync(r.backup, 'utf8'));
  assert.equal(backup.invalidated_problem_neighbors.length, 3);
  assert.deepEqual(backup.inserted.problem_occurrences.length, 2);
  assert.equal(q(fx.file, 'SELECT count(*) n FROM problem_neighbors')[0].n, 0);
  assert.equal(JSON.parse(fs.readFileSync(r.receipt, 'utf8')).source_id, r.source_id);
});

test('rerun of the same print writes nothing', async () => {
  const fx = fixture();
  const first = await recordMembership(base(fx, { cells: [101, 102] }));
  const again = await recordMembership(base(fx, { cells: [101, 102] }));
  assert.deepEqual([first.status, again.status, again.source_id], ['recorded', 'already_recorded', first.source_id]);
  assert.equal(q(fx.file, "SELECT count(*) n FROM sources WHERE kind='worksheet'")[0].n, 1);
  assert.equal(q(fx.file, "SELECT count(*) n FROM problem_occurrences WHERE source_kind_raw='print_usage'")[0].n, 2);
});

test('an earlier print_usage record of the same print is enriched, not duplicated', async () => {
  const fx = fixture();
  const db = new DatabaseSync(fx.file);
  const old = { adapter: ADAPTER, record_kind: 'print_usage', paper_id: 2261630, evidence_id: 'ev0', usage_label_v1: { label: '26 행신 공수2 기말 프린트', year: 2026, semester: null, period: '기말', part: 2 } };
  db.exec(`INSERT INTO sources(id,source_sha256,kind,title,school_id,source_subject_text,source_subject_id,binding_status,source_metadata_json)
    VALUES ('old','${HEX('c')}','worksheet','행신 공수2 프린트2','sch-hs','공통수학2','s-c2','verified','${JSON.stringify(old)}');
    INSERT INTO problem_occurrences(id,problem_id,source_id,display_number,original_ordinal,item_code,source_kind_raw) VALUES
      ('u1','p1','old','1',1,'101','print_usage'), ('u2','p2','old','2',2,'102','print_usage');`);
  db.close();
  const r = await recordMembership(base(fx, { cells: [101, 102] }));
  assert.deepEqual([r.status, r.source_id, r.readback.ok], ['enriched', 'old', true]);
  const [s] = q(fx.file, "SELECT * FROM sources WHERE kind='worksheet'");
  const meta = JSON.parse(s.source_metadata_json);
  assert.equal(meta.evidence_id, 'ev0');
  assert.deepEqual(meta.usage_label_v1, old.usage_label_v1);
  assert.equal(meta.print_membership_v1.name, '26 행신 공수2 기말 프린트2');
  assert.deepEqual([s.title, s.year, s.grade], ['행신 공수2 프린트2', 2026, 1]);
  assert.equal(JSON.parse(fs.readFileSync(r.backup, 'utf8')).source_pre_image.id, 'old');
});

test('another writer holding index.lock blocks the write and its lock is left alone', async () => {
  const fx = fixture();
  const lock = path.join(path.dirname(fx.file), 'index.lock');
  fs.writeFileSync(lock, '4242');
  await assert.rejects(recordMembership(base(fx, { cells: [101] })), /writer lock busy.*4242/);
  assert.equal(fs.readFileSync(lock, 'utf8'), '4242');
  assert.equal(q(fx.file, "SELECT count(*) n FROM sources WHERE kind='worksheet'")[0].n, 0);
});

test('nothing matched and dry-run leave the DB unchanged', async () => {
  const fx = fixture();
  assert.equal((await recordMembership(base(fx, { cells: [105] }))).status, 'nothing_matched');
  const dry = await recordMembership(base(fx, { cells: [101, 105], dryRun: true }));
  assert.deepEqual([dry.status, dry.matched], ['would_record', 1]);
  assert.equal(q(fx.file, "SELECT count(*) n FROM sources WHERE kind='worksheet'")[0].n, 0);
  assert.equal(fs.existsSync(fx.out) && fs.readdirSync(fx.out).length, 0);
});

test('CLI record reads a site receipt and explicit fields', () => {
  const fx = fixture();
  const receipt = path.join(fx.dir, 'site-receipt.json');
  fs.writeFileSync(receipt, JSON.stringify({ paperId: 2102155, orderedCellIds: [101, 102] }));
  const out = execFileSync(process.execPath, [path.join(__dirname, '../tools/mathbank_membership.cjs'), 'record', '--db', fx.file,
    '--name', '주엽 26 미적1 기말 프린트', '--cells-file', receipt, '--grade', '2', '--semester', '2', '--out', fx.out], { encoding: 'utf8' });
  const r = JSON.parse(out);
  assert.deepEqual([r.status, r.paper_id, r.matched, r.fields.grade, r.fields.semester, r.fields.subject], ['recorded', 2102155, 2, 2, 2, '미적분Ⅰ']);
  const [s] = q(fx.file, 'SELECT school_id, term, grade FROM sources WHERE id=?', r.source_id);
  assert.deepEqual({ ...s }, { school_id: 'sch-jy', term: 2, grade: 2 });
});
