# 연구 과제 · Codex 조사 지시서

이 조사는 코드 변경이 아니다. 결과는 `docs/research/` 아래 markdown 한 파일씩이다. 각 과제는 한 스레드에서 한다. 결과에는 출처 URL과 확인 날짜를 쓴다. 확인하지 못한 것은 "미확인"으로 쓴다. 추측을 사실처럼 쓰지 않는다.

Claude가 2026-10-11에 확인한 공개 정보는 다음과 같다. 조사의 출발점으로 쓴다.

- 수학비서(mathsecr.com)는 포스트매스가 운영하는 교사용 문제은행이다. HWP 지원, 원클릭 유사문제 검색, 자체 수학 OCR, 수학적 의미 기반 그래프 유사 검색이 있다. 100개 이상 고등학교가 쓴다. 출처: 유니콘팩토리 2024-11-17 기사.
- Aside는 YC 지원 에이전트 브라우저다. CLI `aside exec`, `aside repl`이 있다. REPL 전역에 `page`, `tabs`, `listBrowserTabs()`, `attachBrowserTab(targetId)`, `attachActiveBrowserTab()`, `openTab(url)`, `closeTab(tab)`, `snapshot(page, options)`(`interactive`, `showHidden`, `ref`, `selector` 옵션, 반환 `{tree, diff}`), `annotatedScreenshot(page)`, `page.screenshot()`, `page.evaluate()`가 있다. snapshot마다 이전 ref가 무효가 된다. `aside exec` 세션은 종료 뒤 약 15분 유지된다. 요금제는 Free/Pro/Max다. 출처: 공개 `aside-browser` skill 문서, 2026 비교 글. 공식 문서 URL은 미확인.
- Codex는 2026년 기준 Computer use, 내장 앱 브라우저(IAB), Chrome 확장(2026-05, macOS·Windows, 실제 Chrome 프로필 사용, 2FA·로그인 화면에서 멈춤)으로 브라우저를 제어한다. 출처: 2026 비교 글. 공식 문서로 재확인 필요.

## R1 · Aside REPL 공식 사양

목표: Phase 3의 probe와 identity receipt에 쓸 사실을 확정한다.

조사 항목:

1. 공식 문서 위치. `aside guide`, `aside guide repl` 출력 전문을 보관한다.
2. CLI 옵션 `--host`, `--account`, `--update`, `skills list`의 현재 동작.
3. `snapshot(page, options)` 정확한 시그니처와 반환 구조. `page.evaluate()`에 함수와 인자를 넘기는 방법. 이 저장소의 `search_observation.js`를 그 방법으로 호출할 수 있는지 simulator 탭에서 확인한다.
4. 시간 초과 기본값과 변경 방법. screenshot과 CDP 관련 제한.
5. 브라우저 identity를 읽는 방법. 프로필, 세션 ID, 탭 ID, 버전.
6. 실행 중 아님을 나타내는 정확한 진단 문구. 현재 코드는 `Aside isn't running on this machine.`를 기준으로 한다.
7. `aside exec`와 `aside repl`의 차이. 어느 쪽이 제작에 맞는지.

출력: `docs/research/aside-repl.md`. 각 항목에 확인 방법과 출처를 쓴다.

## R2 · 수학비서 문제 검색 UI control map

목표: Phase 2의 `test-fixtures/control-map/mathsecr-current.json`을 채운다.

주의: 실제 계정과 문제지는 사용자 소유다. 사용자가 세션을 열어 준 경우에만 한다. 읽기 전용으로 한다. `출제하기`, `전체 선택`, `문제지에 담기`, `변경하기`, `선택 삭제`를 누르지 않는다. 실제 문제지 URL과 계정 정보를 결과 문서에 쓰지 않는다. 문제지 URL은 `/mypaper/123`으로 바꿔 쓴다.

조사 항목:

1. `/mypaper/<id>` 검색 화면의 control. `나만의 DB 선택`, `내 문제지 선택`, `단원 및 유형 선택`, 텍스트·수식 검색 입력, `f(x)` 수식 버튼, `검색하기`, 결과 수 표시, 결과 카드, 카드 ID 위치, 선택 체크박스, `다음 단계`.
2. 각 control의 안정적인 selector. `data-*` 속성, role, 텍스트 중 무엇이 안정적인지. 같은 selector로 두 번 로드해 확인한다.
3. 결과 카드의 DOM 구조. 카드 ID, DB명, 출처 메타데이터, 본문 이미지의 위치.
4. lazy loading 방식. 스크롤 단위, 끝 판정 신호.
5. 편집 화면의 control. `문제 추가하기`, `문제 검색` modal, `추가`, `확인`, 카드 메뉴 `문제 이동`, `번호순 정렬`.
6. 공식 도움말에서 검색 조건과 수식 입력 문법을 확인한다. 도움말은 live paper 탭이 아닌 다른 탭에서 연다.

출력: `docs/research/mathsecr-control-map.md`와 `mathsecr-paper-builder-kit/test-fixtures/control-map/mathsecr-current.json`. JSON은 Phase 2의 schema를 따른다.

## R3 · Codex 브라우저 표면 비교

목표: Phase 3의 `codex-iab`, `codex-chrome-ext` probe 명령과 identity 필드를 확정한다. Phase 5 비교 실험의 설계 근거를 만든다.

조사 항목:

1. OpenAI developers 공식 문서에서 Codex의 Computer use, 내장 브라우저, Chrome 확장의 현재 사양. 지원 OS, 로그인 처리, 탭 제어, DOM 판독 API, 스크린샷, 시간 초과.
2. 각 표면에서 현재 탭 목록, URL, 제목, 로그인 상태를 읽는 명령.
3. 각 표면에서 페이지 안 JS를 실행하는 방법. `search_observation.js` 호출 가능 여부.
4. 각 표면의 identity를 받는 방법. 브라우저 종류, 프로필, 탭 ID.
5. `docs/incidents.md` 사고 19~21의 원인 후보를 공식 사양으로 재해석한다. 메모리 commit 94.3% 관측과 시간 초과의 관계는 "미확인"으로 둔다. 근거가 있을 때만 쓴다.
6. 공정 비교 설계. 같은 source·scope·시작 칩·저장 상태에서 양쪽 완료 쌍만 비교한다. 순서 교차. 측정 항목과 기록 형식을 제안한다.

출력: `docs/research/codex-browser-surfaces.md`.

## 결과 전달

각 결과는 PR로 올린다. 브랜치 `codex/research-r1` 등. Issue #2에 링크를 남긴다. 코드와 fixture 변경은 R2의 JSON만 허용한다.
