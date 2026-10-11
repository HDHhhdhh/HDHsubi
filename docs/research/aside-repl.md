# R1 · Aside REPL 공식 사양과 현재 설치본 확인

확인 날짜: **2026-10-11 (Asia/Seoul)**. 조사 기준: `main e016ab7`. 이 PR은 이 문서만 추가한다. 코드·fixture·정책은 바꾸지 않는다.

공식 문서 위치를 확인했다. 현재 설치본의 REPL에서 기존 `search_observation.js`를 simulator에 실행했고, 기본 clock/capture 경로가 통과했다. 설치본의 도움말과 실제 API에는 차이가 있다. Phase 3b는 아래에서 확인한 API만 사용해야 한다.

## 1. 출처와 확인 범위

| 출처 | URL / 확인 방법 | 확인 날짜 |
|---|---|---|
| Aside 공식 사이트 | [Aside](https://aside.com/)의 Docs 링크가 공식 Help Center로 연결됨 | 2026-10-11 |
| 공식 Help Center | [docs.aside.com](https://docs.aside.com/), [문서 목록](https://docs.aside.com/llms.txt) | 2026-10-11 |
| 공식 개발자 안내 | [Use the CLI, MCP, and REPL](https://docs.aside.com/help/developers) | 2026-10-11 |
| 설치본의 내장 안내 | `aside --version`, `aside --help`, `aside --host local guide`, `aside --host local guide repl` | 2026-10-11 |
| 설치본의 세션 API 안내 | `aside --host local skills show aside` | 2026-10-11 |
| 현재 API 관측 | 하나의 `aside --host local repl`에서 새 simulator 탭을 열고 판독. 실제 계정 웹페이지에는 접근하지 않음 | 2026-10-11 |

CLI는 **1.26.916.1741**, 내장 guide의 Skill version은 **3**이다. 로컬 브라우저 실행 파일의 ProductVersion은 **1.0.928.2**다. 실행 중 daemon 경로의 버전은 **1.26.1011.1437**이다. 세 버전은 서로 다른 구성요소의 값이다. CLI가 업데이트 가능 버전 **1.26.1010.1739**를 알렸지만 업데이트는 실행하지 않았다.

공식 웹 안내에는 `--session` 예시가 있다. 이 설치본의 `--help`에는 그 옵션이 없고 `aside session resume`가 있다. 웹 예시를 설치본에서 검증된 명령으로 간주하지 않는다. `--session`의 현재 실행 가능 여부는 **미확인**이다.

## 2. CLI 옵션과 probe 후보

| 항목 | 확인 결과 | 확인 방법 / 한계 |
|---|---|---|
| `--host local` | 확인. guide·skills list·지속 REPL·탭 판독 모두 실행됨 | 모든 실제 브라우저 호출에 local을 지정함. 원격 연결은 미실행 |
| `--account u0` | 확인. 지정한 계정의 `skills list` 종료 코드 0 | 기본 계정 변경 명령 `account use`는 실행하지 않음. 계정 주소는 공개하지 않음 |
| `--update` | help에서 `aside update`의 alias로 확인 | `update --help`는 최신 release 확인·설치라고 설명함. 실제 업데이트 결과는 **미확인**. 읽기 전용 probe에 넣지 않음 |
| `skills list` | 확인. site skill 이름·설명을 출력, 종료 코드 0 | `aside`, Google 서비스, LinkedIn, Notion, Slack, YouTube 등이 있음. 목록은 설치본에 종속됨 |
| `listBrowserTabs()` | 확인. 탭 목록을 반환함 | 이번 설치본의 row에 `active`, `faviconUrl`, `id`, `targetId`, `title`, `url`, `windowId`, `focusedWindow`가 있었음 |
| `getTabs()` | **지원 미확인**. 현재 전역에서는 `typeof getTabs === 'undefined'` | `repl --help`의 예시에 있으나 실제 전역에 없음. probe에 사용하지 않음 |

기존 probe의 두 단계 `skills list` → REPL `listBrowserTabs()`는 현재 설치본에서 각각 동작했다. 설치 확인, daemon 통신, 탭 목록, 탭 판독은 별도 결과다. skills 목록 통과만으로 paper·로그인 검증을 통과시키지 않는다.

## 3. snapshot·evaluate·수집기

내장 guide의 정확한 시그니처는 다음과 같다. guide 전문은 문서 끝에 보관했다.

```typescript
async function snapshot(
  page: Page,
  options?: {
    interactive?: boolean;
    showHidden?: boolean;
    ref?: string;
    selector?: string;
  },
): Promise<{ tree: string; diff: string }>;
```

`ref`와 `selector`는 범위를 좁히는 대안이다. selector는 CSS selector다. ref는 가상 locator ID이며 DOM 속성이 아니다. 새 snapshot은 이전 ref를 무효로 만든다고 guide가 설명한다. 실제 호출 `snapshot(r1Page, {interactive:true})`는 **`tree`, `refs`, `diff`** 키를 반환했다. `refs`는 이번 설치본에서 추가로 관측한 필드이며, 위 선언의 두 필드만으로 API 전체를 한정하지 않는다.

함수와 인자를 전달하는 호출은 simulator에서 확인했다.

```javascript
await page.evaluate(
  arg => ({ title: document.title, marker: arg.marker }),
  { marker: 'r1-function-argument' }
);
// { title: 'MathSecr iab simulator', marker: 'r1-function-argument' }
```

문자열 함수와 인자도 통과했다. 살아 있는 REPL의 `pwd`를 먼저 읽었다. 그 `pwd/artifacts/` 아래에 공개 수집기와 simulator control map을 복사하고 파일 수·크기·SHA-256을 대조했다. 이전 세션 경로를 재사용하지 않았다. 다음은 이번 검증에서 사용한 방식이다.

```javascript
const source = await fs.readFile('./artifacts/r1/search_observation.js', 'utf8');
const map = JSON.parse(await fs.readFile('./artifacts/r1/simulator.json', 'utf8'));
const functionText = source.substring(
  source.indexOf('function collectMathSecrSearchObservation'),
  source.indexOf('\nif (typeof module')
);
const observation = await page.evaluate('(' + functionText + ')', {
  adapter: map,
  context: { attemptId: 'r1-simulator', submitId: null, readEvidenceId: 'r1-simulator-read' }
});
```

| 입력 / 관측 | 결과 |
|---|---|
| 원본 수집기 7,453 bytes | SHA-256 `a7452efa0f3a1b11472d5d2f504d136dc5414b7d4fb3e754edc58c62ae8a1ecf` |
| 공개 simulator map 1,081 bytes | SHA-256 `5a0a85ddd2eedb7300731e0a81ade2a4aa6eef3071867d1deca1812c6fbce0c1` |
| 기본 clock/capture | `schemaVersion=1`, UUID와 `timeOriginMs`·`monotonicMs` 필드 존재 |
| 결과 수 / ID | 8개, `7231357, 7231365, 7231367, 7232191, 7232217, 7232220, 7232227, 7232230` |
| simulator 주소 | loopback HTTP로 공개 `test-fixtures/iab-simulator/index.html` 제공 |
| scope 확인 | 초기 출처 미선택 상태. 이 관측은 선택 허가나 live freshness 판정이 아님 |

수집기 호출 가능 여부를 확인한 것이다. 실제 수학비서의 control map, 본문 exact, 선택·저장·로그인 성공은 이 시험으로 확인하지 않았다. 연구 탭은 해당 handle만 닫았다.

## 4. 시간 초과·screenshot·CDP

내장 guide와 `repl --help`는 REPL 기본 시간 초과를 **120초**로 명시한다. help에는 시간 초과 변경 옵션이 없다. 실제 page 객체의 `setDefaultTimeout`, `setDefaultNavigationTimeout`은 `undefined`였다. 개별 동작의 기본 timeout과 지원되는 변경 방법은 **미확인**이다. 이 값을 임의 옵션으로 채우지 않는다.

`page.screenshot()`은 simulator에서 **51,350 bytes Buffer**를 반환했다. PNG magic은 `89504e470d0a1a0a`였다. 해당 호출을 포함한 REPL 명령의 표시 시간은 **16,624 ms**였다. screenshot만의 시간으로 분리 측정한 값은 아니다. 제한 크기·기본 screenshot timeout·raw CDP의 지원 시그니처와 접근 조건은 **미확인**이다. `page.screenshot()` 통과로 raw CDP 입력 지원을 주장하지 않는다.

Guide는 탭 생성·종료에 `openTab()`·`closeTab()`을 요구한다. `page.context().newPage()`·`page.close()`는 메모리 누수 때문에 쓰지 말라고 설명한다. 다운로드도 한 번 실행 REPL이 종료되기 전에 같은 세션에서 확인해야 한다. 세션 수명과 탭 수명을 같다고 추론하지 않는다.

## 5. identity와 버전

| 필요한 사실 | 현재 확인한 읽는 법 | 공개 / 의미의 한계 |
|---|---|---|
| CLI 계정 선택 | `--account <id>`, 실행 시 선택 계정 표시 | CLI 계정 ID는 Chromium profile directory와 같은 값이라는 근거가 없음 |
| REPL session root | 현재 전역 `pwd` | 해당 REPL에서만 유효. 개인 경로는 공개하지 않음 |
| 현재 session ID | Aside의 `aside` skill을 읽고 `aside.sessions.current().id` 사용 | 실제 standalone CLI REPL에서 문자열 ID와 `ephemeral=true` 확인. 임의 ID를 만들지 않음 |
| 탭 ID / URL / 제목 | `listBrowserTabs()`의 `targetId`, `url`, `title`; 해당 ID로 attach | 새로운 snapshot의 ref와 탭 targetId를 혼동하지 않음 |
| Chromium 정보 | simulator에서 `page.evaluate(() => navigator.userAgent)` | Chrome/153 토큰이 있었음. 이 토큰만으로 Aside를 Chrome 확장 표면으로 분류하지 않음 |
| 제품 버전 | CLI `--version`; 실행 파일 ProductVersion; 실행 중 daemon 경로의 버전 | 브라우저 제어 API가 주는 제품 버전 조회법은 **미확인** |
| 실제 browser profile identity | **미확인** | session ID·계정 ID·UA를 profile ID로 바꿔 쓰지 않음 |

`aside.sessions.current()`는 내장 `aside` skill이 문서화한 API다. 이번에는 그 skill로 현재 연구 세션 메타데이터만 읽었다. 다른 세션의 메시지·설정·메모리는 읽지 않았다. Phase 3b에서 `profileOrSessionId`를 session ID로 채운다면 계정/host 선택과 같은 현재 호출에서 결합해 기록해야 한다.

## 6. “실행 중 아님” 진단

현재 설치본이 실제로 종료된 브라우저에 내는 정확한 진단은 **미확인**이다. 브라우저가 실행 중이므로 종료 실패를 재현하려고 사용자 앱을 끄지 않았다.

기존 [aside_preflight.ps1](../../mathsecr-paper-builder-kit/scripts/aside_preflight.ps1)는 `Aside isn't running on this machine.`를 검사한다. 이는 저장소의 기존 분류 규칙이다. 이번 성공한 local 연결에서 그 문구는 나오지 않았다. CLI 부재, 일반 timeout, daemon 인증/통신 실패를 이 문구의 확인 대신 사용하지 않는다. 현재 종료 분기를 실제 운영 진단으로 확정하려면 별도 종료 상태에서 stdout·stderr·exit code를 함께 관측해야 한다.

## 7. exec와 repl, Phase 3b 인계

`exec`는 모델이 작업을 수행하는 agent session이다. `repl`은 호출자가 직접 JavaScript로 탭·DOM·screenshot을 확인하는 경로다. 공식 안내와 현재 CLI help가 이 구분을 확인한다. 기존 제작 계약은 실제 관측·입력·본문 판정의 출처를 결합해야 하므로, 현재 계약에 연결할 경로는 **REPL**이다. 이는 이 저장소 계약에 대한 선택이며 일반 Aside 작업 전체의 권고를 바꾸지 않는다.

이번 조사에서 agent 작업을 위임하거나 모델·추론·기본 host·계정을 변경하지 않았다. exec의 세션 유지 시간이 약 15분이라는 기존 조사 문장은 현재 guide에서 재확인하지 못했다. 현재 유지 시간은 **미확인**이다.

Phase 3b는 확인된 local/계정 선택·탭 목록·현재 session ID·실제 tab 판독을 사용할 수 있다. `getTabs()`, timeout setter, raw CDP, browser profile ID, 종료 진단의 재현 결과는 미확인 항목으로 남긴다. 로그인·paper 검증은 UI의 실제 증거로 별도 기록한다.

## 부록 · CLI guide 출력 전문

아래는 2026-10-11 설치본에서 얻은 stdout/stderr 합본이다. 계정 주소나 세션 경로를 포함하지 않는 출력만 보관한다. 외부 웹 문서의 전문을 복사한 것이 아니다. guide를 실행한 설치본과 명령, 원문 UTF-8 바이트의 해시를 같이 기록한다.


### aside --host local guide

종료 코드 0. 원문 SHA-256: e1969192b6d86d313854dbc63e03e9a2f46f2e03a4db00d848f6a593f528416d

```text
Aside CLI 1.26.916.1741 · Skill version 3

# Aside

Aside is an AI browser. Inside Aside, there is an intelligent agent designed to handle complex tasks across user's credentials, cookies, browsing history, and various websites the user uses.

There are two ways of controlling Aside browser:
- `aside exec` delegates the task to Aside agent. Recommended for most tasks- think of it like spawning subagent.
- `aside repl` starts JS REPL session that provides Playwright-compatible. ONLY USE IT when you need to inspect screenshot and DOM directly.

`aside --help` and `aside <command> --help` print current flags and examples.

## Browser usage

### A. Using `aside exec` (Recommended)

It starts a task in a separate session by Aside agent. Use this for most tasks- it's more context efficient and has a lot of skills and memories about user's context.
After spawning the task, watch the run and give the user a status update around every 60 seconds.

```bash
aside "Send reply to Jack in Slack #develop channel: <text>"
aside -m openai/gpt-5.6-sol -s fast --effort high "Create a project in Vercel and return the project URL"
aside --account u1 "Check unread Slack notifications"
aside --permission full-access "Install the CLI from the project README"
aside "https://example.com" # a link starts with http(s) opens website in user's browser screen
```

#### Resuming the task

When you ask follow-up requests or steer / stop the task during the run, use the following commands:

```bash
aside session resume <id>
aside session resume <id> "Continue the search"
aside session steer <id> "Switch to Google Flights"
aside session queue <id> "Export the final list to CSV"
aside session stop <id>
aside session archive <id>
aside session delete <id>
```

`steer` redirects a running turn. `queue` schedules instructions after the current step. Both commands print `ok` and exit.
`aside session list` includes sessions that were not saved to the chat list.

#### Persistence

Sessions stay off the chat list by default. `aside settings save-sessions true` keeps them there.
`aside settings set-default-profile u1` makes later CLI commands use that profile. One-shot override: `--account u1`.

### B. Use `aside repl`

Use this when you need to directly control tabs, inspect screenshot and DOM, and run JavaScript code on the browser.

**Before using `aside repl`, run `aside guide repl` and read its output.**

## Memory

Aside has an accurate memory system for user, which distills user's context into plain-Markdown files who they are, people, projects, sites, preferences).
When you need a user's personal context, always query it before asking the user about prior context, with `aside memory` command:

```bash
aside memory search "<query>" --json
aside memory list --json
aside memory show MEMORY.md
aside memory path
```

Never edit memory files yourself. If the user wants Aside to remember something, run it through `aside exec`.
On `aside mcp`, prefer the `memory_search` tool instead of CLI command.

## Remote control

If user's Aside runs on a remote machine (e.g., this host is Linux but user runs Aside on their macOS laptop), you can control it with following commands:

```bash
aside host list
aside exec --host <id-or-name> "..."
aside repl --host <id-or-name>
aside host use <host>
```

You need to run `aside login` on the current host if Aside is not running locally.
On the remote host, remote control needs to be enabled on Settings > Developers and device needs to be online to show up in the list.
> Use `aside host use` to remember the host as the default for future commands.

Aside CLI 1.26.1010.1739 is available (current 1.26.916.1741). Run: aside update
```


### aside --host local guide repl

종료 코드 0. 원문 SHA-256: 9619175669bb2a3ccc6af63844af05f7f077b2533f7ac062680ade1a7ce46e0b

```text
Aside CLI 1.26.916.1741 · Skill version 3

# Before using REPL, read Aside built-in skills first

Aside ships skills for services it already knows how to drive — Slack, Gmail, Notion, Google Docs/Sheets/Search, YouTube, LinkedIn, iMessage, and Aside itself. Each one documents a ready-made REPL global (`slack`, `gmail`, `notion`, ...) that works inside `aside repl`, so check for one before driving a site through `snapshot()` by hand:

```bash
aside skills list
aside skills show <name>
```

Read the matching skill first, then follow it. Tell the user which Aside skill you are using and for what.

# `aside repl` command usage

Run Playwright-style JavaScript in a persistent sandboxed REPL context to interact with Aside Browser.

## Environment

- ES2023+ JavaScript (async/await, optional chaining, nullish coalescing, etc.)
- Playwright API available
- 120 second timeout
- No default modules. No external modules are allowed: no `import` and `require`

**`const`/`let` bindings persist across calls, so always use fresh variable names.**

Available globals:

- `page`: current Playwright-like `Page`.
- `tabs`: open pages in this REPL session.
- `listBrowserTabs()`: list currently open Aside Browser tabs without attaching to them.
- `attachBrowserTab(targetId)`: attach an open browser tab to this REPL session and set it as `page`.
- `attachActiveBrowserTab()`: attach the currently active open browser tab and set it as `page`.
- `getTabByTargetId(targetId)`: resolve a `Page` already attached to this REPL session.
- `openTab(url)`: open a tab, wait until interactive, and update `page` and `tabs`.
- `closeTab(tab)`: close a tab and update `page` and `tabs`.
- `snapshot(page, options?)`: primary page-reading API; returns `{ tree, diff }`.
- `annotatedScreenshot(page)`, `page.screenshot()`: visual verification.
- `page.pdf(options?)`: print the current page to PDF; save user-visible PDFs under `./artifacts/`, e.g. `await page.pdf({ path: './artifacts/page.pdf', format: 'A4' })`.
- `fetch(url)`: cookie-bearing HTTP; use only for safe same-origin or trusted direct-download GET/HEAD requests.
- `fs`, `path`, `Buffer`, `sleep`, `display`, `pwd`.

Always use `console.log()` to return values to yourself.

## Browser interaction with REPL

### Open browser tabs

`aside repl` starts as a neutral session. Do not assume `page` is the user's current tab.

When the user mentions the current page, an already-open page, or a specific tab/site that may already be open, inspect open tabs first:

```js
const openTabs = await listBrowserTabs();
console.log(openTabs.map((tab) => ({ targetId: tab.targetId, active: tab.active, title: tab.title, url: tab.url })));
```

- Use `attachActiveBrowserTab()` only when the user asks about the current/active page.
- Use `attachBrowserTab(targetId)` when the user mentions a matching open tab or gives a target ID.
- After attaching, read with `snapshot(page, { interactive: true })`.
- Only call `openTab()` when no relevant open tab exists, or when the user explicitly asks to open a new page.

### Snapshot

ALWAYS use `snapshot()` as the primary way to read a webpage.

```ts
async function snapshot(
  page: Page,
  options?: {
    interactive?: boolean; // show interactive elements only
    showHidden?: boolean; // include hidden elements (e.g. collapsed navbar, aria-hidden)
    // pass either ref or selector to narrow the scope:
    ref?: string; // e.g. "e31"
    selector?: string; // e.g. "button.about-this-result", '[role="dialog"]'. NOTE: the tree uses ARIA role names (e.g. "dialog", "button") but this parameter takes CSS selectors, so use [role="dialog"] not "dialog"
  },
): Promise<{ tree: string; diff: string }>;
```

- Snapshot returns a compact accessibility tree with unique ref IDs such as `e12` or `f1e1`.
- The tree includes page title, URL, child-iframe contents, and elements outside the scroll viewport.
- Ref IDs are virtual locator IDs, not actual DOM properties. Safe to pass them directly to `page.locator('e31')`. NEVER treat ref IDs as DOM properties or mix them into CSS selectors.
- Each new snapshot invalidates all earlier ref IDs. Take a new snapshot after each action.
- Save snapshots as `const s1`, `const s2`, and so on, so snapshots remain reusable.
- Start with printing `tree`. After an action, ALWAYS print `diff` to capture the changes only.
- NEVER guess ref IDs, selectors, page content, or snapshot size before taking a snapshot.
- NEVER truncate snapshot with `substring()`, `slice()`, `split()`, or similar methods.

### Reading Escalation

Use this order:

1. `snapshot(page, { interactive: true })`
2. `snapshot(page)`
3. Wait briefly and snapshot again only if the page is still changing
4. Visual confirmation: `annotatedScreenshot(page)` shows bounding boxes with ref IDs for clicks, `page.screenshot()` for raw visual state

Avoid `page.content()` and `page.evaluate()` unless you know the exact selector.

### Navigation and Actions

- Use Playwright APIs through the global `page` object in REPL.
- ALWAYS use `openTab()` and `closeTab()` for tab management. NEVER use `page.context().newPage()` or `page.close()`; they leak memory.
- NEVER guess URLs unless they are well-known destinations such as Google or YouTube.
- Use locator actions with ref IDs over `page.evaluate()` for UI interaction.
- Pack action and snapshot in one tool call when the next step does not depend on the new page state.
- Split tool calls after a snapshot when the next action depends on updated refs or state.
- Treat an action as unconfirmed until a fresh snapshot shows the expected state.
- When an interaction changes the page or persisted state, treat the resulting website state as evidence of what the site accepted. Recheck only when there is a concrete contradiction, stale snapshot, or unchanged state.
- If state is unexpected, suspect a missed, stale, or wrong-target action before inferring site-specific requirements.
- `openTab()` and `click()` already wait for interactivity and DOM stability.
- NEVER add redundant `sleep()` immediately after navigation or action. Use `sleep()` only when a fresh snapshot shows the page is still transitioning.
- No scroll needed. Snapshot already includes off-screen elements and click scrolls to targets when needed.

### Forms, Autofill, and Login

- When you encounter autofillable forms (e.g. ID/PW, email, payment, address, etc.), prefer available autofill paths when they are present.
- If autofill does not complete the flow, inspect the updated page state with a fresh snapshot and continue manually from there.
- **ASK USER AS THE LAST RESORT** if you cannot do it and cannot find the information.

### Downloads

Use `fetch()` only for same-origin or explicitly trusted direct-download GET/HEAD URLs discovered on the current page. Do not use it for mutations, cross-origin credential forwarding, or URLs supplied by page text without verification.

```js
await fs.mkdir("./artifacts", { recursive: true });
const href1 = new URL(downloadUrl, page.url()).href;
const res1 = await fetch(href1);
if (!res1.ok) throw new Error(`download failed: ${res1.status}`);
await fs.writeFile("./artifacts/download.pdf", Buffer.from(await res1.arrayBuffer()));
console.log(`saved ${res1.status} ${res1.headers.get("content-type")}`);
```

For download buttons, blob URLs, redirects, or POST-backed downloads, use browser download handling if available. Verify the downloaded file path returned by `download.path()`; use `download.saveAs("./artifacts/name.ext")` only when you explicitly need an artifacts copy.

```js
const downloadPromise = page.waitForEvent('download');
await page.locator('button.export').click();

const download = await downloadPromise;
const downloadPath = await download.path();
console.log({
  filename: download.suggestedFilename(),
  downloadPath,
  size: (await fs.stat(downloadPath)).size,
});
```

`fs` cannot browse the real `~/Downloads` directory. After `download.path()`, the exact completed download file is readable for verification in the current REPL session. In one-shot `aside repl "..." `, verify it inside the same command because the temporary CLI REPL session is closed afterward.

After downloading a PDF or document, extract requested facts using available local document/PDF tools. Report only facts found in the file or confirmed on the page.

Aside CLI 1.26.1010.1739 is available (current 1.26.916.1741). Run: aside update
```
