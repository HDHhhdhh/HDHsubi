# tools/site_search.cjs — 수학비서 빠른 검색·문제지 구성

모델이 Aside 브라우저 화면을 한 단계씩 조작(검색→읽기→이미지 열기→다음)하던 일을, 사이트가 내부적으로 쓰는 JSON API(`api.mathsecr.com`)를 **로그인된 Aside 탭 안에서** 직접 호출하는 방식으로 바꾼다. 모델은 후보 이미지를 보고 "같은 문제인가"만 판정한다.

- 필요: Node 18+, Aside Browser(로그인 상태), Aside CLI(`%LOCALAPPDATA%/Aside/CLI/current/aside.exe`, 다르면 `--aside` 또는 `ASIDE_EXE`).
- 실행할 때마다 `aside --host local mcp` 세션을 새로 열고 **자기 탭 1개**(`/home`)를 띄웠다가 끝나면 닫는다. 다른 탭, 로그인 상태, 계정 설정은 건드리지 않는다.
- 로그인이 안 됐거나 기기 제한 안내가 보이면 `STOP:` 메시지를 내고 종료한다. 로그인이나 안내 닫기는 하지 않는다.
- 출제, HML 다운로드, 삭제 기능은 없다.

## 1) 검색

```
node tools/site_search.cjs search --in items.json --out result.json [--images DIR] [옵션]
```

`items.json`은 배열이다(`{items:[...]}`도 된다). 각 항목:

| 필드 | 뜻 |
|---|---|
| `key` 또는 `id`/`number` | 결과와 짝을 맞출 키 |
| `text` | 문항 전사. 한글 단어를 뽑아 자동으로 질의를 만든다 |
| `terms` (선택) | 자동 추출 대신 쓸 단어 목록 |
| `queries` (선택) | 직접 지정한 AND 질의 목록, 예: `[["정수","개수"],["극댓값","극솟값"]]` |
| `scope` (선택) | 항목별 범위(아래 범위 옵션과 같은 키) |
| `site_cell_id`/`expect` (선택) | 정답 셀. 있으면 결과에 순위(`expected`)를 기록한다 |

작업 기록의 `output/sources.json`을 그대로 넣어도 된다.

### 같은 문제 판정 규칙 (소유자 1571040637506297917)

> "객관식 선지 없거나 다른 거는 굳이 검증하지 말고, 같은 문제로 취급하고 집어넣어"

- **발문(본문)이 같으면 같은 문제다.** 선지가 없거나(학교 프린트는 선지를 지운다) 다르거나, `구하시오`/`값은?`처럼 끝맺음만 다르면 더 확인하지 않고 문제지에 넣는다.
- 스크립트는 질의를 만들 때 발문만 쓴다. 첫 ① 뒤, 끝에 붙은 `(1) .. (2) .. (3)` 선지는 잘라내고, 끝맺음 말(구하시오, 구하면, 얼마인가, 몇 등)은 검색어에서 뺀다.
- `search`와 `create-paper` 결과의 `rule` 필드에 이 규칙을 적어 둔다. 후보 이미지를 보고 판정하는 단계(모델)도 이 규칙을 따른다.

