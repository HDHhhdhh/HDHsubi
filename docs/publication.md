# 공개본의 범위와 실행

## 포함한 내용

- 2026-10-10 로컬 kit의 스크립트, SKILL, AGENTS, 프롬프트, 기술 문서.
- 합성 선택 저널, 검색어 준비, 관측 어댑터, production roster, 로컬 simulator 자료.
- 연도 직렬화의 지역 계약 fixture와 범위를 제한한 과거 관측. 원래 서비스 bundle은 미포함.
- 새 공개용 목표·연표·사고·구조·후속 계획 문서.
- 복사 원본과 공개 파일의 SHA-256을 기록한 SOURCE_SNAPSHOT.
- 공개 파일 목록·문서 링크·민감 정보 검사와 제한된 합성 검사 도구.

초기 공개에서는 테스트 코드 한 곳의 기기 표시명을 합성 이름으로 바꿨다. SOURCE_SNAPSHOT의 transformation에 표시했다. 당시 production 실행 구현과 로컬 canonical 정책은 바꾸지 않았다.

Phase 0에서는 연도 테스트 2개의 JSON reader를 기존 contract reader로 연결했다. PowerShell 버전과 PC 시간대가 달라도 원래 ISO 날짜 문자열과 offset을 보존한다. 단정과 fixture는 그대로 유지했다. 원본 sourceSha256은 보존하고 변경한 export의 해시·크기·transformation만 기록했다.

Phase 1에서는 검증 모듈 4개에 호출 단위 캐시, 단일 읽기·해시, 구조 비교를 추가했다. 변경 전후 결과와 오류는 별도 PowerShell 프로세스로 비교한다. 원본 sourceSha256은 보존하며 변경한 export를 transformation으로 구분한다. [Phase 1 검증 결과](evidence/phase-1.md)에 검증 범위와 수치를 기록한다.

Phase 1b는 같은 최상위 호출 안에서 PDF 검증 프로세스와 성공한 append 검증 결과를 공유한다. PDF마다 검증을 실행하며 호출 종료 시 프로세스를 정리한다. snapshot 내용과 CLR 형식, 기대 목록이 달라지면 다시 검증한다. [Phase 1b 검증 결과](evidence/phase-1b.md)에 계측과 오류 동일성, worker 종료 검사를 기록한다.

## 제외한 내용

원본 PDF/HWPX, 문항 렌더와 크롭, 실제 문제 DB inventory, 개인 문제지 주소, 원시 세션 JSONL, 실제 브라우저 캡처·프로필·인증 자료를 제외했다. 임시 OCR/Python 환경과 개별 문제지용 one-off 스크립트도 제외했다.

실제 시험지를 사용하는 body-exact·PDF 분할 자료와 그 자료에 의존하는 평가·lesson registry 원본도 공개하지 않았다. 개인 자료를 제거한 상태에서 전체 kit의 설치 가능성과 전체 회귀 통과를 주장하지 않는다.

기존 비공개 Git 저장소를 공개로 전환하지 않았다. 로컬에 남은 `.git`을 수정하지 않았다. 공개본은 별도 초기 Git 이력으로 시작한다.

## 원래 kit와 공개본의 차이

원래 kit의 [README](../mathsecr-paper-builder-kit/README.md)는 full hub checkout과 인덱스의 `.omo/evidence`를 설치 계약으로 요구한다. 공개본에는 그 비공개 자료가 없다.

따라서 `install.ps1`, `check.ps1`, `run_validations.ps1`의 전체 계약은 공개 clone만으로 통과한다고 안내하지 않는다. 해당 코드도 구조 검토를 위해 포함했다. 실제 지원 bundle을 갖춘 별도 환경에서 사용한다.

기존 kit 문서의 과거 `.omo/evidence`·평가·렌더 참조는 원래 비공개 bundle을 가리킨다. 공개본에서 열 수 있는 링크로 위장하지 않는다. 새 공개 문서는 공개 파일에만 링크한다.

