#!/usr/bin/env node
// Record in MathBank that existing items were used in a school print
// ("이 원본이 26 행신 공수2 기말 프린트에 포함됐다").
//
//   node tools/mathbank_membership.cjs record --db <mathbank.sqlite> --name "26 행신 공수2 기말 프린트2" \
//        --paper 2261630 --cells 1860,467938,... [--out DIR] [--dry-run]
//
// Each 수학비서 cell is linked only through MathBank's own identity map
// (external_identities workroom_item/mathsecr, state resolved). Cells without a
// single resolved problem are listed as unmatched and never linked.
// One worksheet source + one occurrence per matched item, written under the
// MathBank writer lock (MathBankData/index.lock) in one IMMEDIATE transaction,
// with a row-level backup written before the write and an independent readback
// after it. Needs Node 22.13+ (node:sqlite). See tools/USAGE.md.

'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ADAPTER = 'subi-print-usage-v1';
const SITE = 'https://www.mathsecr.com';
const SUBJECTS = {
  공수1: '공통수학1', 공통수학1: '공통수학1', 공수2: '공통수학2', 공통수학2: '공통수학2', 대수: '대수',
  미적1: '미적분Ⅰ', 미적분1: '미적분Ⅰ', 미적분Ⅰ: '미적분Ⅰ', 미적2: '미적분Ⅱ', 미적분2: '미적분Ⅱ', 미적분Ⅱ: '미적분Ⅱ',
  확통: '확률과 통계', 확률과통계: '확률과 통계', '확률과 통계': '확률과 통계', 기하: '기하',
};
const SHORT = { 공통수학1: '공수1', 공통수학2: '공수2', 대수: '대수', 미적분Ⅰ: '미적1', 미적분Ⅱ: '미적2', '확률과 통계': '확통', 기하: '기하' };
// 2022 개정: 공통수학1·2 are 고1 subjects. Other subjects need an explicit --grade.
const GRADE_BY_SUBJECT = { 공통수학1: 1, 공통수학2: 1 };

// "26 행신 공수2 기말 프린트2" / "주엽 26 미적1 기말 프린트" -> fields. Tokens it does not know stay in `extra`.
function parsePrintName(name) {
  const out = { school: null, year: null, subject: null, exam: null, part: null, extra: [] };
  for (const t of String(name).trim().split(/\s+/)) {
    let m;
    if (out.year == null && /^\d{2}$/.test(t)) out.year = 2000 + Number(t);
    else if (out.year == null && /^20\d{2}$/.test(t)) out.year = Number(t);
    else if (!out.exam && (t === '중간' || t === '기말')) out.exam = t;
    else if (!out.subject && SUBJECTS[t]) out.subject = SUBJECTS[t];
    else if ((m = /^(?:심화)?프린트(\d*)$/.exec(t))) out.part = m[1] ? Number(m[1]) : null;
    else if (!out.school) out.school = t;
    else out.extra.push(t);
  }
  return out;
}

function sha256(s) { return crypto.createHash('sha256').update(s).digest('hex'); }
const jd = (x) => JSON.stringify(x);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function acquireLock(lockPath, info, waitMs, pollMs) {
  const body = jd(info);
  const deadline = Date.now() + waitMs;
  for (;;) {
    try { fs.writeFileSync(lockPath, body, { flag: 'wx' }); return body; } catch (e) { if (e.code !== 'EEXIST') throw e; }
    if (Date.now() >= deadline) {
      let holder = '';
      try { holder = fs.readFileSync(lockPath, 'utf8'); } catch {}
      throw new Error(`MathBank writer lock busy (${lockPath}): ${holder || 'unknown holder'}; nothing written`);
    }
    await sleep(pollMs);
  }
}
function releaseLock(lockPath, body) {
  try { if (fs.readFileSync(lockPath, 'utf8') === body) fs.unlinkSync(lockPath); } catch {}
  return !fs.existsSync(lockPath) || fs.readFileSync(lockPath, 'utf8') !== body;
}