동작:
1. 사이트 텍스트 검색(`textIncludes`)은 **부분 문자열의 AND**다. 공백이 들어간 한글 구절은 걸리지 않는다. 그래서 한글 단어를 뽑아 조사를 떼고(`terms`), 식은 사이트 LaTeX 표기로 바꿔 따로 뽑는다(`formulas`, 아래 수식 검색).
2. 서버 응답 시간은 걸리는 문항 수에 비례한다. `정수`처럼 흔한 단어 하나는 수천 건이라 몇 초가 걸리고, 3단어 AND는 0.5초 안팎이다. 그래서 1차로 긴 단어 위주의 3~5단어 AND와 연속 3단어 묶음을 약 10개 보낸다. 하나도 안 걸린 항목만 2단어 묶음으로 한 번 더 찾는다. 결과가 `--max-total`(기본 300)을 넘는 질의는 너무 넓다고 보고 점수에서 뺀다.
3. **교재 자동 좁히기**: 앞의 `--probe`(기본 6)문항 결과에서 여러 문항에 공통으로 나오는 교재(보유 DB 제목)를 찾는다. 학교 프린트는 보통 한두 교재에서 뽑기 때문이다. 찾으면 나만의 DB 폴더 트리를 한 번 훑어 그 교재의 DB id를 얻고, 모든 문항을 그 DB 안에서 다시 검색한다(범위가 작아 빠르므로 2단어 묶음까지 보낸다). 교재 안에서도 안 걸린 문항만 전체 범위로 검색한다. 교재 단계 점수는 2배로 쥐다. 끄려면 `--no-auto-scope`. 결과의 `books`/`bookDbIds`에 기록된다.
4. 셀마다 걸린 질의 수와 질의 구체성으로 점수를 매긴다. 수식은 색인되지 않아 동점이 많으므로, 프린트가 교재 순서를 따른다는 점을 이용해 앞뒤 문항(±2)의 선두 후보와 셀 id가 가까운 후보에 작은 가산점(`neighbor`, 최대 20%)을 준다. 상위 `--top`(기본 15)개를 낸다. 각 후보에는 `id`, `imagePath`, `sources`(출처 제목), `books`, `chapter`, `score`, `hits`, `neighbor`가 붙는다.
5. `--images DIR`를 주면 항목별 상위 `--images-top`(기본 8)개 이미지를 내려받아 `DIR/<cellId>.png`에 저장하고 후보의 `image`에 경로를 적는다. CDN은 브라우저 쿠키가 있어야 열리므로 Aside 세션으로 받는다.

범위 옵션(사이트 필터와 같다):
- `--scope-folder 81500[,..]`: 나만의 DB 폴더 ID. 예: `81500` 수능특강·수능완성, `1` 교육청·평가원, `5127` 작업공간 전체. 폴더 트리는 `GET /bms/api/v1/folders?folderType=mydb`에서 확인한다.
- `--db-ids`, `--paper-ids`, `--chapters`(chapterTreeIds), `--years 2025-2026`
- 속도: `--concurrency 6`(동시에 보내는 요청 수 상한). 탭이 백그라운드에 있으면 브라우저가 타이머를 늦추므로, 간격 타이머 대신 동시 요청 수로만 속도를 조절한다. 429/5xx는 잠시 쉬었다가 다시 시도하고, 요청 하나가 30초를 넘으면 끊는다.
- 폴더 범위를 주면 빨라지고 정확해진다. 단 `5127`(작업공간 전체)은 오히려 느리다(질의당 약 2.5초). 출처를 모르면 범위 없이 돌린다.

### 수식 검색

사이트의 `f(x)`(수식 입력) 버튼은 LaTeX 문자열을 `textIncludes`에 그대로 넣는다. 사이트는 문항을 LaTeX로 저장하고 부분 문자열로 비교하므로, **사이트와 같은 표기로 쓰면 수식으로 검색된다**. 2026-11-14 실측 표기:

- 식 안에는 공백이 없다: `x^{4}+ax^{2}`, `tf(t)`, `(x+1)f(x)`, `x^{3}-6x^{2}+9x+2` (`(x+1) f(x)`, `x^{4}+a x^{2}`는 0건)
- 지수에는 중괄호를 쓴다: `x^{3}`
- 명령어 아래첨자 앞에는 공백이 있다: `\int _{-2}^{2}` (`\int_{-2}^{2}`는 0건)
- 분수는 `\frac{13}{2}`, 무한대는 `\infty`
- 극한(`\lim`)과 프라임(`f'(1)`)은 표기를 아직 못 찾았다. 그래서 만들지 않는다.