## 실행할 수 있는 공개본 검사

Python 3과 PowerShell 7을 준비한다. 서비스 로그인은 필요하지 않다. offline regression의 Collector는 Edge/Chrome으로 로컬 simulator를 검사한다. 의존성은 [회귀 inventory](evidence/regression-inventory.md)를 따른다.

```powershell
python ./scripts/validate_publication.py
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_public_checks.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/run_offline_regression.ps1
```

검사 범위는 다음과 같다.

| 검사 | 확인 내용 |
|---|---|
| publication validator | 새 문서의 로컬 링크, JSON 형식, public allowlist, 복사 해시, 실제 개인 경로·키·토큰·금지 확장자 |
| Selection Journal All | 요청·재시도·ACK·재개, 실파일 왕복, 중복과 손상 입력 거부 |
| Search Query Plan | 원본 순서, literal 단서, 원본 위치, 입력 shape의 허용·거부 |
| public offline regression | 14개 공개 gate: 연도 계약, 관측/collector, 회귀 receipt, PDF 생성, 저널, 검색어, 이력 fixture·runner·캐시·조립/상주·surface 검증 |

이들은 공개 packaging과 독립 가능한 지역 계약의 검사다. 전체 production 회귀, 브라우저 연결, 저장, 수학적 정답을 증명하지 않는다. 기존 전체 검사 PASS 기록을 새로 실행한 것처럼 표시하지 않는다.

Phase 0은 원래 full runner를 수정하지 않고 별도 public runner와 Windows CI를 추가했다. [회귀 inventory](evidence/regression-inventory.md)에 필요한 경로와 공개 가능 여부를 기록했다. 공개되지 않은 20개 gate는 SKIP이며, public gate의 입력이 없으면 FAIL이다. 누락된 원래 helper 또는 oracle을 합성 자료로 대체하지 않았다.

새 성능 입력은 OS 임시 폴더에서 생성하고 검증한다. 생성한 PNG, PDF, session과 실행 artifact는 커밋하지 않는다. 공개 계약을 만족시키기 위한 합성 시각과 판정은 실제 관측이나 본문 정답의 증거가 아니다. 수치와 실행 명령은 [Phase 0 성능 기준선](evidence/phase-0.md)에 있다.

## 실제 제작에 필요한 것

사용자 소유의 원본과 허가된 수학비서 계정·DB 접근 권한이 필요하다. 최신 도구 문서와 실제 연결을 확인해야 한다. production 정책을 바꿀 때는 canonical 지침과 어댑터·validator를 함께 맞춰야 한다.

공개는 재배포 라이선스를 새로 지정하는 행동과 다르다. 이 공개 작업에서는 별도 라이선스를 부여하지 않았다. 수학비서·Aside·Codex 등 외부 제품의 코드나 실행 파일을 배포하지 않는다.

Phase 2는 기존 export 계약을 유지하며 새 조립기·상주 검증 CLI와 공개 합성 gate를 더한다. [입력 계약](search_attempt_input.md)과 [본문 판정](body_judgment_input.md)은 입력 사실과 자동 계산을 구분한다. simulator receipt는 현재 선택 정책대로 거부하고 공개 합성 receipt로 Select·BeforeNext를 검증한다. [Phase 2 결과](evidence/phase-2.md)는 명령 격리·동일성·시간 측정 범위를 기록한다.

Phase 3a는 선언한 surface 4종을 지원하고, receipt·append 이력·캐시를 같은 surface에 결합한다. 새 SurfaceContract gate와 simulator A2 경로를 검증한다. 기본 Aside session의 동일성 24개와 H=6 성능은 [Phase 3a 결과](evidence/phase-3a.md)에 있다. export 5개의 해시·크기·transformation을 갱신하며 원본 sourceSha256 72개는 보존한다. 실제 연결 probe·canonical 지침과 비공개 자료의 검증 범위는 후속 작업이다.