function mapCells(db, cells) {
  const q = db.prepare(`SELECT DISTINCT x.problem_id, x.occurrence_id, p.current_revision_id
    FROM external_identities x JOIN problems p ON p.id = x.problem_id
    WHERE x.namespace = 'workroom_item' AND x.scope_key = 'mathsecr' AND x.state = 'resolved' AND x.external_id = ?`);
  return cells.map((cell, i) => {
    const rows = q.all(String(cell));
    const problems = [...new Set(rows.map((r) => r.problem_id))];
    const base = { position: i + 1, cell: Number(cell) };
    if (problems.length === 1) return { ...base, status: 'matched', problem_id: rows[0].problem_id, existing_occurrence: rows[0].occurrence_id, matched_revision: rows[0].current_revision_id };
    return { ...base, status: 'unmatched', reason: problems.length ? 'ambiguous' : 'not_in_mathbank', candidates: problems };
  });
}

function resolveSchool(db, school) {
  if (!school) return null;
  const rows = db.prepare(`SELECT DISTINCT s.id FROM schools s WHERE s.name IN (?, ?)
    OR EXISTS (SELECT 1 FROM json_each(s.aliases_json) a WHERE a.value IN (?, ?))`).all(school, school + '고', school, school + '고');
  return rows.length === 1 ? rows[0].id : null;
}

function resolveSubject(db, label) {
  if (!label) return null;
  const rows = db.prepare("SELECT id FROM subjects WHERE label = ? AND curriculum_version_id = '2022_revised'").all(label);
  return rows.length === 1 ? rows[0].id : null;
}

// The print this record describes: same adapter + paper + the same matched cells in the same positions.
function findExisting(db, paperId, items) {
  const want = jd(items.filter((x) => x.status === 'matched').map((x) => [x.position, String(x.cell), x.problem_id]));
  const sources = db.prepare(`SELECT * FROM sources WHERE kind = 'worksheet'
    AND json_extract(source_metadata_json, '$.adapter') = ? AND json_extract(source_metadata_json, '$.paper_id') = ?`).all(ADAPTER, paperId);
  const occ = db.prepare('SELECT original_ordinal, item_code, problem_id FROM problem_occurrences WHERE source_id = ? ORDER BY original_ordinal');
  return sources.find((s) => jd(occ.all(s.id).map((o) => [o.original_ordinal, o.item_code, o.problem_id])) === want) || null;
}

function membershipOf(o, f, items, ids) {
  const matched = items.filter((x) => x.status === 'matched');
  return {
    version: 1,
    name: o.name,
    school: f.school, school_id: ids.school_id,
    grade: f.grade, year: f.year, semester: f.semester,
    subject: f.subject, subject_id: ids.subject_id,
    exam: f.exam, part: f.part,
    site: { paper_id: o.paperId, url: `${SITE}/mypaper/${o.paperId}`, ...(o.sourcePaperId ? { source_paper_id: o.sourcePaperId } : {}) },
    positions: items.map((x) => ({ position: x.position, cell: x.cell, status: x.status, problem_id: x.problem_id || null, ...(x.reason ? { reason: x.reason } : {}) })),
    counts: { total: items.length, matched: matched.length, unmatched: items.length - matched.length },
    recorded_at: o.now, recorded_by: o.actor, evidence_id: ids.evidence_id,
    ...(o.receipt ? { receipt: o.receipt } : {}),
  };
}