스크립트는 전사의 식을 이 표기로 바꿔 수식 조각을 최대 4개 뽑는다(`formulas`: 정적분 구간, 다항식, `tf(t)`류 곱, 분수, `(…)/x`의 분자). 질의는 조각 하나, 조각+가장 긴 한글 단어, 긴 조각 두 개를 쓴다. 한글 단어가 2개 미만인 수식 위주 문항은 이 질의로 찾는다. 예: 적분 7은 `\int _{-2}^{2}` + `(x+1)f(x)`가 교재 안에서 1건으로 좁혀져 1위가 됐다. 수식 조각을 직접 주려면 항목에 `formulas: [...]`를 넣는다.

실측(2026-11-14, 백양 미적1 프린트1, 18문항, 알려진 정답 16개): 85초, 요청 650개. **16개 모두 1위**였고 이미지도 저장됐다. 이전에 화면을 조작했을 때는 약 25분이 걸렸다.

stderr 마지막 줄에 요약이 찍힌다: `{"items":18,"ms":...,"requests":...,"expected":{"total":16,"found":..,"top1":..}}`.

## 2) 문제지 만들기 + 셀 넣기

```
node tools/site_search.cjs create-paper --title "문제지 이름" --cells 7231979,7232826,... [--folder 194543] \
  --print-name "26 행신 공수2 기말 프린트2" --mathbank-db <MathBankData/mathbank.sqlite> --mathbank-out <작업 폴더>
node tools/site_search.cjs create-paper --title "문제지 이름" --cells-file picks.json --print-name "<정식 프린트 이름>" ...
```

- **학교 프린트 문제지는 항상 `--print-name`에 정식 프린트 이름을 넣는다**(`연도 학교 과목 중간|기말 프린트[N]`, 예: `26 행신 공수2 기말 프린트2`). `--title`은 사이트에 보이는 문제지 이름이고, `--print-name`은 MathBank에 "이 문항이 어느 프린트에 들어갔는지"를 남기는 이름이다(아래 3). 학년이 공통수학이 아니면 `--grade`, 학기를 알면 `--semester`를 함께 준다. 기존 문제지의 일부만 쓰는 프린트는 `create-paper` 대신 3의 `record`를 실행한다.
- 출력의 `mathbank.status`가 `recorded`/`enriched`/`already_recorded`인지, `mathbank.unmatched`가 몇 개인지 작업 영수증에 적는다. `failed`(종료 코드 3)면 문제지는 그대로 두고 `record`만 다시 실행한다.

- 폴더 기본값은 subi 계약의 194543이다.
- 셀은 준 순서대로 맨 뒤에 붙는다(50개씩 나눠 보냄). 끝나면 문제지 셀 목록을 다시 읽어 순서가 맞는지 확인한다. 결과의 `orderOk`가 false면 종료 코드는 2다.
- 출력: `{"paperId":..., "url":"https://www.mathsecr.com/mypaper/<id>", "count":..., "orderOk":true, "cells":[...]}`
- `--cells-file`은 숫자 배열, `{id}`/`{site_cell_id}` 객체 배열, `{cells:[...]}` 중 하나를 받는다.

기존 문제지 뒤에 붙이기는 `add-cells --paper <id> --cells ...`, 확인만 하려면 `paper-cells --paper <id>`.

## 3) MathBank에 "이 원본이 어느 학교 프린트에 들어갔다" 기록

`create-paper`에 `--print-name`을 주면 셀 추가와 순서 확인이 끝난 뒤 탭을 닫고, 그 프린트에 들어간 문항을 MathBank 기존 문항에 연결한다. 결과는 출력의 `mathbank` 필드에 남는다.

```
node tools/site_search.cjs create-paper --title "행신 공수2 프린트2" --cells-file picks.json \
  --print-name "26 행신 공수2 기말 프린트2" --mathbank-db <MathBankData/mathbank.sqlite> --mathbank-out <작업 폴더>
```

