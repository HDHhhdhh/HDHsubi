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
1. 사이트 텍스트 검색(`textIncludes`)은 **부분 문자열의 AND**다. 공백이 들어간 구절이나 수식은 거의 걸리지 않는다. 그래서 한글 단어만 뽑고 조사를 뗀다(`terms`).
2. 서버 응답 시간은 걸리는 문항 수에 비례한다. `정수`처럼 흔한 단어 하나는 수천 건이라 몇 초가 걸리고, 3단어 AND는 0.5초 안팎이다. 그래서 1차로 긴 단어 위주의 3~5단어 AND와 연속 3단어 묶음을 약 10개 보낸다. 하나도 안 걸린 항목만 2단어 묶음으로 한 번 더 찾는다. 결과가 `--max-total`(기본 300)을 넘는 질의는 너무 넓다고 보고 점수에서 뺀다.
3. **교재 자동 좁히기**: 앞의 `--probe`(기본 6)문항 결과에서 여러 문항에 공통으로 나오는 교재(보유 DB 제목)를 찾는다. 학교 프린트는 보통 한두 교재에서 뽑기 때문이다. 찾으면 나만의 DB 폴더 트리를 한 번 훑어 그 교재의 DB id를 얻고, 모든 문항을 그 DB 안에서 다시 검색한다(범위가 작아 빠르므로 2단어 묶음까지 보낸다). 교재 안에서도 안 걸린 문항만 전체 범위로 검색한다. 교재 단계 점수는 2배로 쥐다. 끄려면 `--no-auto-scope`. 결과의 `books`/`bookDbIds`에 기록된다.
4. 셀마다 걸린 질의 수와 질의 구체성으로 점수를 매긴다. 수식은 색인되지 않아 동점이 많으므로, 프린트가 교재 순서를 따른다는 점을 이용해 앞뒤 문항(±2)의 선두 후보와 셀 id가 가까운 후보에 작은 가산점(`neighbor`, 최대 20%)을 준다. 상위 `--top`(기본 15)개를 낸다. 각 후보에는 `id`, `imagePath`, `sources`(출처 제목), `books`, `chapter`, `score`, `hits`, `neighbor`가 붙는다.
5. `--images DIR`를 주면 항목별 상위 `--images-top`(기본 8)개 이미지를 내려받아 `DIR/<cellId>.png`에 저장하고 후보의 `image`에 경로를 적는다. CDN은 브라우저 쿠키가 있어야 열리므로 Aside 세션으로 받는다.

범위 옵션(사이트 필터와 같다):
- `--scope-folder 81500[,..]`: 나만의 DB 폴더 ID. 예: `81500` 수능특강·수능완성, `1` 교육청·평가원, `5127` 작업공간 전체. 폴더 트리는 `GET /bms/api/v1/folders?folderType=mydb`에서 확인한다.
- `--db-ids`, `--paper-ids`, `--chapters`(chapterTreeIds), `--years 2025-2026`
- 속도: `--concurrency 6`(동시에 보내는 요청 수 상한). 탭이 백그라운드에 있으면 브라우저가 타이머를 늦추므로, 간격 타이머 대신 동시 요청 수로만 속도를 조절한다. 429/5xx는 잠시 쉬었다가 다시 시도하고, 요청 하나가 30초를 넘으면 끊는다.
- 폴더 범위를 주면 빨라지고 정확해진다. 단 `5127`(작업공간 전체)은 오히려 느리다(질의당 약 2.5초). 출처를 모르면 범위 없이 돌린다.

한글 단어가 하나뿐인 문항(수식만 있는 문제)은 질의를 만들 수 없다. 서버가 단어 하나짜리 검색에는 0건을 돌려주기 때문이다. 이런 문항은 `queries`/`terms`를 직접 주거나 수동으로 찾는다.

실측(2026-11-14, 백양 미적1 프린트1, 18문항, 알려진 정답 16개): 78초, 요청 576개. 16개 중 15개가 후보 목록에 들었다(1위 11, 3위 안 14, 모두 이미지 저장됨). 놓친 1개는 한글 단어가 `다항함수` 하나뿐인 문항이다. 이전에 화면을 조작했을 때는 약 25분이 걸렸다.

stderr 마지막 줄에 요약이 찍힌다: `{"items":18,"ms":...,"requests":...,"expected":{"total":16,"found":..,"top1":..}}`.

## 2) 문제지 만들기 + 셀 넣기

```
node tools/site_search.cjs create-paper --title "문제지 이름" --cells 7231979,7232826,... [--folder 194543]
node tools/site_search.cjs create-paper --title "문제지 이름" --cells-file picks.json
```

- 폴더 기본값은 subi 계약의 194543이다.
- 셀은 준 순서대로 맨 뒤에 붙는다(50개씩 나눠 보냄). 끝나면 문제지 셀 목록을 다시 읽어 순서가 맞는지 확인한다. 결과의 `orderOk`가 false면 종료 코드는 2다.
- 출력: `{"paperId":..., "url":"https://www.mathsecr.com/mypaper/<id>", "count":..., "orderOk":true, "cells":[...]}`
- `--cells-file`은 숫자 배열, `{id}`/`{site_cell_id}` 객체 배열, `{cells:[...]}` 중 하나를 받는다.

기존 문제지 뒤에 붙이기는 `add-cells --paper <id> --cells ...`, 확인만 하려면 `paper-cells --paper <id>`.

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