// opts: { db, name, paperId, cells[], sourcePaperId?, school?, grade?, year?, semester?, subject?, exam?, part?,
//         sourceFile?, actor?, outDir?, receipt?, dryRun?, lockWaitMs?, lockPollMs?, busyTimeoutMs? }
async function recordMembership(opts) {
  const { DatabaseSync } = require('node:sqlite');
  if (!opts.db || !fs.existsSync(opts.db)) throw new Error('MathBank DB not found: ' + opts.db);
  if (!opts.name) throw new Error('print name required');
  const paperId = Number(opts.paperId);
  if (!Number.isInteger(paperId) || paperId <= 0) throw new Error('paper id required');
  const cells = (opts.cells || []).map(Number);
  if (!cells.length || cells.some((c) => !Number.isInteger(c) || c <= 0)) throw new Error('ordered cell ids required');

  const parsed = parsePrintName(opts.name);
  const pick = (k) => (opts[k] != null && opts[k] !== '' ? opts[k] : parsed[k]);
  const subject = pick('subject') ? SUBJECTS[pick('subject')] || pick('subject') : null;
  const f = {
    school: pick('school'), year: pick('year') != null ? Number(pick('year')) : null,
    semester: opts.semester != null ? Number(opts.semester) : null, subject, exam: pick('exam'),
    part: pick('part') != null ? Number(pick('part')) : null,
    grade: opts.grade != null ? Number(opts.grade) : GRADE_BY_SUBJECT[subject] ?? null,
  };
  const now = new Date().toISOString();
  const o = { ...opts, paperId, now, actor: opts.actor || 'subi-site_search' };
  const fileSha = opts.sourceFile ? sha256(fs.readFileSync(opts.sourceFile)) : null;
  const sourceSha = fileSha || sha256(`${ADAPTER}|paper:${paperId}|cells:${cells.join(',')}|name:${opts.name}`);
  const label = f.year && f.school && f.subject && f.exam
    ? { label: `${String(f.year).slice(2)} ${f.school} ${SHORT[f.subject] || f.subject} ${f.exam} 프린트`, year: f.year, semester: f.semester, period: f.exam, part: f.part }
    : null;

  const plan = (db) => {
    const items = mapCells(db, cells);
    const ids = { school_id: resolveSchool(db, f.school), subject_id: resolveSubject(db, f.subject), evidence_id: crypto.randomUUID() };
    const existing = findExisting(db, paperId, items);
    return { items, ids, existing };
  };
  const summary = (status, p, extra) => ({
    status, name: opts.name, paper_id: paperId, fields: f,
    matched: p.items.filter((x) => x.status === 'matched').length,
    unmatched: p.items.filter((x) => x.status !== 'matched').map(({ position, cell, reason, candidates }) => ({ position, cell, reason, candidates })),
    ...extra,
  });

  if (opts.dryRun) {
    const db = new DatabaseSync(opts.db, { readOnly: true });
    try {
      const p = plan(db);
      const meta = p.existing && JSON.parse(p.existing.source_metadata_json);
      const status = !p.items.some((x) => x.status === 'matched') ? 'nothing_matched'
        : !p.existing ? 'would_record' : meta.print_membership_v1 ? 'already_recorded' : 'would_enrich';
      return summary(status, p, { dry_run: true, source_id: p.existing ? p.existing.id : null, items: p.items });
    } finally { db.close(); }
  }

  const outDir = opts.outDir || process.cwd();
  fs.mkdirSync(outDir, { recursive: true });
  const stamp = now.replace(/[:.]/g, '-');
  const base = path.join(outDir, `mathbank-membership-${paperId}-${stamp}`);
  const lockPath = path.join(path.dirname(path.resolve(opts.db)), 'index.lock');
  const lockBody = await acquireLock(lockPath, { pid: process.pid, purpose: ADAPTER, name: opts.name, paper_id: paperId, started_at: now },
    opts.lockWaitMs ?? 30 * 60 * 1000, opts.lockPollMs ?? 5000);
  let result, released;
  try {
    const db = new DatabaseSync(opts.db, { timeout: opts.busyTimeoutMs ?? 60000 });
    let p, sourceId, before, neighbors;
    try {
      db.exec('PRAGMA foreign_keys = ON');
      db.exec('BEGIN IMMEDIATE');
      try {
        p = plan(db);
        const matched = p.items.filter((x) => x.status === 'matched');
        const membership = membershipOf(o, f, p.items, p.ids);
        const meta = p.existing && JSON.parse(p.existing.source_metadata_json);
        if (!matched.length || (meta && meta.print_membership_v1)) {
          db.exec('ROLLBACK');
          result = summary(!matched.length ? 'nothing_matched' : 'already_recorded', p, { source_id: p.existing ? p.existing.id : null });
        } else {
          const pids = [...new Set(matched.map((x) => x.problem_id))];
          const marks = pids.map(() => '?').join(',');
          before = db.prepare(`SELECT id, current_revision_id, status, updated_at FROM problems WHERE id IN (${marks}) ORDER BY id`).all(...pids);
          neighbors = p.existing ? [] : db.prepare(`SELECT * FROM problem_neighbors WHERE problem_id IN (${marks}) OR neighbor_id IN (${marks})`).all(...pids, ...pids);
          sourceId = p.existing ? p.existing.id : crypto.randomUUID();
          const occIds = p.existing ? [] : matched.map(() => crypto.randomUUID());
          // Row-level backup: every row this write changes, written before the write.
          const backup = {
            db: path.resolve(opts.db), data_version: db.prepare('PRAGMA data_version').get().data_version, at: now,
            mode: p.existing ? 'enrich' : 'insert', source_pre_image: p.existing || null,
            inserted: { evidence: [p.ids.evidence_id], sources: p.existing ? [] : [sourceId], problem_occurrences: occIds },
            invalidated_problem_neighbors: neighbors,
          };
          fs.writeFileSync(base + '.backup.json', JSON.stringify(backup, null, 1), { flag: 'wx' });
          db.prepare('INSERT INTO evidence(id, kind, actor, details_json) VALUES (?, ?, ?, ?)').run(p.ids.evidence_id, 'source', o.actor,
            jd({ adapter: ADAPTER, name: opts.name, paper_id: paperId, cells, items: p.items, source_sha256: sourceSha, source_file_sha256: fileSha, receipt: opts.receipt || null }));
          if (p.existing) {
            const next = { ...meta, usage_label_v1: meta.usage_label_v1 || label, print_membership_v1: membership };
            db.prepare(`UPDATE sources SET source_metadata_json = ?, school_id = COALESCE(school_id, ?), source_subject_id = COALESCE(source_subject_id, ?),
              source_subject_text = COALESCE(source_subject_text, ?), year = COALESCE(year, ?), term = COALESCE(term, ?), grade = COALESCE(grade, ?),
              updated_at = ? WHERE id = ?`).run(jd(next), p.ids.school_id, p.ids.subject_id, f.subject, f.year, f.semester, f.grade, now, sourceId);
          } else {
            const meta2 = {
              adapter: ADAPTER, record_kind: 'print_usage', paper_id: paperId, site_url: `${SITE}/mypaper/${paperId}`,
              evidence_id: p.ids.evidence_id, matching_method: 'mathsecr cell id -> MathBank workroom_item/mathsecr resolved identity',
              recorded_scope: 'print only', ...(label ? { usage_label_v1: label } : {}), print_membership_v1: membership,
            };
            db.prepare(`INSERT INTO sources(id, source_sha256, kind, title, school_id, source_subject_text, source_subject_id, year, term, grade,
              binding_status, source_metadata_json) VALUES (?, ?, 'worksheet', ?, ?, ?, ?, ?, ?, ?, 'verified', ?)`)
              .run(sourceId, sourceSha, opts.name, p.ids.school_id, f.subject, p.ids.subject_id, f.year, f.semester, f.grade, jd(meta2));
            const ins = db.prepare(`INSERT INTO problem_occurrences(id, problem_id, source_id, display_number, original_ordinal, item_code, source_kind_raw)
              VALUES (?, ?, ?, ?, ?, ?, 'print_usage')`);
            matched.forEach((x, i) => ins.run(occIds[i], x.problem_id, sourceId, String(x.position), x.position, String(x.cell)));
          }
          db.exec('COMMIT');
          result = summary(p.existing ? 'enriched' : 'recorded', p, {
            source_id: sourceId, evidence_id: p.ids.evidence_id, backup: base + '.backup.json',
            neighbors_invalidated: neighbors.length, items: p.items,
          });
        }
      } catch (e) {
        if (db.isTransaction) db.exec('ROLLBACK');
        throw e;
      }
    } finally { db.close(); }

    if (sourceId && before) result.readback = readback(DatabaseSync, opts.db, sourceId, p, before);
  } finally { released = releaseLock(lockPath, lockBody); }
  result.writer_lock_released = released;
  if (result.status === 'recorded' || result.status === 'enriched') {
    result.receipt = base + '.receipt.json';
    fs.writeFileSync(result.receipt, JSON.stringify(result, null, 1), { flag: 'wx' });
    if (!result.readback.ok) throw Object.assign(new Error('MathBank readback mismatch; see ' + result.receipt), { result });
  }
  return result;
}