새 문제지를 만들지 않는 경우(기존 문제지 일부만 쓰는 프린트)나 나중에 기록할 때는 직접 실행한다.

```
node tools/mathbank_membership.cjs record --db <mathbank.sqlite> --name "주엽 26 미적1 기말 프린트" \
  --paper 2102155 --cells 846168,2296167,... --grade 2 --semester 2 --out <작업 폴더> [--dry-run]
```

- DB 경로는 `--mathbank-db`/`--db` 또는 환경변수 `MATHBANK_DB`. Node 22.13 이상(`node:sqlite`)이 필요하다.
- 이름에서 연도(`26`), 학교, 과목(`공수2`, `미적1` 등), `중간`/`기말`, `프린트N`의 N을 읽는다. `--school --year --subject --exam --part --grade --semester`로 덮어쓸 수 있다. 학년은 공통수학1·2면 1, 그 밖의 과목은 `--grade`로 준다.
- 연결은 MathBank가 이미 가진 수학비서 셀 ID 대응(`external_identities` workroom_item/mathsecr, resolved)만 쓴다. 대응이 없거나 둘 이상이면 연결하지 않고 `unmatched`에 위치·셀·이유를 적는다. 추측으로 잇지 않는다.
- 쓰기: worksheet 소스 1개(`print_membership_v1`: 이름·학교·학년·연도·학기·과목·시험·순번, 문제지 id, 위치별 결과, 기록 시각, 영수증)와 일치한 문항마다 occurrence 1개. 같은 프린트를 다시 기록하면 아무것도 쓰지 않는다(`already_recorded`). 예전 방식으로 만든 같은 프린트 기록이 있으면 새로 만들지 않고 정보만 보탠다(`enriched`).
- MathBank writer lock(`MathBankData/index.lock`)을 잡고 쓴다. 다른 작업자가 잡고 있으면 기다리고(`--lock-wait` 초, 기본 1800), 남의 lock은 지우지 않는다. 쓰기 전에 바뀌는 행을 `<out>/mathbank-membership-<paper>-<시각>.backup.json`에 남기고, 쓴 뒤 따로 다시 읽어 확인한 결과를 `.receipt.json`에 남긴다.
- MathBank는 occurrence가 생긴 문항의 유사문항 캐시를 비우고 다음 색인 때 다시 만든다. 비워진 행 수는 `neighbors_invalidated`, 원래 행은 backup에 있다.
- 기록이 실패해도 문제지는 그대로 두고 `create-paper`는 종료 코드 3을 낸다.

## 사용한 사이트 API (2026-11-14 관측)

모든 요청에 `Authorization: Bearer <next-auth session accessToken>`과 `X-User-Type: educator`를 붙인다. 토큰은 탭 안에서 `/api/auth/session`으로 얻으며 파일에 저장하지 않는다.

| 용도 | 요청 |
|---|---|
| 검색 | `GET /bms/api/v1/question-cells?source=mypaper&curriculumId=2&isSoftMode=true&problemBankScope=include&textIncludes=..&textIncludes=..&dbFolderIds=a\|b&limit=48[&cursor=]` → `data.cellsByChapter[].cells[]`, `pagination.{totalItems,cursor}` |
| 셀 상세 | `GET /bms/api/v1/question-cells/<id>?curriculumId=2&withAllSources=true` |
| 문제지 생성 | `POST /bms/api/v1/my-papers` `{"title","folderId","category":"paper"}` → `data.id` |
| 셀 추가 | `POST /bms/api/v1/my-papers/<id>/cells?action=add&curriculumId=2` `{"cellIds":[..],"afterNumber":N}` → 204 |
| 셀 목록 | `GET /bms/api/v1/my-papers/<id>/cells?curriculumId=2&limit=200` |

사이트가 바뀌어 4xx가 나면 위 표를 다시 관측해 고친다. 우회 시도는 하지 않는다.
