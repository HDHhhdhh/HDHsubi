'use strict';
// Synthetic DOM only. No browser, service, profile, backend or app state access.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const fixtureRoot = path.resolve(__dirname, '../test-fixtures/filter-collector');
const source = fs.readFileSync(path.join(__dirname, 'search_observation.js'), 'utf8');
const baseAdapter = JSON.parse(fs.readFileSync(path.join(fixtureRoot, 'filter-adapter.synthetic.json'), 'utf8'));
const clone = value => JSON.parse(JSON.stringify(value));
let checks = 0;
const check = (name, fn) => { fn(); checks++; };
function fixture() {
  let order = 0;
  const dom = {};
  const node = (content = '', attrs = {}) => ({textContent:content, attrs, order:order++, isConnected:true, hidden:false,
    getAttribute(name) { return Object.hasOwn(this.attrs, name) ? this.attrs[name] : null; },
    getClientRects() { return this.hidden ? [] : [{}]; },
    closest() { return this.hidden ? this : null; },
    matches(selector) { return (dom[selector] ?? []).includes(this); }});
  dom['#mode']=[node('내 문제지')];
  dom['.source-chip']=[node('교육청, 평가원')];
  dom['#scope-selected']=[node('', {'aria-checked':'true'})];
  dom['#filter-panel']=[node('', {'data-visible-panel':'filters'})];
  dom['.subject-chip']=[node('수학Ⅰ')];
  dom['.unit-chip']=[node('지수함수와 로그함수')];
  dom['.answer-kind-selected']=[node('', {'data-answer-kind':'객관식'}), node('', {'data-answer-kind':'단답형'})];
  for (const [selector,value] of [['#year-min','2007'],['#year-max','2026'],['#difficulty-min','1'],['#difficulty-max','5']]) {
    dom[selector]=[node('', {'data-visible-value':value})];
  }
  dom['.exclude-condition-selected']=[node('이미 담은 문제 제외')];
  dom['.content-selected']=[node('문제')];
  dom['.query-text']=[node('', {'data-value':'직선','data-mode':'include'})];
  dom['.query-formula']=[node('', {'data-value':'f(x)','data-mode':'exclude'})];
  dom['.query-chip']=[...dom['.query-text'],...dom['.query-formula']];
  dom['#count']=[node('검색결과 : 2개')];
  dom['.card']=[node('', {'data-id':'ID-A'}),node('', {'data-id':'ID-B'})];
  dom['#loading']=[node('', {'aria-busy':'false'})];
  return {dom,node};
}
function read(f, index, adapter = baseAdapter) {
  const input = {adapter, context:{attemptId:'synthetic-filter-attempt',submitId:index===0?null:'synthetic-submit',
    readEvidenceId:`synthetic-actual-read-${index}`,clockSource:'date-now',captureSource:'read-evidence-id'}};
  const sandbox = {Date, input, globalThis:undefined, crypto:undefined, performance:undefined,
    document:{title:'Synthetic filter study', querySelectorAll(selector) {
      return [...new Set(selector.split(',').flatMap(part=>f.dom[part]??[]))].sort((a,b)=>a.order-b.order);
    }},location:{href:'https://www.mathsecr.com/mypaper/synthetic'},
    getComputedStyle(el) { return {display:el.hidden?'none':'block',visibility:'visible'}; }};
  return clone(vm.runInNewContext(source+'\ncollectMathSecrSearchObservation(input);', sandbox));
}
function packet(f = fixture(), mutate) {
  const beforeSubmit = read(f,0);
  if (mutate) mutate(f);
  const submission = {submitId:'synthetic-submit',actionEvidenceId:'synthetic-search-action',action:'검색하기',
    surface:'offline-dom-test',completedAtUtc:new Date().toISOString(),url:beforeSubmit.raw.url,
    criteria:read(f,10).raw.criteria,resultCriteriaKey:null};
  const observations=[read(f,1),read(f,2),read(f,3)];
  return {schemaVersion:1,attemptId:'synthetic-filter-attempt',submission,beforeSubmit,observations};
}
check('all observed filter categories are bound', () => {
  const result = read(fixture(),0);
  assert.equal(result.raw.criteria.filterChips.length,11);
  const fields = Object.fromEntries(result.raw.criteria.filterChips.map(JSON.parse));
  assert.deepEqual(fields.subject,['수학Ⅰ']);
  assert.deepEqual(fields.unit,['지수함수와 로그함수']);
  assert.deepEqual(fields['answer-kind'],['객관식','단답형']);
  assert.deepEqual(fields['query-polarity'],['include','exclude']);
  assert.deepEqual(result.raw.criteria.chips,[{kind:'text',value:'직선'},{kind:'formula',value:'f(x)'}]);
});
check('legacy singleton descriptor is unchanged', () => {
  const adapter=clone(baseAdapter); adapter.filterChips={selector:'.subject-chip',read:'text'};
  assert.deepEqual(read(fixture(),0,adapter).raw.criteria.filterChips,['수학Ⅰ']);
});
check('legacy null remains empty', () => {
  const adapter=clone(baseAdapter); adapter.filterChips=null;
  assert.deepEqual(read(fixture(),0,adapter).raw.criteria.filterChips,[]);
});
check('hidden filter template is excluded', () => {
  const f=fixture(); const hidden=f.node('오래된 단원'); hidden.hidden=true; f.dom['.unit-chip'].push(hidden);
  assert.deepEqual(JSON.parse(read(f,0).raw.criteria.filterChips[2]),['unit',['지수함수와 로그함수']]);
});
check('absent optional active group is explicit', () => {
  const f=fixture(); f.dom['.unit-chip']=[];
  assert.deepEqual(JSON.parse(read(f,0).raw.criteria.filterChips[2]),['unit',[]]);
});
check('missing required filter panel fails closed', () => {
  const f=fixture(); f.dom['#filter-panel']=[];
  assert.throws(()=>read(f,0),/cardinality mismatch/);
});
check('ambiguous required range field fails closed', () => {
  const f=fixture(); f.dom['#year-min'].push(f.node('',{'data-visible-value':'2010'}));
  assert.throws(()=>read(f,0),/cardinality mismatch/);
});
check('duplicate filter key fails closed', () => {
  const adapter=clone(baseAdapter); adapter.filterChips[1].key=adapter.filterChips[0].key;
  assert.throws(()=>read(fixture(),0,adapter),/duplicate filter/);
});
check('missing observed attribute is not guessed', () => {
  const f=fixture(); delete f.dom['.query-text'][0].attrs['data-mode'];
  assert.throws(()=>read(f,0),/missing observed filter/);
});
for (const invalid of [-1,1.5,'1',false,null]) check(`strict cardinality rejects ${JSON.stringify(invalid)}`, () => {
  const adapter=clone(baseAdapter); adapter.filterChips[0].minCount=invalid;
  assert.throws(()=>read(fixture(),0,adapter),/invalid filter descriptor cardinality/);
});
check('blank observed filter string is not accepted', () => {
  const f=fixture(); f.dom['.subject-chip'][0].textContent=' ';
  assert.throws(()=>read(f,0),/nonblank canonical/);
});
check('typed observed JSON scalar remains typed in encoded string', () => {
  const f=fixture(); f.dom['#filter-panel'][0].attrs['data-json']='{"selected":false}';
  const adapter=clone(baseAdapter); adapter.filterChips[0]={key:'flag',selector:'#filter-panel',read:'attribute',attribute:'data-json',jsonPath:['selected'],minCount:1,maxCount:1};
  assert.equal(read(f,0,adapter).raw.criteria.filterChips[0],'["flag",[false]]');
});
check('nonfinite observed JSON scalar cannot serialize as null', () => {
  const f=fixture(); f.dom['#filter-panel'][0].attrs['data-json']='{"selected":1e400}';
  const adapter=clone(baseAdapter); adapter.filterChips[0]={key:'flag',selector:'#filter-panel',read:'attribute',attribute:'data-json',jsonPath:['selected'],minCount:1,maxCount:1};
  assert.throws(()=>read(f,0,adapter),/nonfinite observed filter/);
});
check('JSON escaping prevents filter key/value collision', () => {
  const f=fixture(); f.dom['.subject-chip'][0].textContent='a","b';
  assert.deepEqual(JSON.parse(read(f,0).raw.criteria.filterChips[1]),['subject',['a","b']]);
});
for (const invalid of [-1, 0.5, '1', false, null]) check(`strict maximum rejects ${JSON.stringify(invalid)}`, () => {
  const adapter=clone(baseAdapter); adapter.filterChips[0].maxCount=invalid;
  assert.throws(()=>read(fixture(),0,adapter),/invalid filter descriptor cardinality/);
});
check('maximum below minimum is rejected', () => {
  const adapter=clone(baseAdapter); adapter.filterChips[0].minCount=2; adapter.filterChips[0].maxCount=1;
  assert.throws(()=>read(fixture(),0,adapter),/invalid filter descriptor cardinality/);
});
for (const key of ['', ' spaced ', null, 1]) check(`invalid filter key ${JSON.stringify(key)}`, () => {
  const adapter=clone(baseAdapter); adapter.filterChips[0].key=key;
  assert.throws(()=>read(fixture(),0,adapter),/canonical string/);
});
check('object JSON values cannot become a filter scalar', () => {
  const f=fixture(); f.dom['#filter-panel'][0].attrs['data-json']='{"selected":{}}';
  const adapter=clone(baseAdapter); adapter.filterChips[0]={key:'flag',selector:'#filter-panel',read:'attribute',attribute:'data-json',jsonPath:['selected'],minCount:1,maxCount:1};
  assert.throws(()=>read(f,0,adapter),/must be scalar/);
});
check('typed zero survives JSON encoding', () => {
  const f=fixture(); f.dom['#filter-panel'][0].attrs['data-json']='{"selected":0}';
  const adapter=clone(baseAdapter); adapter.filterChips[0]={key:'zero',selector:'#filter-panel',read:'attribute',attribute:'data-json',jsonPath:['selected'],minCount:1,maxCount:1};
  assert.equal(read(f,0,adapter).raw.criteria.filterChips[0],'["zero",[0]]');
});
check('descriptor array order and DOM group order are separate', () => {
  const adapter=clone(baseAdapter); adapter.filterChips.reverse();
  const fields=read(fixture(),0,adapter).raw.criteria.filterChips.map(JSON.parse);
  assert.equal(fields[0][0],'query-polarity');
  assert.deepEqual(fields[0][1],['include','exclude']);
});
const cases={normal:packet()};
for (const [name,mutate] of Object.entries({
  subject:f=>{f.dom['.subject-chip'][0].textContent='수학Ⅱ';},
  unit:f=>{f.dom['.unit-chip'][0].textContent='삼각함수';},
  answer:f=>{f.dom['.answer-kind-selected'][0].attrs['data-answer-kind']='주관식';},
  year:f=>{f.dom['#year-min'][0].attrs['data-visible-value']='2018';},
  difficulty:f=>{f.dom['#difficulty-max'][0].attrs['data-visible-value']='4';},
  exclusion:f=>{f.dom['.exclude-condition-selected'][0].textContent='해설 없는 문제 제외';},
  polarity:f=>{f.dom['.query-text'][0].attrs['data-mode']='exclude';},
  content:f=>{f.dom['.content-selected'][0].textContent='해설';}
})) {
  cases[`filter-change-${name}`]=packet(fixture(),mutate);
  check(`${name} change alters criteria even with same count and IDs`,()=> {
    assert.notDeepEqual(cases[`filter-change-${name}`].beforeSubmit.raw.criteria.filterChips,
      cases[`filter-change-${name}`].submission.criteria.filterChips);
    assert.deepEqual(cases[`filter-change-${name}`].beforeSubmit.raw.result,cases[`filter-change-${name}`].observations[0].raw.result);
  });
  cases[`post-submit-drift-${name}`]=packet();
  const driftFixture=fixture(); mutate(driftFixture);
  cases[`post-submit-drift-${name}`].observations[1]=read(driftFixture,2);
}
cases['reused-capture']=packet(); cases['reused-capture'].observations[1]=clone(cases['reused-capture'].observations[0]);
cases['reused-action']=packet(); cases['reused-action'].observations[0].readEvidenceId=cases['reused-action'].submission.actionEvidenceId;
cases['reused-action'].observations[0].raw.captureId=cases['reused-action'].submission.actionEvidenceId;
cases['zero-result']=packet(); for (const o of cases['zero-result'].observations) {o.raw.result.count=0;o.raw.result.orderedIds=[];}
cases['partial-cards']=packet(); for (const o of cases['partial-cards'].observations) o.raw.result.count=100;
cases['changed-order']=packet(); cases['changed-order'].observations[2].raw.result.orderedIds.reverse();
cases['loading-tail']=packet(); cases['loading-tail'].observations[2].raw.result.loading=true;
cases['stale-native-submit']=packet(); cases['stale-native-submit'].observations[1].raw.result.observedSubmitId='previous-submit';
if (process.argv[2]) fs.writeFileSync(path.resolve(process.argv[2]),JSON.stringify(cases,null,2)+'\n',{flag:'wx'});
console.log(`PASS Filter Collector: ${checks} checks; ${Object.keys(cases).length} packet fixtures; synthetic DOM only`);