function readback(DatabaseSync, dbPath, sourceId, p, before) {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const s = db.prepare('SELECT source_metadata_json FROM sources WHERE id = ?').get(sourceId);
    const occ = db.prepare('SELECT original_ordinal, item_code, problem_id FROM problem_occurrences WHERE source_id = ? ORDER BY original_ordinal').all(sourceId);
    const want = p.items.filter((x) => x.status === 'matched').map((x) => [x.position, String(x.cell), x.problem_id]);
    const pm = s && JSON.parse(s.source_metadata_json).print_membership_v1;
    const pids = before.map((r) => r.id);
    const after = db.prepare(`SELECT id, current_revision_id, status, updated_at FROM problems WHERE id IN (${pids.map(() => '?').join(',')}) ORDER BY id`).all(...pids);
    const evidence = !!db.prepare('SELECT 1 FROM evidence WHERE id = ?').get(p.ids.evidence_id);
    const checks = {
      source: !!s, membership: !!pm && pm.evidence_id === p.ids.evidence_id,
      occurrences_in_order: jd(occ.map((o) => [o.original_ordinal, o.item_code, o.problem_id])) === jd(want),
      evidence, matched_problems_unchanged: jd(after) === jd(before),
    };
    return { ok: Object.values(checks).every(Boolean), ...checks };
  } finally { db.close(); }
}

// ---------------------------------------------------------------- CLI glue (also used by site_search create-paper)
function readCellsArg(args) {
  if (args['cells-file']) {
    const raw = JSON.parse(fs.readFileSync(args['cells-file'], 'utf8'));
    const list = Array.isArray(raw) ? raw : raw.cells || raw.orderedCellIds;
    return { cells: list.map((x) => Number(typeof x === 'object' ? x.id ?? x.site_cell_id : x)).filter(Boolean), paperId: Array.isArray(raw) ? null : raw.paperId };
  }
  return { cells: args.cells == null || args.cells === true ? [] : String(args.cells).split(/[,\s|]+/).filter(Boolean).map(Number), paperId: null };
}

function optsFromArgs(args, over = {}) {
  const v = (k) => (args[k] == null || args[k] === true ? undefined : args[k]);
  return {
    db: v('mathbank-db') || v('db') || process.env.MATHBANK_DB,
    name: v('print-name') || v('name'),
    sourcePaperId: v('source-paper') ? Number(v('source-paper')) : undefined,
    school: v('school'), grade: v('grade'), year: v('year'), semester: v('semester'), subject: v('subject'), exam: v('exam'), part: v('part'),
    sourceFile: v('source-file'), actor: v('actor'), outDir: v('mathbank-out') || v('out'), receipt: v('receipt'),
    lockWaitMs: v('lock-wait') != null ? Number(v('lock-wait')) * 1000 : undefined,
    dryRun: !!args['dry-run'],
    ...over,
  };
}

// site_search create-paper hook: never throws, so the paper result is always printed.
async function recordForPaper(args, paperId, cells) {
  try { return await recordMembership(optsFromArgs(args, { paperId, cells })); } catch (e) { return { status: 'failed', error: String(e && e.message || e), ...(e && e.result ? { result: e.result } : {}) }; }
}

module.exports = { parsePrintName, recordMembership, recordForPaper, optsFromArgs, ADAPTER };

if (require.main === module) {
  const argv = process.argv.slice(2);
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) args[a.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
    else args._.push(a);
  }
  if (args._[0] !== 'record') {
    console.error('usage: node tools/mathbank_membership.cjs record --db PATH --name "26 행신 공수2 기말 프린트2" --paper ID (--cells 1,2 | --cells-file f.json)\n' +
      '       [--source-paper ID] [--school 행신] [--grade 1] [--year 2026] [--semester 2] [--subject 공수2] [--exam 기말] [--part 2]\n' +
      '       [--source-file HML] [--out DIR] [--lock-wait SEC] [--actor NAME] [--dry-run]');
    process.exit(1);
  }
  const { cells, paperId } = readCellsArg(args);
  recordMembership(optsFromArgs(args, { paperId: args.paper || paperId, cells }))
    .then((r) => { process.stdout.write(JSON.stringify(r, null, 1) + '\n'); })
    .catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
}
